"""Top-level migration pipeline: discover → backup → transfer → restore →
verify → heal, with per-project state, resume, rollback, and parallelism."""

from __future__ import annotations

import concurrent.futures as cf
import threading
import time
from dataclasses import asdict
from typing import Callable, Optional

from .backup import BackupBuilder
from .config import Config
from .discovery import Discoverer, ProjectInfo
from .heal import Healer
from .logging_setup import get_logger
from .restore import Restorer
from .ssh import SSHConnection
from .state import MigrationState, Rollback
from .transfer import Transfer
from .verify import Verifier

log = get_logger("orchestrator")

StatusCB = Callable[[str, str], None]  # (project, message)


class Orchestrator:
    def __init__(self, cfg: Config, status: Optional[StatusCB] = None,
                 strict_host_key: bool = False):
        self.cfg = cfg
        self.status = status or (lambda p, m: None)
        self.state = MigrationState()
        self.strict = strict_host_key
        self.warnings: list[str] = []
        self.heal_actions: list[str] = []
        self._lock = threading.Lock()

    # ------------------------------------------------------------ plumbing

    def _connect_pair(self) -> tuple[SSHConnection, SSHConnection]:
        src = SSHConnection(self.cfg.source, strict_host_key=self.strict)
        dst = SSHConnection(self.cfg.destination, strict_host_key=self.strict)
        src.connect()
        dst.connect()
        return src, dst

    # ------------------------------------------------------------ pipeline

    def preflight(self, src: SSHConnection, dst: SSHConnection) -> list[str]:
        problems = []
        for conn, label in ((src, "source"), (dst, "destination")):
            r = conn.run("cat /etc/os-release")
            if "ubuntu" not in r.stdout.lower() and \
                    "debian" not in r.stdout.lower():
                problems.append(f"{label} is not Ubuntu/Debian")
            if conn.cfg.username != "root":
                if not conn.run("sudo -n true").ok:
                    problems.append(
                        f"{label}: user {conn.cfg.username} lacks "
                        f"passwordless sudo")
            free = conn.disk_free_mb("/")
            if free < 2048:
                problems.append(f"{label}: only {free} MB free disk")
        return problems

    def discover(self, src: SSHConnection) -> list[ProjectInfo]:
        self.status("*", "Scanning source server for projects")
        d = Discoverer(src, self.cfg.scan_roots, self.cfg.exclude_paths)
        projects = d.discover_all(only=self.cfg.projects)
        for p in projects:
            if not self.state.phase_reached(p.name, "discovered"):
                self.state.set_phase(p.name, "discovered",
                                     info=p.to_dict())
        return projects

    def migrate_project(self, proj: ProjectInfo, src: SSHConnection,
                        dst: SSHConnection) -> dict:
        """Run the full pipeline for one project. Uses dedicated SSH
        connections (passed in) so workers don't share channels."""
        name = proj.name
        st = self.state
        result: dict = {"name": name, "framework": proj.framework,
                        "databases": proj.databases, "status": "failed",
                        "checks": [], "size": 0, "sha256": ""}

        backup = BackupBuilder(src, self.cfg.backup.staging_dir,
                               self.cfg.backup.compression,
                               self.cfg.backup.include_venv)
        transfer = Transfer(self.cfg, src, dst)
        restorer = Restorer(self.cfg, dst)
        verifier = Verifier(self.cfg, dst)
        healer = Healer(self.cfg, dst)
        rollback = Rollback(dst)

        try:
            # ---- backup ------------------------------------------------
            if st.phase_reached(name, "backed_up"):
                info = st.project(name)
                archive, sha = info["archive"], info["sha256"]
                size = info.get("size", 0)
                self.status(name, "Backup already exists — skipping")
            else:
                self.status(name, "Backing up")
                backup.ensure_tools()
                b = backup.build(proj)
                archive, sha, size = b["archive"], b["sha256"], b["size"]
                st.set_phase(name, "backed_up", archive=archive,
                             sha256=sha, size=size)
            result["size"], result["sha256"] = size, sha

            # ---- transfer ----------------------------------------------
            if st.phase_reached(name, "transferred"):
                dest_archive = st.project(name)["dest_archive"]
                self.status(name, "Already transferred — skipping")
            else:
                self.status(name, "Transferring")
                t0 = time.time()
                dest_archive = transfer.send(
                    archive, self.cfg.backup.staging_dir, sha)
                st.set_phase(name, "transferred",
                             dest_archive=dest_archive,
                             transfer_seconds=time.time() - t0)
            result["transfer_seconds"] = st.project(name).get(
                "transfer_seconds", 0)

            # ---- restore -----------------------------------------------
            if st.phase_reached(name, "restored"):
                self.status(name, "Already restored — skipping")
            else:
                self.status(name, "Restoring")
                restorer.install_base_dependencies()
                try:
                    r = restorer.restore(
                        dest_archive,
                        status=lambda m: self.status(name, m))
                    st.set_phase(name, "restored",
                                 snapshot=r.get("snapshot", ""))
                except Exception as e:
                    log.error("Restore failed for %s: %s — rolling back",
                              name, e)
                    self.status(name, f"Restore failed — rolling back")
                    snap = st.project(name).get("snapshot", "")
                    rollback.rollback_project(proj.to_dict(), snap)
                    st.set_phase(name, "rolled_back", error=str(e))
                    result["status"] = "rolled_back"
                    result["error"] = str(e)
                    return result

            # ---- verify + heal -----------------------------------------
            if self.cfg.verify.enabled:
                self.status(name, "Verifying")
                rep = verifier.verify_project(proj.to_dict())
                if not rep.passed and self.cfg.heal.enabled:
                    self.status(name, "Self-healing")
                    rep = healer.heal(proj.to_dict(), rep)
                    with self._lock:
                        self.heal_actions.extend(
                            f"{name}: {a}" for a in healer.actions)
                result["checks"] = [asdict(c) for c in rep.checks]
                st.set_phase(name, "verified",
                             passed=rep.passed,
                             checks=result["checks"])
                if not rep.passed:
                    with self._lock:
                        self.warnings.append(
                            f"{name}: {len(rep.failures)} verification "
                            f"check(s) still failing after healing")

            st.set_phase(name, "done")
            result["status"] = "done"
            self.status(name, "Done")
        except Exception as e:  # noqa: BLE001 — never take down siblings
            log.exception("Migration of %s failed", name)
            st.set_phase(name, "failed", error=str(e))
            result["status"] = "failed"
            result["error"] = str(e)
            self.status(name, f"FAILED: {e}")
        finally:
            transfer.cleanup()
        return result

    # ----------------------------------------------------------------- run

    def run(self) -> dict:
        started = time.time()
        src, dst = self._connect_pair()
        summary: dict = {
            "source": self.cfg.source.host,
            "destination": self.cfg.destination.host,
            "projects": [],
            "warnings": self.warnings,
            "heal_actions": self.heal_actions,
        }
        try:
            self.status("*", "Running preflight checks")
            problems = self.preflight(src, dst)
            if problems:
                raise RuntimeError("Preflight failed: " + "; ".join(problems))

            projects = self.discover(src)
            if not projects:
                self.warnings.append("No Python web applications found")

            pending = [p for p in projects
                       if self.state.phase(p.name) != "done"]
            skipped = [p for p in projects
                       if self.state.phase(p.name) == "done"]
            for p in skipped:
                self.status(p.name, "Already migrated (resume)")
                summary["projects"].append(
                    {"name": p.name, "framework": p.framework,
                     "databases": p.databases, "status": "done",
                     "checks": self.state.project(p.name).get("checks", []),
                     "size": self.state.project(p.name).get("size", 0),
                     "sha256": self.state.project(p.name).get("sha256", "")})

            workers = min(self.cfg.parallel_workers, max(len(pending), 1))
            if workers <= 1 or len(pending) <= 1:
                for p in pending:
                    summary["projects"].append(
                        self.migrate_project(p, src, dst))
            else:
                # One SSH connection pair per worker
                def worker(p: ProjectInfo) -> dict:
                    wsrc, wdst = self._connect_pair()
                    try:
                        return self.migrate_project(p, wsrc, wdst)
                    finally:
                        wsrc.close()
                        wdst.close()

                with cf.ThreadPoolExecutor(max_workers=workers) as pool:
                    for res in pool.map(worker, pending):
                        summary["projects"].append(res)

            # Prune old backups on the source
            BackupBuilder(src, self.cfg.backup.staging_dir,
                          self.cfg.backup.compression).prune_old(
                self.cfg.backup.keep_days)
            summary["disk_free_mb"] = dst.disk_free_mb("/")
        finally:
            summary["duration_seconds"] = time.time() - started
            src.close()
            dst.close()
        return summary
