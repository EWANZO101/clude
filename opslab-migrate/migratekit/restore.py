"""Restore a project archive on the destination host."""

from __future__ import annotations

import json
import shlex
import time

from .config import Config
from .database import DatabaseHandler
from .logging_setup import get_logger
from .ssh import SSHConnection

log = get_logger("restore")

BASE_PACKAGES = (
    "python3 python3-pip python3-venv build-essential libpq-dev "
    "default-mysql-client postgresql-client nginx rsync curl"
)

DECOMPRESS = {
    ".tar.zst": "--zstd",
    ".tar.gz": "-z",
    ".tar.xz": "-J",
}


class Restorer:
    def __init__(self, cfg: Config, dst: SSHConnection):
        self.cfg = cfg
        self.dst = dst
        self.db = DatabaseHandler(dst)
        self._deps_done = False

    # -------------------------------------------------------- dependencies

    def install_base_dependencies(self) -> None:
        if self._deps_done or not self.cfg.restore.install_dependencies:
            return
        log.info("Installing base packages on destination")
        self.dst.run("DEBIAN_FRONTEND=noninteractive apt-get update -qq",
                     sudo=True, timeout=900)
        self.dst.run(
            f"DEBIAN_FRONTEND=noninteractive apt-get install -y "
            f"{BASE_PACKAGES}", sudo=True, timeout=1800)
        if not self.dst.which("zstd"):
            self.dst.run("DEBIAN_FRONTEND=noninteractive apt-get install -y "
                         "zstd xz-utils", sudo=True, timeout=600)
        self._deps_done = True

    # -------------------------------------------------------------- restore

    def restore(self, archive_path: str, manifest_hint: dict | None = None,
                status=lambda msg: None) -> dict:
        """Full restore of one archive. Returns per-step result dict."""
        q = shlex.quote
        result: dict = {"steps": {}, "project": ""}
        ext = next((e for e in DECOMPRESS if archive_path.endswith(e)), None)
        if ext is None:
            raise RuntimeError(f"Unknown archive type: {archive_path}")
        flag = DECOMPRESS[ext]

        work = archive_path[: -len(ext)] + ".extract"
        status("Extracting archive")
        self.dst.run(f"rm -rf {q(work)} && mkdir -p {q(work)}", sudo=True,
                     check=True)
        self.dst.run(f"tar {flag} -xf {q(archive_path)} -C {q(work)}",
                     sudo=True, check=True, timeout=7200)
        result["steps"]["extract"] = True

        manifest = json.loads(
            self.dst.read_file(f"{work}/manifest.json", sudo=True))
        proj = manifest["project"]
        result["project"] = proj["name"]
        target = proj["path"]

        # ---- pre-restore snapshot for rollback -------------------------
        snapshot = ""
        if self.dst.exists(target):
            if not self.cfg.restore.overwrite:
                raise RuntimeError(
                    f"{target} already exists on destination and "
                    f"restore.overwrite is false")
            snapshot = f"{target}.pre-migrate.{int(time.time())}"
            status("Snapshotting existing directory")
            self.dst.run(f"mv {q(target)} {q(snapshot)}", sudo=True,
                         check=True)
        result["snapshot"] = snapshot

        try:
            # ---- application tree --------------------------------------
            status("Placing application files")
            self.dst.run(
                f"mkdir -p $(dirname {q(target)}) && "
                f"mv {q(work)}/app {q(target)}", sudo=True, check=True)
            result["steps"]["files"] = True

            # ---- ownership + permissions -------------------------------
            status("Restoring ownership and permissions")
            self._restore_permissions(proj, manifest.get("permissions", ""))
            result["steps"]["permissions"] = True

            # ---- virtualenv --------------------------------------------
            status("Recreating virtual environment")
            self._restore_venv(proj)
            result["steps"]["venv"] = True

            # ---- databases ---------------------------------------------
            status("Restoring databases")
            db_ok = self._restore_databases(manifest, work, proj)
            result["steps"]["databases"] = db_ok

            # ---- system configs ----------------------------------------
            status("Restoring services and web server")
            self._restore_system(work, proj)
            result["steps"]["system"] = True

            # ---- start services ----------------------------------------
            if self.cfg.restore.restart_services:
                status("Starting services")
                self._start_services(proj)
                result["steps"]["services"] = True
        finally:
            self.dst.run(f"rm -rf {q(work)}", sudo=True)

        result["manifest"] = manifest
        return result

    # --------------------------------------------------------------- steps

    def _restore_permissions(self, proj: dict, perms: str) -> None:
        q = shlex.quote
        owner = proj.get("owner") or "root"
        group = proj.get("group") or owner
        # Ensure owner exists on destination
        if self.dst.run(f"id -u {q(owner)}").ok is False:
            self.dst.run(
                f"useradd -r -m -s /usr/sbin/nologin {q(owner)}", sudo=True)
        self.dst.run(f"chown -R {q(owner)}:{q(group)} {q(proj['path'])}",
                     sudo=True)
        # Fine-grained modes from the manifest (batch via a script)
        if perms:
            lines = []
            for row in perms.splitlines()[:100000]:
                try:
                    rel, mode, u, g = row.split("|")
                except ValueError:
                    continue
                if rel in (".", ""):
                    continue
                full = f"{proj['path']}/{rel[2:]}" if rel.startswith("./") \
                    else f"{proj['path']}/{rel}"
                lines.append(f"chmod {mode} {shlex.quote(full)} 2>/dev/null")
                if (u, g) != (owner, group):
                    lines.append(f"chown {shlex.quote(u)}:{shlex.quote(g)} "
                                 f"{shlex.quote(full)} 2>/dev/null")
            if lines:
                script = "\n".join(lines)
                self.dst.write_file("/tmp/.mk_perms.sh", script, sudo=True,
                                    mode="700")
                self.dst.run("bash /tmp/.mk_perms.sh; rm -f /tmp/.mk_perms.sh",
                             sudo=True, timeout=1800)

    def _restore_venv(self, proj: dict) -> None:
        q = shlex.quote
        path = proj["path"]
        pyver = proj.get("python_version", "")
        # Try to match the source's minor Python version if available
        py = "python3"
        if pyver:
            minor = ".".join(pyver.split(".")[:2])
            if self.dst.which(f"python{minor}"):
                py = f"python{minor}"
        venv = proj.get("venv_path") or f"{path}/venv"
        # venv from archive is excluded — always rebuild
        self.dst.run(f"rm -rf {q(venv)}", sudo=True)
        self.dst.run(f"{py} -m venv {q(venv)}", sudo=True, check=True,
                     timeout=300)
        pip = f"{venv}/bin/pip"
        self.dst.run(f"{q(pip)} install --upgrade pip wheel", sudo=True,
                     timeout=600)

        if proj.get("uses_poetry"):
            self.dst.run(f"{q(pip)} install poetry", sudo=True, timeout=600)
            self.dst.run(
                f"cd {q(path)} && {q(venv)}/bin/poetry install --no-root "
                f"--only main", sudo=True, timeout=3600)
        elif proj.get("uses_pipenv"):
            self.dst.run(f"{q(pip)} install pipenv", sudo=True, timeout=600)
            self.dst.run(
                f"cd {q(path)} && VIRTUAL_ENV={q(venv)} "
                f"{q(venv)}/bin/pipenv install --deploy --system",
                sudo=True, timeout=3600)
        elif proj.get("requirements_file"):
            req = f"{path}/requirements.txt"
            if self.dst.exists(req):
                self.dst.run_retry(
                    f"{q(pip)} install -r {q(req)}", retries=2, sudo=True,
                    timeout=3600)
        if proj.get("wsgi_server"):
            self.dst.run(f"{q(pip)} install {proj['wsgi_server']}",
                         sudo=True, timeout=600)
        owner = proj.get("owner") or "root"
        self.dst.run(f"chown -R {q(owner)}:{q(owner)} {q(venv)}", sudo=True)

    def _restore_databases(self, manifest: dict, work: str,
                           proj: dict) -> bool:
        all_ok = True
        engines_needed = {d["db"]["engine"] for d in manifest.get(
            "db_dumps", []) if d.get("dump")}
        self._ensure_db_servers(engines_needed)
        for entry in manifest.get("db_dumps", []):
            if not entry.get("dump"):
                continue
            dump_rel = entry["dump"].rsplit("/db/", 1)[-1]
            dump_path = f"{work}/db/{dump_rel}"
            db = dict(entry["db"])
            # Recover password from destination .env if present (never stored
            # in manifest)
            db.setdefault("password", self._password_from_env(proj, db))
            ok = self.db.restore(db, dump_path)
            all_ok = all_ok and ok
            log.info("Database %s (%s): %s", db.get("name"),
                     db.get("engine"), "restored" if ok else "FAILED")
        return all_ok

    def _password_from_env(self, proj: dict, db: dict) -> str:
        """The .env travelled inside the app tree — re-parse it on the
        destination to obtain credentials for restore."""
        import re
        for cfg in (".env", "config.py", "settings.py", "instance/config.py"):
            path = f"{proj['path']}/{cfg}"
            if not self.dst.exists(path):
                continue
            content = self.dst.read_file(path, sudo=True)
            m = re.search(
                r"://" + re.escape(db.get("user", "")) + r":([^@\s\"']+)@",
                content)
            if m:
                return m.group(1)
        return ""

    def _ensure_db_servers(self, engines: set) -> None:
        if not self.cfg.restore.install_dependencies:
            return
        pkg_map = {
            "mysql": "mariadb-server",
            "mariadb": "mariadb-server",
            "postgresql": "postgresql",
            "mongodb": "mongodb-org mongodb",  # tries both
            "redis": "redis-server",
        }
        for engine in engines:
            pkgs = pkg_map.get(engine)
            if not pkgs:
                continue
            check = {"mysql": "mysqld|mariadbd", "mariadb": "mariadbd|mysqld",
                     "postgresql": "postgres", "mongodb": "mongod",
                     "redis": "redis-server"}[engine]
            if self.dst.run(f"pgrep -f '{check}' >/dev/null").ok:
                continue
            log.info("Installing %s server on destination", engine)
            for pkg in pkgs.split():
                r = self.dst.run(
                    f"DEBIAN_FRONTEND=noninteractive apt-get install -y {pkg}",
                    sudo=True, timeout=1800)
                if r.ok:
                    break
            svc = {"mysql": "mariadb", "mariadb": "mariadb",
                   "postgresql": "postgresql", "mongodb": "mongod",
                   "redis": "redis-server"}[engine]
            self.dst.run(f"systemctl enable --now {svc}", sudo=True)

    def _restore_system(self, work: str, proj: dict) -> None:
        q = shlex.quote
        # systemd units
        r = self.dst.run(f"ls {q(work)}/system/systemd 2>/dev/null",
                         sudo=True)
        units = [u for u in r.stdout.split() if u.endswith(".service")]
        for unit in units:
            self.dst.run(
                f"cp -a {q(work)}/system/systemd/{q(unit)} "
                f"/etc/systemd/system/", sudo=True, check=True)
        # supervisor
        r = self.dst.run(f"ls {q(work)}/system/supervisor 2>/dev/null",
                         sudo=True)
        for conf in r.stdout.split():
            self.dst.run("mkdir -p /etc/supervisor/conf.d", sudo=True)
            self.dst.run(
                f"cp -a {q(work)}/system/supervisor/{q(conf)} "
                f"/etc/supervisor/conf.d/", sudo=True)
        # nginx
        r = self.dst.run(f"ls {q(work)}/system/nginx 2>/dev/null", sudo=True)
        sites = r.stdout.split()
        for site in sites:
            self.dst.run(
                f"cp -a {q(work)}/system/nginx/{q(site)} "
                f"/etc/nginx/sites-available/", sudo=True, check=True)
            self.dst.run(
                f"ln -sf /etc/nginx/sites-available/{q(site)} "
                f"/etc/nginx/sites-enabled/{q(site)}", sudo=True)
        # apache
        r = self.dst.run(f"ls {q(work)}/system/apache 2>/dev/null", sudo=True)
        for site in r.stdout.split():
            self.dst.run("mkdir -p /etc/apache2/sites-available", sudo=True)
            self.dst.run(
                f"cp -a {q(work)}/system/apache/{q(site)} "
                f"/etc/apache2/sites-available/ && a2ensite {q(site)} "
                f"2>/dev/null", sudo=True)

    def _start_services(self, proj: dict) -> None:
        self.dst.run("systemctl daemon-reload", sudo=True)
        for unit_path in proj.get("systemd_units", []):
            unit = unit_path.rsplit("/", 1)[-1]
            self.dst.run(f"systemctl enable --now {shlex.quote(unit)}",
                         sudo=True)
            self.dst.run(f"systemctl restart {shlex.quote(unit)}", sudo=True)
        if proj.get("supervisor_configs"):
            self.dst.run("supervisorctl reread && supervisorctl update",
                         sudo=True)
        if proj.get("docker_compose"):
            compose_dir = proj["docker_compose"].rsplit("/", 1)[0]
            self.dst.run(
                f"cd {shlex.quote(compose_dir)} && "
                f"(docker compose up -d || docker-compose up -d)",
                sudo=True, timeout=1800)
        if proj.get("nginx_configs") or proj.get("apache_configs"):
            r = self.dst.run("nginx -t", sudo=True)
            if r.ok:
                self.dst.run("systemctl reload nginx || "
                             "systemctl restart nginx", sudo=True)
            else:
                log.error("nginx config test failed: %s", r.stderr[:400])
