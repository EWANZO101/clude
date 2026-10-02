"""Product build pipeline (admin-only, triggered from a ticket).

Each build:
  1. copies the source (an uploaded folder, or a folder already on this VM)
     into its own new directory under PRODUCTS_ROOT,
  2. creates a dedicated PostgreSQL role + database with a random password,
  3. builds a venv and installs requirements (+ gunicorn, psycopg2),
  4. writes .env with DATABASE_URL / SECRET_KEY, runs migrations if present,
  5. installs + starts a systemd gunicorn service on a free local port,
  6. health-checks it and posts the result to the ticket. The DB credentials
     are stored encrypted and shown in the ticket behind a "Reveal" button.

The pipeline runs outside gunicorn (via systemd-run) so a web reload never
kills a build:  python -m app.product_builder run <build_id>
"""
import base64
import hashlib
import http.client
import json
import os
import re
import secrets
import shutil
import socket
import subprocess
import sys
import time
import traceback
from datetime import datetime

PRODUCTS_ROOT = os.environ.get("PRODUCTS_ROOT", "/srv/opslabs-products")
STAGING_ROOT = os.environ.get("BUILD_STAGING_ROOT", "/var/lib/opslabs/build-staging")
LOG_ROOT = os.environ.get("BUILD_LOG_ROOT", "/var/lib/opslabs/builds")
SERVICE_USER = os.environ.get("PRODUCT_SERVICE_USER", "opslab-prod")
PORT_RANGE = range(6400, 7000)
APP_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))   # /root/opslabs

# Never copy these out of a source folder.
COPY_IGNORE = shutil.ignore_patterns("venv", ".venv", "env", "__pycache__", "*.pyc",
                                     ".git", "node_modules", ".mypy_cache", ".pytest_cache")
# Source paths on the VM that must never be used as a product source.
FORBIDDEN_SOURCES = ("/", "/etc", "/proc", "/sys", "/dev", "/boot", "/bin", "/sbin",
                     "/lib", "/lib64", "/usr", "/var", "/var/lib", "/var/lib/postgresql",
                     "/root", "/home", "/run", "/tmp", "/snap")


class BuildError(Exception):
    pass


# ---------- secrets ----------
def _fernet():
    from cryptography.fernet import Fernet
    secret = os.environ.get("SECRET_KEY", "change-me-in-production-please")
    key = base64.urlsafe_b64encode(hashlib.sha256(("product-build:" + secret).encode()).digest())
    return Fernet(key)


def encrypt(text):
    return _fernet().encrypt(text.encode()).decode()


def decrypt(token):
    return _fernet().decrypt(token.encode()).decode()


# ---------- helpers ----------
def slugify(name):
    s = re.sub(r"[^a-z0-9]+", "-", (name or "").lower()).strip("-")
    return (s or "product")[:40]


def ensure_dirs():
    for d in (PRODUCTS_ROOT, STAGING_ROOT, LOG_ROOT):
        os.makedirs(d, mode=0o755, exist_ok=True)


def log_path(build_id):
    return os.path.join(LOG_ROOT, f"{int(build_id)}.log")


def validate_source_path(path):
    """Admin typed a folder on this VM — make sure it's a sane source."""
    if not path or not path.startswith("/"):
        raise BuildError("Enter an absolute folder path, e.g. /root/myproduct")
    real = os.path.realpath(path)
    if not os.path.isdir(real):
        raise BuildError(f"Folder not found: {path}")
    if real.rstrip("/") in FORBIDDEN_SOURCES or real == "/":
        raise BuildError("That folder can't be used as a product source.")
    for root in (PRODUCTS_ROOT, STAGING_ROOT, LOG_ROOT, APP_DIR):
        r = os.path.realpath(root)
        if real == r or real.startswith(r + "/") or r.startswith(real + "/"):
            raise BuildError("That folder overlaps the OpsLabs system folders.")
    return real


def safe_relpath(rel):
    """Relative path from a browser folder upload -> safe normalised path or None."""
    rel = (rel or "").replace("\\", "/").lstrip("/")
    parts = [p for p in rel.split("/") if p not in ("", ".")]
    if not parts or any(p == ".." or "\x00" in p for p in parts):
        return None
    return "/".join(parts)


