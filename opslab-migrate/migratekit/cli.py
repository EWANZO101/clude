"""Typer CLI with a Rich live terminal UI."""

from __future__ import annotations

import sys
import threading
import time
from pathlib import Path

import typer
from rich.console import Console, Group
from rich.live import Live
from rich.panel import Panel
from rich.progress import (BarColumn, Progress, SpinnerColumn, TextColumn,
                           TimeElapsedColumn, TimeRemainingColumn)
from rich.table import Table
from rich.text import Text

from . import __version__
from .config import Config, ConfigError, load_config
from .logging_setup import get_logger, setup_logging
from .orchestrator import Orchestrator
from .report import Reporter
from .ssh import SSHConnection

app = typer.Typer(add_completion=False,
                  help="OpsLab Migrate — automated Python/Flask server "
                       "migration toolkit")
console = Console()
log = get_logger("cli")

OK = "[bold green]✓[/]"
FAIL = "[bold red]✗[/]"
ARROW = "[bold blue]→[/]"

# Pipeline stages shown in the live table
STAGES = ["Backing up", "Transferring", "Restoring", "Verifying",
          "Self-healing", "Done"]


class LiveUI:
    """Live dashboard: header, per-project status table, log tail."""

    def __init__(self, cfg: Config):
        self.cfg = cfg
        self.statuses: dict[str, str] = {}
        self.log_lines: list[str] = []
        self.lock = threading.Lock()
        self.progress = Progress(
            SpinnerColumn(),
            TextColumn("[progress.description]{task.description}"),
            BarColumn(bar_width=40),
            TextColumn("{task.percentage:>3.0f}%"),
            TimeElapsedColumn(),
            TimeRemainingColumn(),
            console=console,
        )
        self.task = self.progress.add_task("Overall", total=100)
        self.total_projects = 1
        self.done_projects = 0

    def status(self, project: str, message: str) -> None:
        with self.lock:
            if project == "*":
                self.log_lines.append(
                    f"[dim]{time.strftime('%H:%M:%S')}[/] {message}")
            else:
                self.statuses[project] = message
                self.log_lines.append(
                    f"[dim]{time.strftime('%H:%M:%S')}[/] "
                    f"[cyan]{project}[/]: {message}")
                if message == "Done" or message.startswith("FAILED"):
                    self.done_projects += 1
            self.log_lines = self.log_lines[-8:]
            pct = min(99, int(
                100 * self.done_projects / max(self.total_projects, 1)))
            self.progress.update(self.task, completed=pct)

    def render(self) -> Group:
        with self.lock:
            table = Table(box=None, pad_edge=False, show_header=True,
                          header_style="bold")
            table.add_column("Project", style="cyan", min_width=18)
            table.add_column("Status")
            for name, msg in sorted(self.statuses.items()):
                icon = OK if msg == "Done" else (
                    FAIL if msg.startswith(("FAILED", "Restore failed"))
                    else ARROW)
                table.add_row(name, f"{icon} {msg}")
            header = Text.assemble(
                ("OpsLab Migrate ", "bold"), (f"v{__version__}  ", "dim"),
                (self.cfg.source.host, "green"), (" → ", "dim"),
                (self.cfg.destination.host, "green"))
            logs = Text.from_markup("\n".join(self.log_lines) or "[dim]…[/]")
            return Group(
                Panel(header, border_style="blue"),
                Panel(table, title="Projects", border_style="dim"),
                self.progress,
                Panel(logs, title="Log", border_style="dim"),
            )


def _load(config_path: Path) -> Config:
    try:
        cfg = load_config(config_path)
    except ConfigError as e:
        console.print(f"{FAIL} Config error: {e}")
        raise typer.Exit(2)
    # Prompt now (before any live UI) if passwords are set to "ask"
    cfg.source.resolve_password("source")
    cfg.destination.resolve_password("destination")
    return cfg


@app.command()
def migrate(
    config: Path = typer.Option("config.yaml", "--config", "-c",
                                help="Path to config.yaml"),
    yes: bool = typer.Option(False, "--yes", "-y",
                             help="Skip confirmation prompt"),
    strict_host_key: bool = typer.Option(
        False, "--strict-host-key",
        help="Reject unknown SSH host keys (recommended after first run)"),
):
    """Run the full migration: discover, backup, transfer, restore, verify,
    heal. Safe to re-run — completed projects are skipped."""
    setup_logging()
    cfg = _load(config)

    console.print(Panel.fit(
        f"[bold]OpsLab Migrate v{__version__}[/]\n"
        f"Source:       [green]{cfg.source.username}@{cfg.source.host}[/]\n"
        f"Destination:  [green]{cfg.destination.username}@"
        f"{cfg.destination.host}[/]\n"
        f"Compression:  {cfg.backup.compression}   "
        f"Workers: {cfg.parallel_workers}   "
        f"Overwrite: {cfg.restore.overwrite}",
        border_style="blue"))

    if Path("migration_state.json").exists():
        console.print(f"{ARROW} Found existing migration_state.json — "
                      f"resuming where we left off\n")

    if not yes and not typer.confirm("Proceed with migration?"):
        raise typer.Exit(0)

    ui = LiveUI(cfg)
    orch = Orchestrator(cfg, status=ui.status,
                        strict_host_key=strict_host_key)

    summary: dict = {}
    try:
        with Live(ui.render(), console=console, refresh_per_second=4) as live:
            def refresher():
                while not stop.is_set():
                    live.update(ui.render())
                    time.sleep(0.25)

            stop = threading.Event()
            t = threading.Thread(target=refresher, daemon=True)
            t.start()
            try:
                # crude project-count estimation for the progress bar
                summary = orch.run()
                ui.total_projects = max(len(summary.get("projects", [])), 1)
                ui.progress.update(ui.task, completed=100)
            finally:
                stop.set()
                t.join(timeout=1)
                live.update(ui.render())
    except KeyboardInterrupt:
        console.print(f"\n{FAIL} Interrupted — state saved to "
                      f"migration_state.json. Re-run to resume.")
        raise typer.Exit(130)
    except Exception as e:  # noqa: BLE001
        console.print(f"\n{FAIL} [bold red]{e}[/]")
        console.print("State saved — re-run to resume. "
                      "See logs/errors.log for details.")
        raise typer.Exit(1)

    # ---- summary table -----------------------------------------------
    _print_summary(summary)
    paths = Reporter(summary).write_all()
    console.print(f"\n{OK} Reports written:")
    for kind, p in paths.items():
        console.print(f"   [dim]{kind.upper():5s}[/] {p}")

    failed = [p for p in summary.get("projects", [])
              if p.get("status") != "done"]
    raise typer.Exit(1 if failed else 0)


