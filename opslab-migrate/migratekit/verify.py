"""Post-restore verification checks on the destination host."""

from __future__ import annotations

import shlex
from dataclasses import dataclass, field

from .config import Config
from .logging_setup import get_logger
from .ssh import SSHConnection

log = get_logger("verify")


@dataclass
class Check:
    name: str
    passed: bool
    detail: str = ""


@dataclass
class VerifyReport:
    project: str
    checks: list = field(default_factory=list)

    @property
    def passed(self) -> bool:
        return all(c.passed for c in self.checks)

    @property
    def failures(self) -> list:
        return [c for c in self.checks if not c.passed]


class Verifier:
    def __init__(self, cfg: Config, dst: SSHConnection):
        self.cfg = cfg
        self.dst = dst

    def verify_project(self, proj: dict) -> VerifyReport:
        rep = VerifyReport(project=proj["name"])
        add = rep.checks.append

        # ---- systemd services ------------------------------------------
        for unit_path in proj.get("systemd_units", []):
            unit = unit_path.rsplit("/", 1)[-1]
            r = self.dst.run(f"systemctl is-active {shlex.quote(unit)}")
            add(Check(f"service {unit} active", r.stdout.strip() == "active",
                      r.stdout.strip() or r.stderr.strip()))

        # ---- ports listening -------------------------------------------
        for port in proj.get("listen_ports", []):
            r = self.dst.run(
                f"ss -ltn 2>/dev/null | grep -q ':{port} ' && echo yes")
            add(Check(f"port {port} listening", "yes" in r.stdout,
                      "" if "yes" in r.stdout else "not listening"))

        # ---- HTTP / HTTPS ------------------------------------------------
        checked_http = False
        for port in proj.get("listen_ports", []):
            for scheme in ("http", "https"):
                if scheme == "https" and port not in (443,):
                    continue
                r = self.dst.run(
                    f"curl -k -s -o /dev/null -w '%{{http_code}}' "
                    f"--max-time {self.cfg.verify.http_timeout} "
                    f"{scheme}://127.0.0.1:{port}/")
                code = r.stdout.strip()
                if code and code != "000":
                    ok = code.isdigit() and int(code) < 500
                    add(Check(f"{scheme.upper()} :{port} responds",
                              ok, f"status {code}"))
                    checked_http = True
        if not checked_http and proj.get("listen_ports"):
            add(Check("HTTP response", False, "no port answered"))

        # ---- Python imports ----------------------------------------------
        venv = proj.get("venv_path")
        fw = proj.get("framework", "")
        if venv and fw in ("flask", "fastapi", "quart", "django"):
            py = f"{venv}/bin/python"
            r = self.dst.run(
                f"{shlex.quote(py)} -c 'import {fw}' 2>&1")
            add(Check(f"python import {fw}", r.ok, r.stderr.strip()[:200]
                      or r.stdout.strip()[:200]))

        # ---- databases ----------------------------------------------------
        for db in proj.get("databases", []):
            add(self._check_db(db))

        # ---- nginx --------------------------------------------------------
        if proj.get("nginx_configs"):
            r = self.dst.run("nginx -t 2>&1", sudo=True)
            add(Check("nginx config valid", r.ok,
                      "" if r.ok else (r.stdout + r.stderr)[:200]))

        # ---- resources ----------------------------------------------------
        disk = self.dst.disk_free_mb("/")
        add(Check("disk space > 1GB free", disk > 1024, f"{disk} MB free"))
        mem = self.dst.memory_free_mb()
        add(Check("memory > 256MB available", mem > 256, f"{mem} MB available"))

        log.info("Verification for %s: %d/%d checks passed",
                 proj["name"],
                 sum(1 for c in rep.checks if c.passed), len(rep.checks))
        for c in rep.failures:
            log.warning("FAILED: %s — %s", c.name, c.detail)
        return rep

    def _check_db(self, db: dict) -> Check:
        engine = db.get("engine", "")
        name = db.get("name", "")
        label = f"database {engine}:{name}"
        try:
            if engine == "sqlite":
                path = db.get("sqlite_path", "")
                ok = bool(path) and self.dst.exists(path)
                return Check(label, ok, path if ok else f"missing: {path}")
            if engine in ("mysql", "mariadb"):
                r = self.dst.run(
                    f"mysql -e 'USE `{name}`; SELECT 1' >/dev/null 2>&1 "
                    f"&& echo ok", sudo=True)
                return Check(label, "ok" in r.stdout, r.stderr[:150])
            if engine == "postgresql":
                r = self.dst.run(
                    f"sudo -u postgres psql -d {shlex.quote(name)} "
                    f"-c 'SELECT 1' >/dev/null 2>&1 && echo ok")
                return Check(label, "ok" in r.stdout, r.stderr[:150])
            if engine == "mongodb":
                r = self.dst.run(
                    f"mongosh --quiet --eval 'db.getMongo()' >/dev/null 2>&1 "
                    f"&& echo ok || (mongo --quiet --eval 'db.getMongo()' "
                    f">/dev/null 2>&1 && echo ok)")
                return Check(label, "ok" in r.stdout, r.stderr[:150])
            if engine == "redis":
                r = self.dst.run("redis-cli PING")
                return Check(label, "PONG" in r.stdout, r.stderr[:150])
        except Exception as e:  # noqa: BLE001
            return Check(label, False, str(e)[:200])
        return Check(label, False, f"unknown engine {engine}")
