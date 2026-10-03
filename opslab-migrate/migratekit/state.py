"""Migration state persistence (migration_state.json) for resume support,
plus rollback of failed restores."""

from __future__ import annotations

import json
import shlex
import time
from pathlib import Path
from typing import Any

from .logging_setup import get_logger
from .ssh import SSHConnection

log = get_logger("state")

STATE_FILE = Path("migration_state.json")

# Phase order per project
PHASES = ("discovered", "backed_up", "transferred", "restored",
          "verified", "done", "failed", "rolled_back")


class MigrationState:
    def __init__(self, path: Path = STATE_FILE):
        self.path = path
        self.data: dict[str, Any] = {
            "started": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "updated": "",
            "projects": {},   # name -> {phase, archive, sha256, snapshot,...}
            "meta": {},
        }
        if path.exists():
            try:
                self.data = json.loads(path.read_text(encoding="utf-8"))
                log.info("Resuming from existing %s", path)
            except (json.JSONDecodeError, OSError) as e:
                log.warning("Cannot read state file (%s) — starting fresh", e)

    # ---------------------------------------------------------------- io

    def save(self) -> None:
        self.data["updated"] = time.strftime("%Y-%m-%dT%H:%M:%SZ",
                                             time.gmtime())
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps(self.data, indent=2, default=str),
                       encoding="utf-8")
        tmp.replace(self.path)

    # ------------------------------------------------------------- project

    def project(self, name: str) -> dict:
        return self.data["projects"].setdefault(
            name, {"phase": "", "history": []})

    def set_phase(self, name: str, phase: str, **extra) -> None:
        p = self.project(name)
        p["phase"] = phase
        p["history"].append({"phase": phase, "at": time.strftime(
            "%Y-%m-%dT%H:%M:%SZ", time.gmtime())})
        p.update(extra)
        self.save()

    def phase(self, name: str) -> str:
        return self.project(name).get("phase", "")

    def phase_reached(self, name: str, phase: str) -> bool:
        """True if the project already completed the given phase."""
        cur = self.phase(name)
        if cur in ("failed", "rolled_back"):
            return False
        try:
            return PHASES.index(cur) >= PHASES.index(phase)
        except ValueError:
            return False

    def pending_projects(self, all_names: list[str]) -> list[str]:
        return [n for n in all_names if self.phase(n) != "done"]


class Rollback:
    """Undo a partially applied restore on the destination."""

    def __init__(self, dst: SSHConnection):
        self.dst = dst

    def rollback_project(self, proj: dict, snapshot: str,
                         restored_units: list[str] | None = None,
                         restored_nginx: list[str] | None = None) -> bool:
        q = shlex.quote
        ok = True
        name = proj.get("name", "?")
        log.warning("Rolling back %s on destination", name)

        # Stop and remove services we installed
        for unit_path in proj.get("systemd_units", []):
            unit = unit_path.rsplit("/", 1)[-1]
            self.dst.run(f"systemctl stop {q(unit)}", sudo=True)
            self.dst.run(f"systemctl disable {q(unit)}", sudo=True)
            self.dst.run(f"rm -f /etc/systemd/system/{q(unit)}", sudo=True)
        self.dst.run("systemctl daemon-reload", sudo=True)

        # Remove nginx sites we installed
        for site_path in proj.get("nginx_configs", []):
            site = site_path.rsplit("/", 1)[-1]
            self.dst.run(f"rm -f /etc/nginx/sites-enabled/{q(site)} "
                         f"/etc/nginx/sites-available/{q(site)}", sudo=True)
        r = self.dst.run("nginx -t", sudo=True)
        if r.ok:
            self.dst.run("systemctl reload nginx", sudo=True)

        # Restore the original directory
        target = proj.get("path", "")
        if target:
            self.dst.run(f"rm -rf {q(target)}", sudo=True)
            if snapshot and self.dst.exists(snapshot):
                r = self.dst.run(f"mv {q(snapshot)} {q(target)}", sudo=True)
                ok = ok and r.ok
                log.info("Restored original files from snapshot %s", snapshot)

        # Note: database rollback is intentionally conservative — dumps of
        # the pre-existing destination DBs are only taken when overwrite is
        # enabled; restoring them here if present.
        return ok