def detect_wsgi(src):
    """Find the Flask app gunicorn should serve, as 'module:object'."""
    manifest = os.path.join(src, "opslab.json")
    if os.path.isfile(manifest):
        try:
            with open(manifest) as f:
                target = (json.load(f) or {}).get("wsgi")
            if target and re.match(r"^[A-Za-z_][\w.]*:[A-Za-z_]\w*(\(\))?$", target):
                return target
        except (OSError, ValueError):
            pass

    def defines(fname, var):
        p = os.path.join(src, fname)
        if not os.path.isfile(p):
            return False
        with open(p, errors="ignore") as f:
            return re.search(rf"^{var}\s*=", f.read(), re.M) is not None

    for fname, mod in (("wsgi.py", "wsgi"), ("run.py", "run"), ("app.py", "app"),
                       ("main.py", "main"), ("server.py", "server")):
        for var in ("application", "app"):
            if defines(fname, var):
                return f"{mod}:{var}"
    for entry in sorted(os.listdir(src)):
        init = os.path.join(src, entry, "__init__.py")
        if os.path.isfile(init):
            with open(init, errors="ignore") as f:
                if re.search(r"^def create_app\(", f.read(), re.M):
                    return f"{entry}:create_app()"
    raise BuildError("Couldn't find the Flask app. Add an opslab.json with "
                     '{"wsgi": "module:app"} to the product folder.')


def free_port(taken):
    for port in PORT_RANGE:
        if port in taken:
            continue
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            try:
                s.bind(("127.0.0.1", port))
            except OSError:
                continue
        return port
    raise BuildError("No free ports left for products (6400–6999).")


def read_env_file(path):
    env = {}
    if os.path.isfile(path):
        with open(path, errors="ignore") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    env[k.strip()] = v.strip()
    return env


def write_env_file(path, env):
    with open(path, "w") as f:
        f.write("# Written by the OpsLabs product builder.\n")
        for k, v in env.items():
            f.write(f"{k}={v}\n")
    os.chmod(path, 0o600)


