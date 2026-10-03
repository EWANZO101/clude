import os
import re
import secrets
import subprocess

CLONE_DIR = "/home/snaily-cadv4"
REPO_URL = "https://github.com/SnailyCAD/snaily-cadv4.git"
DB_NAME = "snaily-cadv4"
DB_USER = "snailycad"


class SnailyCadError(Exception):
    pass


def _run(args, cwd=None, timeout=900, env=None):
    try:
        result = subprocess.run(
            args, cwd=cwd, capture_output=True, text=True, timeout=timeout, check=False, env=env
        )
    except FileNotFoundError as exc:
        raise SnailyCadError(f"'{args[0]}' isn't available on this host.") from exc
    except subprocess.TimeoutExpired as exc:
        raise SnailyCadError(f"Command timed out after {timeout}s: {' '.join(args)}") from exc

    if result.returncode != 0:
        raise SnailyCadError((result.stderr or result.stdout or "command failed").strip()[-1500:])
    return result


# ---- Step 1: system preparation ----

def system_prepare(log):
    log("Running apt update")
    _run(["apt-get", "update", "-y"], timeout=300)
    log("Running apt upgrade")
    _run(["apt-get", "upgrade", "-y"], timeout=1200)
    log("Installing git, curl, build tools")
    _run(["apt-get", "install", "-y", "git", "curl", "build-essential"], timeout=600)


# ---- Step 2: Node.js 22, npm, pnpm ----

def install_node(log):
    log("Adding NodeSource repo for Node.js 22")
    setup = subprocess.run(
        ["curl", "-fsSL", "https://deb.nodesource.com/setup_22.x"],
        capture_output=True, text=True, timeout=60,
    )
    if setup.returncode != 0:
        raise SnailyCadError("Failed to fetch NodeSource setup script.")
    result = subprocess.run(["bash", "-"], input=setup.stdout, capture_output=True, text=True, timeout=120)
    if result.returncode != 0:
        raise SnailyCadError(f"NodeSource setup script failed: {result.stderr.strip()[-800:]}")

    log("Installing nodejs")
    _run(["apt-get", "install", "-y", "nodejs"], timeout=300)

    log("Enabling pnpm via corepack")
    _run(["corepack", "enable"])
    _run(["corepack", "prepare", "pnpm@latest", "--activate"])


# ---- Step 3: PostgreSQL 16 ----

def install_postgres(log):
    log("Installing PostgreSQL 16")
    _run(["apt-get", "install", "-y", "postgresql-16", "postgresql-contrib"], timeout=600)

    password = secrets.token_urlsafe(24)
    log(f"Creating database '{DB_NAME}' and user '{DB_USER}'")

    _run(["sudo", "-u", "postgres", "psql", "-c",
          f"CREATE USER {DB_USER} WITH PASSWORD '{password}';"])
    _run(["sudo", "-u", "postgres", "psql", "-c",
          f'CREATE DATABASE "{DB_NAME}" OWNER {DB_USER};'])

    return password


# ---- Step 4: clone ----

def clone_repo(log):
    if os.path.exists(CLONE_DIR):
        raise SnailyCadError(f"{CLONE_DIR} already exists — remove it first or use Repair instead.")
    log(f"Cloning {REPO_URL} into {CLONE_DIR}")
    _run(["git", "clone", REPO_URL, CLONE_DIR], timeout=300)


# ---- Step 5: install deps ----

def pnpm_install(log):
    log("Running pnpm install (this can take a while)")
    _run(["pnpm", "install"], cwd=CLONE_DIR, timeout=1200)


# ---- Step 6: environment ----

def write_env(log, db_password):
    env_path = os.path.join(CLONE_DIR, ".env")
    database_url = f"postgresql://{DB_USER}:{db_password}@localhost:5432/{DB_NAME}?schema=public"

    log("Writing .env")
    lines = []
    if os.path.exists(env_path):
        with open(env_path, "r", encoding="utf-8") as f:
            lines = f.readlines()

    def _upsert(lines, key, value):
        pattern = re.compile(rf"^{re.escape(key)}=")
        for i, line in enumerate(lines):
            if pattern.match(line):
                lines[i] = f"{key}={value}\n"
                return lines
        lines.append(f"{key}={value}\n")
        return lines

    lines = _upsert(lines, "DATABASE_URL", database_url)
    lines = _upsert(lines, "DATABASE_USER", DB_USER)
    lines = _upsert(lines, "DATABASE_PASSWORD", db_password)

    try:
        with open(env_path, "w", encoding="utf-8") as f:
            f.writelines(lines)
        os.chmod(env_path, 0o600)
    except PermissionError as exc:
        raise SnailyCadError(f"No permission to write {env_path}.") from exc


# ---- Step 8: build ----

def pnpm_build(log):
    log("Running pnpm run build (this can take several minutes)")
    _run(["pnpm", "run", "build"], cwd=CLONE_DIR, timeout=1800)


# ---- Verification ----

def verify_installed():
    return os.path.isdir(CLONE_DIR) and os.path.exists(os.path.join(CLONE_DIR, ".env"))
