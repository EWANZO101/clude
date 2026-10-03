"""Discover Python web applications, their services, and databases on the
source server."""

from __future__ import annotations

import json
import re
import shlex
from dataclasses import dataclass, field, asdict
from typing import Optional

from .ssh import SSHConnection
from .logging_setup import get_logger

log = get_logger("discovery")

MARKER_FILES = ("app.py", "wsgi.py", "manage.py", "main.py", "run.py",
                "application.py", "server.py", "requirements.txt",
                "pyproject.toml", "Pipfile", "setup.py")

# Files that on their own prove "this dir is an app", vs mere manifests
ENTRY_FILES = ("app.py", "wsgi.py", "manage.py", "main.py", "run.py",
               "application.py", "server.py")

FRAMEWORK_PATTERNS = {
    "flask": re.compile(r"\bflask\b", re.I),
    "fastapi": re.compile(r"\bfastapi\b", re.I),
    "quart": re.compile(r"\bquart\b", re.I),
    "django": re.compile(r"\bdjango\b", re.I),
}

DB_URI_RE = re.compile(
    r"""(?:SQLALCHEMY_DATABASE_URI|DATABASE_URL)\s*[:=]\s*["']?"""
    r"""(?P<uri>[a-z0-9+]+://[^\s"']+|sqlite:///[^\s"']+)""",
    re.I,
)

SCHEME_TO_ENGINE = {
    "sqlite": "sqlite",
    "mysql": "mysql",
    "mariadb": "mariadb",
    "postgres": "postgresql",
    "postgresql": "postgresql",
    "mongodb": "mongodb",
    "redis": "redis",
}


@dataclass
class DatabaseInfo:
    engine: str                 # sqlite | mysql | mariadb | postgresql | mongodb | redis
    uri: str                    # raw URI (redacted before logging)
    name: str = ""
    host: str = "localhost"
    port: int = 0
    user: str = ""
    password: str = ""          # never logged — see config.redact
    sqlite_path: str = ""


@dataclass
class ProjectInfo:
    name: str
    path: str
    framework: str = "unknown"
    python_version: str = ""
    venv_path: str = ""
    uses_poetry: bool = False
    uses_pipenv: bool = False
    requirements_file: str = ""
    wsgi_server: str = ""       # gunicorn | uwsgi | ""
    process_manager: str = ""   # systemd | supervisor | docker | ""
    systemd_units: list = field(default_factory=list)
    supervisor_configs: list = field(default_factory=list)
    nginx_configs: list = field(default_factory=list)
    apache_configs: list = field(default_factory=list)
    docker_compose: str = ""
    databases: list = field(default_factory=list)  # list[DatabaseInfo]
    listen_ports: list = field(default_factory=list)
    owner: str = ""
    group: str = ""

    def to_dict(self) -> dict:
        d = asdict(self)
        return d


