"""Self-healing: attempt automated repair of failed verification checks."""

from __future__ import annotations

import re
import shlex

from .config import Config
from .logging_setup import get_logger
from .ssh import SSHConnection
from .verify import Check, Verifier, VerifyReport

log = get_logger("heal")


class Healer:
    def __init__(self, cfg: Config, dst: SSHConnection):
        self.cfg = cfg
        self.dst = dst
        self.verifier = Verifier(cfg, dst)
        self.actions: list[str] = []

    def heal(self, proj: dict, report: VerifyReport) -> VerifyReport:
        """Attempt to repair failures, then re-verify. Repeats up to
        heal.max_attempts times."""
        if not self.cfg.heal.enabled:
            return report
        for attempt in range(1, self.cfg.heal.max_attempts + 1):
            if report.passed:
                break
            log.info("Heal attempt %d/%d for %s (%d failures)",
                     attempt, self.cfg.heal.max_attempts, proj["name"],
                     len(report.failures))
            fixed_any = False
            for check in report.failures:
                if self._repair(proj, check):
                    fixed_any = True
            if not fixed_any:
                log.warning("No repair strategy made progress — stopping")
                break
            report = self.verifier.verify_project(proj)
        return report

    # ---------------------------------------------------------------- fixes

    def _repair(self, proj: dict, check: Check) -> bool:
        name = check.name
        try:
            if name.startswith("service ") and "active" in name:
                return self._fix_service(name.split()[1], proj)
            if name.startswith("python import"):
                return self._fix_import(proj, check)
            if name.startswith("port ") or "HTTP" in name:
                return self._fix_service_all(proj)
            if name.startswith("nginx config"):
                return self._fix_nginx(check)
            if name.startswith("database"):
                return self._fix_database(name)
            if "disk space" in name:
                return self._fix_disk()
        except Exception as e:  # noqa: BLE001
            log.error("Repair for %r raised: %s", name, e)
        return False

    def _fix_service(self, unit: str, proj: dict) -> bool:
        q = shlex.quote(unit)
        # Read journal for the real cause
        j = self.dst.run(f"journalctl -u {q} -n 30 --no-pager", sudo=True)
        journal = j.stdout + j.stderr

        # Missing module → pip install into the venv
        m = re.search(r"No module named ['\"]?([A-Za-z0-9_.]+)", journal)
        if m and proj.get("venv_path"):
            mod = m.group(1).split(".")[0]
            pip_name = {"flask_sqlalchemy": "flask-sqlalchemy",
                        "dotenv": "python-dotenv",
                        "yaml": "pyyaml", "PIL": "pillow",
                        "psycopg2": "psycopg2-binary"}.get(mod, mod)
            log.info("Missing module %s — installing %s", mod, pip_name)
            self.dst.run(
                f"{shlex.quote(proj['venv_path'])}/bin/pip install "
                f"{shlex.quote(pip_name)}", sudo=True, timeout=600)
            self.actions.append(f"installed missing module {pip_name}")

        # Permission denied → re-own the tree
        if "Permission denied" in journal or "EACCES" in journal:
            owner = proj.get("owner") or "www-data"
            self.dst.run(
                f"chown -R {shlex.quote(owner)}:{shlex.quote(owner)} "
                f"{shlex.quote(proj['path'])}", sudo=True)
            self.actions.append(f"re-owned {proj['path']} to {owner}")

        # Broken symlinks inside the project
        self.dst.run(
            f"find {shlex.quote(proj['path'])} -xtype l -delete 2>/dev/null",
            sudo=True)

        # Missing gunicorn binary
        if "gunicorn" in journal and "No such file" in journal and \
                proj.get("venv_path"):
            self.dst.run(
                f"{shlex.quote(proj['venv_path'])}/bin/pip install gunicorn",
                sudo=True, timeout=600)
            self.actions.append("installed gunicorn")

        self.dst.run("systemctl daemon-reload", sudo=True)
        r = self.dst.run(f"systemctl restart {q}", sudo=True)
        ok = self.dst.run(
            f"sleep 2 && systemctl is-active {q}").stdout.strip() == "active"
        if ok:
            self.actions.append(f"restarted service {unit}")
        return ok

    def _fix_service_all(self, proj: dict) -> bool:
        any_ok = False
        for unit_path in proj.get("systemd_units", []):
            unit = unit_path.rsplit("/", 1)[-1]
            any_ok = self._fix_service(unit, proj) or any_ok
        return any_ok

    def _fix_import(self, proj: dict, check: Check) -> bool:
        venv = proj.get("venv_path", "")
        if not venv:
            return False
        # If the venv itself is broken, recreate it entirely
        if not self.dst.exists(f"{venv}/bin/python"):
            log.info("Recreating broken virtualenv %s", venv)
            self.dst.run(f"rm -rf {shlex.quote(venv)} && "
                         f"python3 -m venv {shlex.quote(venv)}",
                         sudo=True, timeout=300)
            self.actions.append(f"recreated virtualenv {venv}")
        req = f"{proj['path']}/requirements.txt"
        if self.dst.exists(req):
            r = self.dst.run(
                f"{shlex.quote(venv)}/bin/pip install -r {shlex.quote(req)}",
                sudo=True, timeout=3600)
            self.actions.append("reinstalled requirements.txt")
            return r.ok
        fw = proj.get("framework", "")
        if fw:
            r = self.dst.run(
                f"{shlex.quote(venv)}/bin/pip install {shlex.quote(fw)}",
                sudo=True, timeout=600)
            self.actions.append(f"installed {fw}")
            return r.ok
        return False

    def _fix_nginx(self, check: Check) -> bool:
        r = self.dst.run("nginx -t 2>&1", sudo=True)
        out = r.stdout + r.stderr
        # Duplicate default_server / conflicting server names — disable the
        # broken site so the rest of the server keeps working.
        m = re.search(r"in (/etc/nginx/\S+?):(\d+)", out)
        if m and "sites-enabled" in m.group(1):
            broken = m.group(1)
            log.warning("Disabling broken nginx site %s", broken)
            self.dst.run(f"rm -f {shlex.quote(broken)}", sudo=True)
            self.actions.append(f"disabled broken nginx site {broken}")
        # Missing ssl cert paths → comment out ssl lines is too invasive;
        # instead disable the site (handled above) or bail.
        r2 = self.dst.run("nginx -t 2>&1", sudo=True)
        if r2.ok:
            self.dst.run("systemctl reload nginx", sudo=True)
            return True
        return False

    def _fix_database(self, check_name: str) -> bool:
        # e.g. "database postgresql:mydb"
        m = re.match(r"database (\w+):", check_name)
        if not m:
            return False
        engine = m.group(1)
        svc = {"mysql": "mariadb", "mariadb": "mariadb",
               "postgresql": "postgresql", "mongodb": "mongod",
               "redis": "redis-server"}.get(engine)
        if not svc:
            return False
        r = self.dst.run(f"systemctl restart {svc}", sudo=True)
        if r.ok:
            self.actions.append(f"restarted {svc}")
        return r.ok

    def _fix_disk(self) -> bool:
        self.dst.run("apt-get clean && journalctl --vacuum-size=100M",
                     sudo=True)
        self.dst.run("rm -rf /var/tmp/opslab-migrate/*.extract", sudo=True)
        self.actions.append("cleaned apt cache, journals, extract dirs")
        return self.dst.disk_free_mb("/") > 1024