def _print_summary(summary: dict) -> None:
    table = Table(title="Migration summary", show_lines=False)
    table.add_column("Project", style="cyan")
    table.add_column("Framework")
    table.add_column("Status")
    table.add_column("Checks", justify="right")
    for p in summary.get("projects", []):
        checks = p.get("checks", [])
        passed = sum(1 for c in checks if c.get("passed"))
        ok = p.get("status") == "done"
        table.add_row(
            p["name"], p.get("framework", ""),
            f"{OK} done" if ok else f"{FAIL} {p.get('status')}",
            f"{passed}/{len(checks)}" if checks else "—")
    console.print()
    console.print(table)
    for w in summary.get("warnings", []):
        console.print(f"[yellow]⚠ {w}[/]")


@app.command()
def discover(
    config: Path = typer.Option("config.yaml", "--config", "-c"),
):
    """Scan the source server and list detected projects without migrating."""
    setup_logging()
    cfg = _load(config)
    from .discovery import Discoverer

    with console.status("[bold]Connecting to source…"):
        src = SSHConnection(cfg.source, strict_host_key=False)
        src.connect()
    console.print(f"{OK} Connected to {cfg.source.host}")
    with console.status("[bold]Scanning for projects…"):
        d = Discoverer(src, cfg.scan_roots, cfg.exclude_paths)
        projects = d.discover_all(only=cfg.projects)
    src.close()

    table = Table(title=f"Discovered projects on {cfg.source.host}")
    table.add_column("Project", style="cyan")
    table.add_column("Path", style="dim")
    table.add_column("Framework")
    table.add_column("Python")
    table.add_column("Services")
    table.add_column("Databases")
    table.add_column("Ports")
    for p in projects:
        table.add_row(
            p.name, p.path, p.framework, p.python_version,
            "\n".join(u.rsplit("/", 1)[-1] for u in p.systemd_units) or "—",
            "\n".join(f"{d['engine']}:{d['name']}"
                      for d in p.databases) or "—",
            ", ".join(map(str, p.listen_ports)) or "—")
    console.print(table)


@app.command()
def verify(
    config: Path = typer.Option("config.yaml", "--config", "-c"),
):
    """Re-run verification checks against the destination for all projects
    recorded in migration_state.json."""
    setup_logging()
    cfg = _load(config)
    import json

    from .verify import Verifier

    state_file = Path("migration_state.json")
    if not state_file.exists():
        console.print(f"{FAIL} No migration_state.json found — nothing to "
                      f"verify. Run a migration first.")
        raise typer.Exit(2)
    state = json.loads(state_file.read_text())

    dst = SSHConnection(cfg.destination, strict_host_key=False)
    dst.connect()
    v = Verifier(cfg, dst)
    exit_code = 0
    for name, entry in state.get("projects", {}).items():
        info = entry.get("info")
        if not info:
            continue
        rep = v.verify_project(info)
        icon = OK if rep.passed else FAIL
        console.print(f"\n{icon} [bold cyan]{name}[/]")
        for c in rep.checks:
            ic = OK if c.passed else FAIL
            detail = f" [dim]{c.detail}[/]" if c.detail else ""
            console.print(f"   {ic} {c.name}{detail}")
        if not rep.passed:
            exit_code = 1
    dst.close()
    raise typer.Exit(exit_code)


@app.command()
def reset(
    yes: bool = typer.Option(False, "--yes", "-y"),
):
    """Delete migration_state.json to force a fresh migration."""
    p = Path("migration_state.json")
    if not p.exists():
        console.print("No state file present.")
        return
    if yes or typer.confirm("Delete migration state (a re-run will start "
                            "from scratch)?"):
        p.unlink()
        console.print(f"{OK} State cleared")


@app.command()
def version():
    """Print version."""
    console.print(f"OpsLab Migrate v{__version__}")


def main() -> None:
    app()


if __name__ == "__main__":
    main()