class Discoverer:
    def __init__(self, ssh: SSHConnection, scan_roots: list[str],
                 exclude_paths: list[str]):
        self.ssh = ssh
        self.scan_roots = scan_roots
        self.exclude = exclude_paths

    # ------------------------------------------------------------------ scan

    def find_project_roots(self) -> list[str]:
        """Locate candidate project directories.

        Two independent strategies, merged:
        1. systemd units that run python/gunicorn/uwsgi — reads their
           WorkingDirectory/ExecStart paths (most reliable for deployed apps,
           and finds apps living outside the scan roots)
        2. filesystem scan for marker files under scan_roots
        """
        roots: set[str] = set()
        roots |= self._roots_from_systemd()
        roots |= self._roots_from_scan()

        # Never treat scan roots or home dirs themselves as a project —
        # a stray requirements.txt in /root must not swallow every project
        # under it.
        top_level = set(r.rstrip("/") for r in self.scan_roots)
        home_dirs = set()
        r = self.ssh.run("ls -d /home/*/ 2>/dev/null", sudo=True)
        home_dirs |= {p.rstrip("/") for p in r.stdout.split()}
        blocked = top_level | home_dirs | {"/root", "/home"}
        roots = {p for p in roots if p.rstrip("/") not in blocked}
        # Never migrate this tool itself
        roots = {p for p in roots
                 if not self.ssh.exists(f"{p}/migratekit/orchestrator.py")}

        # Collapse nested candidates, but never swallow a child that has its
        # own entry file (app.py etc.) unless the parent has one too — two
        # real apps can be nested in a projects/ folder that happens to have
        # a manifest.
        entry_cache: dict[str, bool] = {}

        def has_entry(path: str) -> bool:
            if path not in entry_cache:
                names = " -o ".join(
                    f"-name {shlex.quote(e)}" for e in ENTRY_FILES)
                rr = self.ssh.run(
                    f"find {shlex.quote(path)} -maxdepth 1 "
                    f"\\( {names} \\) -print -quit 2>/dev/null", sudo=True)
                entry_cache[path] = bool(rr.stdout.strip())
            return entry_cache[path]

        collapsed: list[str] = []
        for p in sorted(roots, key=lambda x: x.count("/")):
            parent = next((c for c in collapsed
                           if p.startswith(c + "/")), None)
            if parent is None:
                collapsed.append(p)
            elif has_entry(p) and not has_entry(parent):
                # parent was manifest-only — the child is the real app
                collapsed.append(p)
        # Drop manifest-only parents whose children were kept
        final = [p for p in collapsed
                 if not any(c != p and c.startswith(p + "/") and
                            has_entry(c) and not has_entry(p)
                            for c in collapsed)]
        log.info("Found %d candidate project roots: %s", len(final), final)
        return sorted(final)

    def _roots_from_systemd(self) -> set[str]:
        roots: set[str] = set()
        r = self.ssh.run(
            "grep -lE '(python|gunicorn|uwsgi|flask|uvicorn)' "
            "/etc/systemd/system/*.service 2>/dev/null", sudo=True)
        for unit in r.stdout.split():
            content = self.ssh.run(f"cat {shlex.quote(unit)}",
                                   sudo=True).stdout
            m = re.search(r"^WorkingDirectory=(\S+)", content, re.M)
            if m and self.ssh.exists(m.group(1)):
                roots.add(m.group(1).rstrip("/"))
                continue
            # Fall back to the directory of the ExecStart script/venv
            m = re.search(r"^ExecStart=.*?(/\S+?)/(?:venv|\.venv)/bin/",
                          content, re.M)
            if m and self.ssh.exists(m.group(1)):
                roots.add(m.group(1).rstrip("/"))
        if roots:
            log.info("systemd-based discovery found: %s", sorted(roots))
        return roots

    def _roots_from_scan(self) -> set[str]:
        excludes = " ".join(
            f"-path {shlex.quote(p)} -prune -o" for p in self.exclude
        )
        # Prune junk *inside find itself* — venv site-packages contain
        # thousands of setup.py/requirements.txt files that would otherwise
        # exhaust the result limit before real projects are reached.
        prune_names = ("venv", ".venv", "env", "virtualenv", "node_modules",
                       "site-packages", "dist-packages", ".git", ".cache",
                       "__pycache__")
        prunes = " ".join(
            f"-name {shlex.quote(n)} -prune -o" for n in prune_names)
        names = " -o ".join(f"-name {shlex.quote(m)}" for m in MARKER_FILES)
        roots: set[str] = set()
        for root in self.scan_roots:
            if not self.ssh.exists(root):
                continue
            # Pass 1: marker files
            cmd = (
                f"find {shlex.quote(root)} {excludes} {prunes} "
                f"\\( {names} \\) -type f -print 2>/dev/null | head -20000"
            )
            r = self.ssh.run(cmd, sudo=True, timeout=600)
            for line in r.stdout.splitlines():
                line = line.strip()
                if line:
                    roots.add(line.rsplit("/", 1)[0])
            # Pass 2: any directory that owns a virtualenv is almost
            # certainly a deployed app, whatever its files are called
            cmd = (
                f"find {shlex.quote(root)} -maxdepth 4 {excludes} "
                f"\\( -name venv -o -name .venv \\) -type d "
                f"-print 2>/dev/null | head -1000"
            )
            r = self.ssh.run(cmd, sudo=True, timeout=600)
            for line in r.stdout.splitlines():
                line = line.strip()
                if not line:
                    continue
                parent = line.rsplit("/", 1)[0]
                if self.ssh.exists(f"{line}/bin/python") and \
                        parent.rstrip("/") not in ("", "/root", "/home"):
                    roots.add(parent)
        return roots

    # ------------------------------------------------------------ per project

    def inspect(self, path: str) -> ProjectInfo:
        name = path.rstrip("/").rsplit("/", 1)[-1]
        proj = ProjectInfo(name=name, path=path)

        listing = self.ssh.run(
            f"ls -A {shlex.quote(path)} 2>/dev/null", sudo=True).stdout.split()

        # Ownership
        st = self.ssh.run(
            f"stat -c '%U %G' {shlex.quote(path)}", sudo=True)
        if st.ok and st.stdout.split():
            proj.owner, proj.group = (st.stdout.split() + ["", ""])[:2]

        # Dependency manifests
        if "requirements.txt" in listing:
            proj.requirements_file = f"{path}/requirements.txt"
        proj.uses_poetry = "pyproject.toml" in listing and self._file_contains(
            f"{path}/pyproject.toml", r"\[tool\.poetry\]")
        proj.uses_pipenv = "Pipfile" in listing

        # Framework
        proj.framework = self._detect_framework(path, listing)

        # Virtualenv
        for cand in (".venv", "venv", "env", "virtualenv"):
            if cand in listing and self.ssh.exists(f"{path}/{cand}/bin/python"):
                proj.venv_path = f"{path}/{cand}"
                break

        # Python version
        py = f"{proj.venv_path}/bin/python" if proj.venv_path else "python3"
        r = self.ssh.run(f"{shlex.quote(py)} --version 2>&1", sudo=True)
        m = re.search(r"(\d+\.\d+(\.\d+)?)", r.stdout + r.stderr)
        proj.python_version = m.group(1) if m else ""

        # WSGI server
        for srv in ("gunicorn", "uwsgi"):
            if proj.venv_path and self.ssh.exists(f"{proj.venv_path}/bin/{srv}"):
                proj.wsgi_server = srv
                break
            if self._file_contains(proj.requirements_file, srv):
                proj.wsgi_server = srv
                break

        # Services / process manager
        self._detect_services(proj)
        # Web server configs
        self._detect_webserver(proj)
        # Databases
        proj.databases = [asdict(db) for db in self._detect_databases(path)]
        # Listening ports (best-effort, from configs)
        proj.listen_ports = self._detect_ports(proj)

        log.info("Inspected %s: framework=%s services=%s dbs=%d",
                 path, proj.framework, proj.systemd_units,
                 len(proj.databases))
        return proj

    # --------------------------------------------------------------- helpers

    def _file_contains(self, path: str, pattern: str) -> bool:
        if not path:
            return False
        r = self.ssh.run(f"grep -lE {shlex.quote(pattern)} "
                         f"{shlex.quote(path)} 2>/dev/null", sudo=True)
        return r.ok and bool(r.stdout.strip())

    def _detect_framework(self, path: str, listing: list[str]) -> str:
        # Manifest first — most reliable
        for manifest in ("requirements.txt", "pyproject.toml", "Pipfile"):
            if manifest not in listing:
                continue
            content = self.ssh.run(
                f"cat {shlex.quote(path + '/' + manifest)}", sudo=True).stdout
            for fw, pat in FRAMEWORK_PATTERNS.items():
                if pat.search(content):
                    return fw
        if "manage.py" in listing:
            return "django"
        # Fall back to imports in entry files
        for entry in ("app.py", "wsgi.py", "main.py"):
            if entry not in listing:
                continue
            content = self.ssh.run(
                f"head -100 {shlex.quote(path + '/' + entry)}",
                sudo=True).stdout
            for fw, pat in FRAMEWORK_PATTERNS.items():
                if pat.search(content):
                    return fw
        return "unknown"

    def _detect_services(self, proj: ProjectInfo) -> None:
        q = shlex.quote(proj.path)
        # systemd units referencing the project path
        r = self.ssh.run(
            f"grep -rl {q} /etc/systemd/system/*.service 2>/dev/null",
            sudo=True)
        proj.systemd_units = [u.strip() for u in r.stdout.splitlines() if u.strip()]
        if proj.systemd_units:
            proj.process_manager = "systemd"

        # supervisor
        r = self.ssh.run(
            f"grep -rl {q} /etc/supervisor/conf.d/ 2>/dev/null", sudo=True)
        proj.supervisor_configs = [u.strip() for u in r.stdout.splitlines()
                                   if u.strip()]
        if proj.supervisor_configs and not proj.process_manager:
            proj.process_manager = "supervisor"

        # docker compose in project dir
        for f in ("docker-compose.yml", "docker-compose.yaml", "compose.yml",
                  "compose.yaml"):
            if self.ssh.exists(f"{proj.path}/{f}"):
                proj.docker_compose = f"{proj.path}/{f}"
                if not proj.process_manager:
                    proj.process_manager = "docker"
                break

    def _detect_webserver(self, proj: ProjectInfo) -> None:
        q = shlex.quote(proj.path)
        r = self.ssh.run(
            f"grep -rl {q} /etc/nginx/sites-available/ /etc/nginx/conf.d/ "
            f"2>/dev/null", sudo=True)
        proj.nginx_configs = [u.strip() for u in r.stdout.splitlines()
                              if u.strip()]
        # Also match by port if proxy_pass points at project's gunicorn port
        r = self.ssh.run(
            f"grep -rl {q} /etc/apache2/sites-available/ 2>/dev/null",
            sudo=True)
        proj.apache_configs = [u.strip() for u in r.stdout.splitlines()
                               if u.strip()]

    def _detect_databases(self, path: str) -> list[DatabaseInfo]:
        found: dict[str, DatabaseInfo] = {}
        for cfg in (".env", "config.py", "settings.py", "instance/config.py",
                    "app/config.py"):
            full = f"{path}/{cfg}"
            if not self.ssh.exists(full):
                continue
            content = self.ssh.run(f"cat {shlex.quote(full)}", sudo=True).stdout
            for m in DB_URI_RE.finditer(content):
                uri = m.group("uri")
                db = self._parse_uri(uri, path)
                if db:
                    found[db.uri] = db
        # Fallback: any *.db / *.sqlite3 file in project root or instance/
        r = self.ssh.run(
            f"find {shlex.quote(path)} -maxdepth 2 "
            f"\\( -name '*.db' -o -name '*.sqlite3' -o -name '*.sqlite' \\) "
            f"-type f 2>/dev/null | head -10", sudo=True)
        for line in r.stdout.splitlines():
            line = line.strip()
            if line and not any(d.sqlite_path == line for d in found.values()):
                found[line] = DatabaseInfo(
                    engine="sqlite", uri=f"sqlite:///{line}",
                    sqlite_path=line, name=line.rsplit("/", 1)[-1])
        return list(found.values())

    def _parse_uri(self, uri: str, project_path: str) -> Optional[DatabaseInfo]:
        m = re.match(r"([a-z0-9]+)(?:\+[a-z0-9]+)?://(.*)", uri, re.I)
        if not m:
            return None
        engine = SCHEME_TO_ENGINE.get(m.group(1).lower())
        if not engine:
            return None
        db = DatabaseInfo(engine=engine, uri=uri)
        if engine == "sqlite":
            p = uri.split("///", 1)[-1]
            if not p.startswith("/"):
                p = f"{project_path}/{p}"
            db.sqlite_path = p
            db.name = p.rsplit("/", 1)[-1]
            return db
        rest = m.group(2)
        cred, _, hostpart = rest.rpartition("@")
        if cred:
            user, _, pw = cred.partition(":")
            db.user, db.password = user, pw
        hostport, _, dbname = hostpart.partition("/")
        host, _, port = hostport.partition(":")
        db.host = host or "localhost"
        db.port = int(port) if port.isdigit() else 0
        db.name = dbname.split("?")[0]
        return db

    def _detect_ports(self, proj: ProjectInfo) -> list[int]:
        ports: set[int] = set()
        for unit in proj.systemd_units:
            content = self.ssh.run(f"cat {shlex.quote(unit)}", sudo=True).stdout
            for m in re.finditer(r"(?:--bind|-b)[= ][\d.]*:(\d+)", content):
                ports.add(int(m.group(1)))
            for m in re.finditer(r"--port[= ](\d+)", content):
                ports.add(int(m.group(1)))
        for ngx in proj.nginx_configs:
            content = self.ssh.run(f"cat {shlex.quote(ngx)}", sudo=True).stdout
            for m in re.finditer(r"listen\s+(?:[\d.]+:)?(\d+)", content):
                ports.add(int(m.group(1)))
        return sorted(ports)

    # ------------------------------------------------------------------ main

    def discover_all(self, only: Optional[list[str]] = None) -> list[ProjectInfo]:
        roots = self.find_project_roots()
        projects: list[ProjectInfo] = []
        for root in roots:
            if only and not any(
                    root == o or root.rsplit("/", 1)[-1] == o for o in only):
                continue
            try:
                projects.append(self.inspect(root))
            except Exception as e:  # noqa: BLE001 — continue past bad project
                log.error("Failed to inspect %s: %s", root, e)
        return projects