class Runner:
    def __init__(self, build, log):
        self.build = build
        self.log = log

    def say(self, msg):
        self.log.write(f"[{datetime.utcnow():%H:%M:%S}] {msg}\n")
        self.log.flush()

    def run(self, cmd, cwd=None, env=None, timeout=900, stdin=None, check=True):
        shown = " ".join(cmd)
        self.say(f"$ {shown}")
        p = subprocess.run(cmd, cwd=cwd, env=env, input=stdin, text=True,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
        if p.stdout:
            self.log.write(p.stdout if p.stdout.endswith("\n") else p.stdout + "\n")
            self.log.flush()
        if check and p.returncode != 0:
            raise BuildError(f"Command failed ({p.returncode}): {shown}")
        return p

    def psql(self, sql, **vars_):
        cmd = ["runuser", "-u", "postgres", "--", "psql", "-X", "-q", "-v", "ON_ERROR_STOP=1"]
        for k, v in vars_.items():
            cmd += ["-v", f"{k}={v}"]
        cmd += ["-f", "-"]
        # Don't echo passwords into the log.
        self.say("$ psql (" + ", ".join(k for k in vars_) + ")")
        p = subprocess.run(cmd, input=sql, text=True, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, timeout=120)
        if p.returncode != 0:
            self.log.write(p.stdout + "\n")
            raise BuildError("PostgreSQL command failed (see log).")


def _ensure_service_user(r):
    if subprocess.run(["id", "-u", SERVICE_USER], capture_output=True).returncode != 0:
        r.run(["useradd", "--system", "--no-create-home", "--shell", "/usr/sbin/nologin", SERVICE_USER])


def _unit_path(service_name):
    return f"/etc/systemd/system/{service_name}.service"


def run_build(build_id):
    from dotenv import load_dotenv
    load_dotenv(os.path.join(APP_DIR, ".env"))
    sys.path.insert(0, APP_DIR)
    from app import create_app, db
    from app.models import ProductBuild, TicketMessage

    app = create_app()
    with app.app_context():
        b = ProductBuild.query.get(build_id)
        if not b or b.status not in ("queued", "running"):
            return
        ensure_dirs()
        with open(log_path(b.id), "a") as log:
            r = Runner(b, log)

            def step(text):
                b.step = text
                db.session.commit()
                r.say(f"== {text}")

            b.status = "running"
            db.session.commit()
            try:
                _pipeline(b, r, step, ProductBuild)
                b.status = "success"
                b.step = "Live"
                b.finished_at = datetime.utcnow()
                db.session.add(TicketMessage(
                    ticket_id=b.ticket_id, source="system",
                    body=(f"🚀 Product build #{b.id} “{b.name}” is live. "
                          f"Database credentials are on this ticket — click “Reveal” under Product builds.")))
                db.session.commit()
                r.say("Build finished successfully.")
                _notify_ticket(app, b, f"🚀 Product build #{b.id} “{b.name}” is live. "
                                       f"Database credentials are on the website ticket (Reveal button).")
            except Exception as e:
                db.session.rollback()
                b = ProductBuild.query.get(build_id)
                msg = str(e) if isinstance(e, BuildError) else f"Unexpected error: {e}"
                r.say("BUILD FAILED: " + msg)
                if not isinstance(e, BuildError):
                    log.write(traceback.format_exc())
                b.status = "failed"
                b.error = msg[:2000]
                b.finished_at = datetime.utcnow()
                db.session.add(TicketMessage(
                    ticket_id=b.ticket_id, source="system", is_internal=True,
                    body=f"Product build #{b.id} “{b.name}” failed at “{b.step}”: {msg[:500]}"))
                db.session.commit()


def _notify_ticket(app, b, text):
    url = app.config.get("DISCORD_BOT_URL")
    t = b.ticket
    if not url or not t or not t.discord_channel_id:
        return
    try:
        import requests
        requests.post(url.rstrip("/") + "/discord/ticket/message", timeout=4,
                      headers={"X-Bridge-Key": app.config.get("DISCORD_BRIDGE_KEY", "")},
                      json={"channel_id": t.discord_channel_id, "ticket_id": t.id,
                            "author": "OpsLab Builder", "author_role": "system", "body": text})
    except Exception:
        pass


def _pipeline(b, r, step, ProductBuild):
    from app import db

    step("Preparing folder")
    target = os.path.join(PRODUCTS_ROOT, f"{b.slug}-{b.id}")
    if os.path.exists(target):
        raise BuildError(f"Target folder already exists: {target}")
    src = b.source_path
    if b.source_type == "path":
        src = validate_source_path(src)
    elif not (os.path.isdir(src) and os.path.realpath(src).startswith(os.path.realpath(STAGING_ROOT) + "/")):
        raise BuildError("Uploaded folder is missing — please upload it again.")
    # A browser folder upload wraps everything in the folder's own name; unwrap it.
    entries = [e for e in os.listdir(src) if not e.startswith(".")]
    if b.source_type == "upload" and len(entries) == 1 and os.path.isdir(os.path.join(src, entries[0])):
        src = os.path.join(src, entries[0])
    shutil.copytree(src, target, ignore=COPY_IGNORE, symlinks=False)
    b.target_dir = target
    db.session.commit()
    r.say(f"Copied {src} -> {target}")
    if b.source_type == "upload":
        shutil.rmtree(b.source_path, ignore_errors=True)

    wsgi = detect_wsgi(target)
    b.wsgi_target = wsgi
    r.say(f"Flask app: {wsgi}")

    step("Creating database")
    ident = re.sub(r"[^a-z0-9_]", "_", b.slug.replace("-", "_"))[:40]
    b.db_name = f"p{b.id}_{ident}"[:63]
    b.db_user = f"p{b.id}_{ident}_u"[:63]
    password = secrets.token_urlsafe(24)
    b.db_host, b.db_port = "127.0.0.1", 5432
    b.db_password_enc = encrypt(password)
    db.session.commit()
    r.psql("CREATE ROLE :\"u\" LOGIN PASSWORD :'pw';\n"
           "CREATE DATABASE :\"d\" OWNER :\"u\";\n"
           "REVOKE ALL ON DATABASE :\"d\" FROM PUBLIC;\n",
           u=b.db_user, pw=password, d=b.db_name)
    r.run(["psql", "-X", "-h", "127.0.0.1", "-U", b.db_user, "-d", b.db_name, "-Atc", "select 1"],
          env={**os.environ, "PGPASSWORD": password}, timeout=30)
    r.say(f"Database {b.db_name} ready (user {b.db_user}).")

    step("Installing Python packages")
    r.run(["/usr/bin/python3", "-m", "venv", "venv"], cwd=target, timeout=300)
    pip = os.path.join(target, "venv", "bin", "pip")
    r.run([pip, "install", "-q", "--upgrade", "pip"], cwd=target, timeout=600)
    if os.path.isfile(os.path.join(target, "requirements.txt")):
        r.run([pip, "install", "-q", "-r", "requirements.txt"], cwd=target, timeout=1800)
    r.run([pip, "install", "-q", "gunicorn", "psycopg2-binary", "python-dotenv"], cwd=target, timeout=600)

    step("Configuring")
    taken = {p for (p,) in db.session.query(ProductBuild.app_port).filter(ProductBuild.app_port.isnot(None))}
    b.app_port = free_port(taken)
    db.session.commit()
    db_url = f"postgresql://{b.db_user}:{password}@{b.db_host}:{b.db_port}/{b.db_name}"
    env = read_env_file(os.path.join(target, ".env"))
    env.update({
        "DATABASE_URL": db_url,
        "SQLALCHEMY_DATABASE_URI": db_url,
        "PORT": str(b.app_port),
        "FLASK_DEBUG": "false",
    })
    env.setdefault("SECRET_KEY", secrets.token_hex(32))
    write_env_file(os.path.join(target, ".env"), env)

    if os.path.isfile(os.path.join(target, "migrations", "env.py")):
        step("Running database migrations")
        flask = os.path.join(target, "venv", "bin", "flask")
        if os.path.isfile(flask):
            r.run([flask, "--app", wsgi, "db", "upgrade"], cwd=target,
                  env={**os.environ, **env}, timeout=600)

    step("Starting service")
    _ensure_service_user(r)
    r.run(["chown", "-R", f"{SERVICE_USER}:{SERVICE_USER}", target])
    b.service_name = f"opslab-product-{b.slug}-{b.id}"
    db.session.commit()
    unit = f"""[Unit]
Description=OpsLab product: {b.name} (build #{b.id}, ticket #{b.ticket_id})
After=network.target postgresql.service

[Service]
User={SERVICE_USER}
Group={SERVICE_USER}
WorkingDirectory={target}
EnvironmentFile={target}/.env
ExecStart={target}/venv/bin/gunicorn -w 2 -b 127.0.0.1:{b.app_port} --timeout 60 {wsgi}
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
ProtectSystem=full
PrivateTmp=true

[Install]
WantedBy=multi-user.target
"""
    with open(_unit_path(b.service_name), "w") as f:
        f.write(unit)
    r.run(["systemctl", "daemon-reload"])
    r.run(["systemctl", "enable", "--now", b.service_name])

    step("Health check")
    deadline = time.time() + 45
    last = None
    while time.time() < deadline:
        try:
            c = http.client.HTTPConnection("127.0.0.1", b.app_port, timeout=5)
            c.request("GET", "/")
            status = c.getresponse().status
            c.close()
            r.say(f"GET / -> {status}")
            if status < 500:
                return
            last = f"HTTP {status}"
        except OSError as e:
            last = str(e)
        time.sleep(2)
    r.run(["journalctl", "-u", b.service_name, "-n", "40", "--no-pager"], check=False)
    raise BuildError(f"The app didn't start on port {b.app_port} ({last}). See the build log.")


def launch(build_id):
    """Start run_build in its own transient systemd unit (survives web reloads)."""
    ensure_dirs()
    py = os.path.join(APP_DIR, "venv", "bin", "python")
    cmd = [py, "-m", "app.product_builder", "run", str(int(build_id))]
    try:
        subprocess.run(["systemd-run", "--quiet", "--collect", f"--unit=opslab-build-{int(build_id)}",
                        f"--working-directory={APP_DIR}", *cmd],
                       check=True, capture_output=True, timeout=20)
    except (OSError, subprocess.SubprocessError):
        with open(log_path(build_id), "a") as log:
            subprocess.Popen(cmd, cwd=APP_DIR, stdout=log, stderr=subprocess.STDOUT,
                             start_new_session=True)


def remove_build(b, log=None):
    """Stop the service, drop the database + role, delete the folder."""
    out = []

    def sh(cmd, **kw):
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=120, **kw)
        out.append(f"$ {' '.join(cmd)} -> {p.returncode} {p.stdout.strip()} {p.stderr.strip()}".strip())
        return p

    if b.service_name and re.match(r"^opslab-product-[a-z0-9-]+$", b.service_name):
        sh(["systemctl", "disable", "--now", b.service_name])
        try:
            os.remove(_unit_path(b.service_name))
        except OSError:
            pass
        sh(["systemctl", "daemon-reload"])
    if b.db_name and re.match(r"^p\d+_[a-z0-9_]+$", b.db_name):
        sh(["runuser", "-u", "postgres", "--", "psql", "-X", "-v", "ON_ERROR_STOP=1",
            "-v", f"d={b.db_name}", "-v", f"u={b.db_user}", "-f", "-"],
           input='DROP DATABASE IF EXISTS :"d" WITH (FORCE);\nDROP ROLE IF EXISTS :"u";\n')
    if b.target_dir:
        real = os.path.realpath(b.target_dir)
        if real.startswith(os.path.realpath(PRODUCTS_ROOT) + "/"):
            shutil.rmtree(real, ignore_errors=True)
    if b.source_type == "upload" and b.source_path.startswith(STAGING_ROOT + "/"):
        shutil.rmtree(b.source_path, ignore_errors=True)
    with open(log_path(b.id), "a") as f:
        f.write(f"[{datetime.utcnow():%H:%M:%S}] == Removed\n" + "\n".join(out) + "\n")
    return out


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "run":
        run_build(int(sys.argv[2]))
    else:
        print("usage: python -m app.product_builder run <build_id>")
        sys.exit(2)
