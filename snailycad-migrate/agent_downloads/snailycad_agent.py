#!/usr/bin/env python3
"""
SnailyCAD Migration Platform — remote agent.

Run this ON the machine that has the SnailyCAD install (or the machine
you want to restore one onto). It connects OUT to the migration platform
over plain HTTPS/HTTP — nothing needs to be reachable, port-forwarded, or
opened on this machine's firewall/router. Only outbound access to the
platform's URL is required, same as any normal web browsing.

Requires only the Python 3 standard library — nothing to pip install.

Usage:
    python3 snailycad_agent.py --server https://your-platform.example.com --token abc123...

The server URL and token are shown on the platform's "Agent" job page
after you start an export or import there.
"""

import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
import zipfile

# Mirrors app/exports/service.py — kept in sync manually; the server also
# sends its own copy of these at handshake time so a stale agent still
# collects the right things.
DEFAULT_KNOWN_CONFIG_PATHS = [
    ".env", "apps/api/.env", "apps/client/.env",
    "apps/api/prisma/schema.prisma", "docker-compose.yml", "package.json",
]
DEFAULT_KNOWN_UPLOAD_DIRS = ["apps/api/uploads", "uploads", "public/uploads"]
DEFAULT_KNOWN_CAD_CONFIG_PATHS = ["apps/api/src/config", "cad-config.json"]

# When this script is downloaded from a job's status page, the platform
# fills these in with the actual server URL and one-time token, so the
# Windows/Linux launchers can double-click-run it with zero arguments.
# Left as None in the generic/manually-downloaded copy — in that case
# --server/--token become required command-line arguments instead.
EMBEDDED_SERVER = None
EMBEDDED_TOKEN = None

AGENT_VERSION = "1.0.0"


def log(msg):
    print(f"[agent] {msg}", flush=True)


def sha256_of_file(path, chunk_size=1024 * 1024):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(chunk_size), b""):
            h.update(chunk)
    return h.hexdigest()


def detect_os():
    system = platform.system().lower()
    if system.startswith("win"):
        return "windows"
    if system.startswith("linux"):
        return "linux"
    return system or "unknown"


def clean_path(value):
    """
    Strips whitespace and a matching pair of surrounding quotes. Handles
    paths pasted from Windows Explorer's "Copy as path" (which wraps the
    result in double quotes) or anyone who typed quotes around a path
    with spaces in it.
    """
    if value is None:
        return value
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in ('"', "'"):
        value = value[1:-1].strip()
    return value


def find_db_tool(tool_name):
    """
    Locates pg_dump/psql without relying on PATH being set up correctly.
    Tries PATH first (shutil.which), then — on Windows — scans the
    standard PostgreSQL install locations directly, since the installer
    doesn't always add itself to PATH and picking the right versioned
    folder by hand trips people up. Returns a full path if found, else
    just the bare tool name (so the normal "not found" error still fires
    with a clear message).
    """
    found = shutil.which(tool_name)
    if found:
        return found

    if detect_os() == "windows":
        import glob
        candidates = []
        for base in (r"C:\Program Files\PostgreSQL", r"C:\Program Files (x86)\PostgreSQL"):
            candidates.extend(glob.glob(os.path.join(base, "*", "bin", f"{tool_name}.exe")))

        def version_key(path):
            # .../PostgreSQL/16/bin/psql.exe -> sort by the version folder, newest first
            parts = path.split(os.sep)
            try:
                idx = parts.index("PostgreSQL")
                return int(parts[idx + 1])
            except (ValueError, IndexError):
                return -1

        candidates.sort(key=version_key, reverse=True)
        if candidates:
            log(f"Found {tool_name} at {candidates[0]} (not on PATH, but no matter)")
            return candidates[0]

    return tool_name


def run_db_tool(cmd, env, tool_name):
    """
    Runs pg_dump/psql and raises a clear, actionable error if the tool
    itself isn't installed/on PATH — the raw OS error for that
    ("[WinError 2] The system cannot find the file specified" on Windows,
    "No such file or directory" on Linux) doesn't say what's actually
    missing. Auto-discovers the binary if it exists but isn't on PATH.
    """
    resolved = find_db_tool(tool_name)
    cmd = [resolved] + cmd[1:]

    try:
        return subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=1800)
    except FileNotFoundError as e:
        if detect_os() == "windows":
            hint = (
                f"'{tool_name}' isn't installed anywhere I could find it.\n"
                f"       It ships with PostgreSQL — install it from "
                f"https://www.postgresql.org/download/windows/ (Command Line Tools "
                f"component is enough if you don't need the full server)."
            )
        else:
            hint = (
                f"'{tool_name}' isn't installed, or isn't on this machine's PATH.\n"
                f"       Install the postgresql-client package (e.g. apt install postgresql-client) "
                f"and try again."
            )
        raise RuntimeError(hint) from e


def human_size(num_bytes):
    """Formats a byte count as something a person would actually say, e.g. '45.2 MB'."""
    if num_bytes is None:
        return "unknown size"
    size = float(num_bytes)
    for unit in ("bytes", "KB", "MB", "GB", "TB"):
        if size < 1024 or unit == "TB":
            return f"{size:.1f} {unit}" if unit != "bytes" else f"{int(size)} bytes"
        size /= 1024


def print_progress_bar(current, total, prefix="", bar_width=30):
    """Draws a plain-text progress bar on the same terminal line, updating in place."""
    if not total or total <= 0:
        return
    fraction = min(current / total, 1.0)
    filled = int(bar_width * fraction)
    bar = "#" * filled + "-" * (bar_width - filled)
    percent = int(fraction * 100)
    line = f"\r{prefix} [{bar}] {percent}%  ({human_size(current)} of {human_size(total)})"
    sys.stdout.write(line.ljust(len(line) + 5))
    sys.stdout.flush()
    if current >= total:
        sys.stdout.write("\n")
        sys.stdout.flush()


class ApiClient:
    def __init__(self, server, token):
        self.server = server.rstrip("/")
        self.token = token
        self.job_id = None  # set after handshake, used for progress reporting

    def _url(self, path):
        return f"{self.server}{path}"

    def post_json(self, path, payload):
        data = json.dumps(payload).encode("utf-8")
        req = urllib.request.Request(
            self._url(path), data=data,
            headers={"Content-Type": "application/json", "X-Agent-Token": self.token},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.loads(resp.read().decode("utf-8"))

    def report_progress(self, message, percent=None):
        """
        Sends a plain-English status update to the platform so the web
        page can show it live. Best-effort — a flaky connection here
        should never interrupt the actual export/import.
        """
        if not self.job_id:
            return
        try:
            self.post_json(f"/agent/api/{self.job_id}/progress", {"message": message, "percent": percent})
        except Exception:  # noqa: BLE001
            pass

    def post_file(self, path, file_path, extra_fields=None, progress_label="Uploading"):
        """Multipart/form-data upload using only stdlib, with a live progress bar."""
        boundary = uuid.uuid4().hex
        extra_fields = extra_fields or {}

        parts = []
        for key, value in extra_fields.items():
            parts.append(
                f'--{boundary}\r\nContent-Disposition: form-data; name="{key}"\r\n\r\n{value}\r\n'.encode()
            )

        filename = os.path.basename(file_path)
        file_size = os.path.getsize(file_path)

        header = (
            f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="{filename}"\r\n'
            f'Content-Type: application/octet-stream\r\n\r\n'
        ).encode()
        footer = f"\r\n--{boundary}--\r\n".encode()

        prefix_bytes = b"".join(parts) + header
        total_len = len(prefix_bytes) + file_size + len(footer)

        def body_generator():
            yield prefix_bytes
            sent = len(prefix_bytes)
            print_progress_bar(sent, total_len, progress_label)
            with open(file_path, "rb") as f:
                while True:
                    chunk = f.read(256 * 1024)
                    if not chunk:
                        break
                    yield chunk
                    sent += len(chunk)
                    print_progress_bar(sent, total_len, progress_label)
            yield footer
            print_progress_bar(total_len, total_len, progress_label)

        # urllib needs a plain readable stream, not a generator — wrap it.
        class _StreamWrapper:
            def __init__(self, gen):
                self._gen = gen
                self._buf = b""

            def read(self, size=-1):
                while size < 0 or len(self._buf) < size:
                    try:
                        self._buf += next(self._gen)
                    except StopIteration:
                        break
                    if size < 0:
                        continue
                if size < 0:
                    result, self._buf = self._buf, b""
                else:
                    result, self._buf = self._buf[:size], self._buf[size:]
                return result

        stream = _StreamWrapper(body_generator())
        req = urllib.request.Request(
            self._url(path), data=stream,
            headers={
                "Content-Type": f"multipart/form-data; boundary={boundary}",
                "X-Agent-Token": self.token,
                "Content-Length": str(total_len),
            },
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=1800) as resp:
            return json.loads(resp.read().decode("utf-8"))

    def download_file(self, path, dest_path, progress_label="Downloading"):
        """
        Streams a download with a live progress bar, and checks the
        number of bytes actually received against what the server said
        to expect (Content-Length) — flags it clearly if they don't
        match, since that usually means a cut-off or corrupted download.
        """
        req = urllib.request.Request(self._url(path), headers={"X-Agent-Token": self.token})
        with urllib.request.urlopen(req, timeout=1800) as resp:
            expected_size = resp.headers.get("Content-Length")
            expected_size = int(expected_size) if expected_size else None

            received = 0
            with open(dest_path, "wb") as f:
                while True:
                    chunk = resp.read(256 * 1024)
                    if not chunk:
                        break
                    f.write(chunk)
                    received += len(chunk)
                    if expected_size:
                        print_progress_bar(received, expected_size, progress_label)

        actual_size = os.path.getsize(dest_path)
        if expected_size and actual_size != expected_size:
            log(
                f"⚠ Warning: expected to download {human_size(expected_size)} but got "
                f"{human_size(actual_size)} — the download may be incomplete or corrupted. "
                f"The integrity check below will catch this if it's a real problem."
            )
        return actual_size, expected_size


# ---- database credential auto-detection -----------------------------------

def parse_env_database_url(install_path, client=None):
    """
    Reads the SnailyCAD install's own .env for DATABASE_URL and returns
    parsed connection details — so the correct DB name/host/user/password
    never has to be guessed or typed in by hand. Returns {} if no
    install path was given or no DATABASE_URL was found — logging
    exactly where it looked and what it found (or didn't), so a failed
    lookup is never a silent mystery.
    """
    if not install_path:
        return {}

    candidate_paths = [rel for rel in DEFAULT_KNOWN_CONFIG_PATHS if rel.endswith(".env")]
    checked = []

    for rel in candidate_paths:
        path = os.path.join(install_path, *rel.split("/"))
        if not os.path.isfile(path):
            checked.append(f"{path} (not found)")
            continue

        try:
            with open(path, encoding="utf-8", errors="replace") as f:
                content = f.read()
        except OSError as e:
            checked.append(f"{path} (couldn't read it: {e})")
            continue

        if "DATABASE_URL" not in content:
            checked.append(f"{path} (exists, but has no DATABASE_URL line)")
            continue

        for line in content.splitlines():
            line = line.strip()
            if not line.startswith("DATABASE_URL"):
                continue
            _, _, value = line.partition("=")
            value = value.strip().strip('"').strip("'")
            if not value:
                checked.append(f"{path} (DATABASE_URL is present but empty)")
                continue
            parsed = urllib.parse.urlsplit(value)
            if not parsed.scheme.startswith("postgres"):
                checked.append(f"{path} (DATABASE_URL found, but it's not a postgres:// URL — got '{parsed.scheme}://')")
                continue
            name = parsed.path.lstrip("/").split("?")[0]
            if not name:
                checked.append(f"{path} (DATABASE_URL found, but no database name in it)")
                continue
            log(f"Found DATABASE_URL in {path}.")
            if client:
                client.report_progress(f"Found database settings in {path}.")
            return {
                "host": parsed.hostname or "localhost",
                "port": parsed.port or 5432,
                "user": parsed.username or "postgres",
                "password": parsed.password or "",
                "name": name,
            }

    diagnostic = f"Couldn't find a usable DATABASE_URL to auto-detect from. Checked: {'; '.join(checked)}"
    log(diagnostic)
    if client:
        client.report_progress(diagnostic)
    return {}


def resolve_db_config(db_config, install_path, client=None):
    """
    Fills in any blank host/port/user/password/name fields for postgres
    by auto-detecting from the local .env, if an install path is
    available. Anything already explicitly provided is left untouched —
    but if what was typed in doesn't match what .env actually says, that
    gets flagged loudly so it's not a silent, confusing failure later.
    """
    if (db_config.get("type") or "").lower() != "postgres":
        return db_config

    auto = parse_env_database_url(install_path, client)

    if db_config.get("name"):
        if auto and auto.get("name") and auto["name"] != db_config["name"]:
            warning = (
                f"⚠ You entered database name '{db_config['name']}', but the .env at "
                f"{install_path} says the real database is '{auto['name']}'. Using what "
                f"you typed since you entered it explicitly — if that's not right, clear "
                f"the DB name field on the form and re-run to auto-detect instead."
            )
            log(warning)
            if client:
                client.report_progress(warning)
        return db_config  # explicit name always wins, never silently overridden

    if not auto:
        return db_config

    message = f"Auto-detected database config from .env: {auto['name']} @ {auto['host']}:{auto['port']}"
    log(message)
    if client:
        client.report_progress(message)
    merged = dict(db_config)
    for key in ("host", "port", "user", "password", "name"):
        if not merged.get(key):
            merged[key] = auto[key]
    return merged


def list_postgres_databases(host, port, user, password):
    """
    Returns (names, error) — a list of real (non-template, non-system)
    database names on the server, or an error string if the connection
    itself failed. Used when no specific database name was given and
    there's no .env to auto-detect one from.
    """
    env = os.environ.copy()
    if password:
        env["PGPASSWORD"] = password
    cmd = [
        "psql", "-h", host, "-p", str(port), "-U", user, "-d", "postgres",
        "-t", "-A", "-c",
        "SELECT datname FROM pg_database WHERE datistemplate = false AND datname NOT IN ('postgres');",
    ]
    try:
        result = run_db_tool(cmd, env, "psql")
    except RuntimeError as e:
        return None, str(e)
    if result.returncode != 0:
        return None, result.stderr.strip()[:2000]
    names = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    return names, None


def dump_one_postgres_db(dump_dir, host, port, user, password, name, client, percent=None):
    """Dumps a single database to dump_dir/{name}.sql, returns the manifest item dict."""
    out_file = os.path.join(dump_dir, f"{name}.sql")
    env = os.environ.copy()
    if password:
        env["PGPASSWORD"] = password
    cmd = ["pg_dump", "-h", host, "-p", str(port), "-U", user, "-F", "p", "-f", out_file, name]
    result = run_db_tool(cmd, env, "pg_dump")
    if result.returncode != 0:
        raise RuntimeError(f"Backing up database '{name}' failed: {result.stderr.strip()[:2000]}")
    dump_size = os.path.getsize(out_file)
    log(f"Database '{name}' backed up — {human_size(dump_size)}.")
    client.report_progress(f"Database '{name}' backed up ({human_size(dump_size)}).", percent=percent)
    return {
        "category": "database", "archive_path": f"database/{name}.sql",
        "size_bytes": dump_size, "sha256": sha256_of_file(out_file),
    }


# ---- export direction: collect locally, build a zip, upload it ------------

def run_export(client, job_id, config, known_paths):
    install_path = clean_path(config.get("install_path"))
    include_files = config.get("include_files", True)
    db_config = config.get("db_config") or {}
    include_uploads = config.get("include_uploads", True)
    extra_paths = config.get("extra_paths") or []

    work_dir = tempfile.mkdtemp(prefix="snailycad-agent-export-")
    staging_dir = os.path.join(work_dir, "staging")
    os.makedirs(staging_dir, exist_ok=True)
    items = []

    def stage_file(source_abs, category, archive_rel):
        dest = os.path.join(staging_dir, *archive_rel.split("/"))
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        shutil.copy2(source_abs, dest)
        items.append({
            "category": category, "archive_path": archive_rel,
            "size_bytes": os.path.getsize(dest), "sha256": sha256_of_file(dest),
        })

    def stage_dir(source_abs, category, archive_rel_root):
        for root, _dirs, files in os.walk(source_abs):
            for fname in files:
                full = os.path.join(root, fname)
                rel = os.path.relpath(full, source_abs).replace("\\", "/")
                stage_file(full, category, f"{archive_rel_root}/{rel}")

    if include_files and install_path:
        log(f"Looking for your SnailyCAD files in: {install_path}")
        client.report_progress(f"Looking for your files in {install_path}...", percent=5)

        if os.path.isfile(install_path):
            corrected = os.path.dirname(install_path)
            log(f"That's a file, not a folder — using its parent folder instead: {corrected}")
            install_path = corrected

        if not os.path.isdir(install_path):
            raise RuntimeError(
                f"Couldn't find that folder on this computer: {install_path}\n"
                f"       This should be the SnailyCAD install FOLDER (e.g. D:\\SnailyCAD), "
                f"not a specific file inside it."
            )

        markers = ["package.json", ".env", "apps"]
        if not any(os.path.exists(os.path.join(install_path, m)) for m in markers):
            raise RuntimeError(
                f"That doesn't look like a SnailyCAD install: {install_path}\n"
                f"       Expected to find package.json, .env, or an apps folder in there. "
                f"Point this at the SnailyCAD root folder, not a subfolder or a single file."
            )

        log("Found it! Copying your settings and configuration files...")
        client.report_progress("Found your SnailyCAD install — copying settings...", percent=10)
        for rel in known_paths.get("config", DEFAULT_KNOWN_CONFIG_PATHS):
            abs_path = os.path.join(install_path, *rel.split("/"))
            if os.path.isfile(abs_path):
                stage_file(abs_path, "config", f"config/{rel}")

        for rel in known_paths.get("cad_config", DEFAULT_KNOWN_CAD_CONFIG_PATHS):
            abs_path = os.path.join(install_path, *rel.split("/"))
            if os.path.isfile(abs_path):
                stage_file(abs_path, "cad_config", f"cad_config/{rel}")
            elif os.path.isdir(abs_path):
                stage_dir(abs_path, "cad_config", f"cad_config/{rel}")

        if include_uploads:
            log("Copying your uploaded files (this can take a while if there are a lot)...")
            client.report_progress("Copying uploaded files (images, documents, etc.)...", percent=20)
            for rel in known_paths.get("uploads", DEFAULT_KNOWN_UPLOAD_DIRS):
                abs_path = os.path.join(install_path, *rel.split("/"))
                if os.path.isdir(abs_path):
                    stage_dir(abs_path, "uploads", f"uploads/{rel}")

        for rel in extra_paths:
            parts = [p for p in re.split(r"[\\/]+", rel) if p]
            abs_path = os.path.join(install_path, *parts)
            norm_rel = "/".join(parts)
            if os.path.isfile(abs_path):
                stage_file(abs_path, "custom", f"custom/{norm_rel}")
            elif os.path.isdir(abs_path):
                stage_dir(abs_path, "custom", f"custom/{norm_rel}")

        file_count = len(items)
        total_bytes = sum(i["size_bytes"] for i in items)
        log(f"Done copying files — found {file_count} file(s), {human_size(total_bytes)} total.")
    else:
        if install_path:
            log(f"Not collecting files — using {install_path} only to look up database settings.")
            client.report_progress("Database-only export — using install path to find DB settings.", percent=10)
        else:
            log("Skipping files — this is a database-only export.")
            client.report_progress("Database-only export — skipping files.", percent=10)

    db_type = (db_config.get("type") or "").lower()
    if db_type == "postgres":
        db_config = resolve_db_config(db_config, install_path, client)
        name = db_config.get("name")
        host = db_config.get("host", "localhost")
        port = db_config.get("port", 5432)
        user = db_config.get("user", "postgres")
        password = db_config.get("password", "")

        dump_dir = os.path.join(staging_dir, "database")
        os.makedirs(dump_dir, exist_ok=True)

        if name:
            log(f"Backing up your database ('{name}') — this can take a few minutes for a big database...")
            client.report_progress(f"Backing up your database ({name})... this can take a while.", percent=40)
            items.append(dump_one_postgres_db(dump_dir, host, port, user, password, name, client, percent=70))
        else:
            log("No database name given — checking what's actually on that server...")
            client.report_progress("No DB name given — looking for databases on the server...", percent=40)
            names, err = list_postgres_databases(host, port, user, password)

            if names is None:
                raise RuntimeError(
                    f"No database name was given, and couldn't even connect to {host}:{port} to look "
                    f"for one: {err}\n"
                    f"       Either type in the database name on the export form, give the install "
                    f"path so it can be read from the SnailyCAD settings file, or check the DB "
                    f"host/user/password are correct."
                )
            if not names:
                raise RuntimeError(
                    f"No database name was given, and connected to {host}:{port} fine, but there "
                    f"aren't any databases there (other than Postgres' own system ones)."
                )

            log(f"Found {len(names)} database(s) on the server: {', '.join(names)}. Backing up all of them...")
            client.report_progress(
                f"Found {len(names)} database(s) — backing up all of them...", percent=45
            )
            for i, db_name in enumerate(names):
                percent = 45 + int(25 * (i + 1) / len(names))
                items.append(dump_one_postgres_db(dump_dir, host, port, user, password, db_name, client, percent=percent))
            log(f"All {len(names)} database(s) backed up.")
    elif db_type == "sqlite":
        log("Copying your database file...")
        client.report_progress("Copying your database file...", percent=40)
        source = clean_path(db_config.get("path"))
        if not source or not os.path.isfile(source):
            raise RuntimeError(f"Couldn't find the database file: {source}")
        dump_dir = os.path.join(staging_dir, "database")
        os.makedirs(dump_dir, exist_ok=True)
        dest_name = os.path.basename(source)
        dest = os.path.join(dump_dir, dest_name)
        shutil.copy2(source, dest)
        dump_size = os.path.getsize(dest)
        log(f"Database copy finished — {human_size(dump_size)}.")
        client.report_progress(f"Database copy finished ({human_size(dump_size)}).", percent=70)
        items.append({
            "category": "database", "archive_path": f"database/{dest_name}",
            "size_bytes": dump_size, "sha256": sha256_of_file(dest),
        })

    if not items:
        raise RuntimeError("Nothing was found to back up — check the install path and try again.")

    manifest = {
        "export_tool_version": AGENT_VERSION,
        "source_os": detect_os(),
        "source_connection": "agent",
        "install_path": install_path,
        "database_type": db_config.get("type"),
        "item_count": len(items),
        "warnings": [],
        "items": items,
    }
    with open(os.path.join(staging_dir, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2)

    log("Packing everything into one file...")
    client.report_progress("Packing everything into one file...", percent=75)
    zip_path = os.path.join(work_dir, "package.zip")
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
        for root, _dirs, files in os.walk(staging_dir):
            for fname in files:
                full = os.path.join(root, fname)
                zf.write(full, os.path.relpath(full, staging_dir))

    package_size = os.path.getsize(zip_path)
    log(f"Package ready — {human_size(package_size)}. Uploading now...")
    client.report_progress(f"Uploading your backup ({human_size(package_size)})...", percent=80)
    result = client.post_file(f"/agent/api/{job_id}/upload-package", zip_path, progress_label="Uploading")

    uploaded_size = result.get("size_bytes")
    if uploaded_size is not None and uploaded_size != package_size:
        log(
            f"⚠ Warning: the file I built here was {human_size(package_size)}, but the "
            f"platform says it received {human_size(uploaded_size)} — those should match. "
            f"If something looks wrong with your export, this is worth mentioning."
        )
        client.report_progress(
            f"⚠ Size mismatch: sent {human_size(package_size)}, platform received "
            f"{human_size(uploaded_size)}.", percent=95
        )
    else:
        log(f"✓ Upload confirmed — the platform received exactly {human_size(uploaded_size or package_size)}, matching what was sent.")
        client.report_progress(
            f"✓ Upload confirmed — {human_size(uploaded_size or package_size)} received, sizes match.",
            percent=100,
        )

    shutil.rmtree(work_dir, ignore_errors=True)
    return result


# ---- import direction: download the package, restore locally --------------

def _safe_pg_identifier(name):
    """Basic sanity check before using a name in a raw SQL statement — the
    name always comes from our own verified manifest/filenames, but this
    guards against anything unexpected slipping through."""
    import re
    if not re.match(r"^[A-Za-z0-9_\-]+$", name):
        raise RuntimeError(f"Unexpected characters in database name '{name}', refusing to use it in SQL.")
    return name


def create_postgres_db_if_missing(host, port, user, password, name):
    name = _safe_pg_identifier(name)
    env = os.environ.copy()
    if password:
        env["PGPASSWORD"] = password
    check_cmd = ["psql", "-h", host, "-p", str(port), "-U", user, "-d", "postgres", "-tAc",
                 f"SELECT 1 FROM pg_database WHERE datname='{name}'"]
    result = run_db_tool(check_cmd, env, "psql")
    if result.returncode == 0 and result.stdout.strip() == "1":
        return  # already exists
    create_cmd = ["psql", "-h", host, "-p", str(port), "-U", user, "-d", "postgres",
                  "-c", f'CREATE DATABASE "{name}"']
    create_result = run_db_tool(create_cmd, env, "psql")
    if create_result.returncode != 0:
        raise RuntimeError(f"Couldn't create database '{name}': {create_result.stderr.strip()[:1000]}")
    log(f"Created database '{name}' on the target server (it didn't exist yet).")


def restore_one_postgres_db(dump_file, host, port, user, password, name, client, percent=None):
    create_postgres_db_if_missing(host, port, user, password, name)
    env = os.environ.copy()
    if password:
        env["PGPASSWORD"] = password
    cmd = ["psql", "-h", host, "-p", str(port), "-U", user, "-d", name, "-f", dump_file]
    result = run_db_tool(cmd, env, "psql")
    if result.returncode != 0:
        raise RuntimeError(f"Restoring database '{name}' failed: {result.stderr.strip()[:2000]}")
    dump_size = os.path.getsize(dump_file)
    log(f"Database '{name}' restored — {human_size(dump_size)}.")
    client.report_progress(f"Database '{name}' restored ({human_size(dump_size)}).", percent=percent)


def run_import(client, job_id, config):
    target_path = clean_path(config.get("target_path"))
    restore_files = config.get("restore_files", True)
    db_target = config.get("db_target") or {}

    work_dir = tempfile.mkdtemp(prefix="snailycad-agent-import-")
    zip_path = os.path.join(work_dir, "package.zip")

    log("Downloading your backup from the platform...")
    client.report_progress("Downloading your backup...", percent=10)
    actual_size, expected_size = client.download_file(
        f"/agent/api/{job_id}/download-package", zip_path, progress_label="Downloading"
    )
    if expected_size and actual_size == expected_size:
        log(f"✓ Download complete — {human_size(actual_size)}, matches what the platform sent.")
    else:
        log(f"Download complete — {human_size(actual_size)}.")
    client.report_progress(f"Download complete ({human_size(actual_size)}).", percent=30)

    extract_dir = os.path.join(work_dir, "extracted")
    os.makedirs(extract_dir, exist_ok=True)
    with zipfile.ZipFile(zip_path) as zf:
        for member in zf.namelist():
            dest = os.path.abspath(os.path.join(extract_dir, member))
            if not dest.startswith(os.path.abspath(extract_dir) + os.sep):
                raise RuntimeError(f"Unsafe path in package: {member}")
        zf.extractall(extract_dir)

    manifest_path = os.path.join(extract_dir, "manifest.json")
    if not os.path.isfile(manifest_path):
        raise RuntimeError("This backup file looks broken — it's missing its manifest.")
    with open(manifest_path) as f:
        manifest = json.load(f)

    log("Double-checking nothing got corrupted on the way here...")
    client.report_progress("Checking the backup for corruption...", percent=35)
    total_declared_size = 0
    for item in manifest.get("items", []):
        full = os.path.join(extract_dir, *item["archive_path"].split("/"))
        if not os.path.isfile(full):
            raise RuntimeError(f"A file is missing from the backup: {item['archive_path']}")
        if sha256_of_file(full) != item["sha256"]:
            raise RuntimeError(
                f"A file doesn't match what it should be (corrupted?): {item['archive_path']}"
            )
        total_declared_size += item.get("size_bytes", 0)
    item_count = len(manifest.get("items", []))
    log(f"✓ All {item_count} item(s) checked out fine — {human_size(total_declared_size)} of content, all matching.")
    client.report_progress(f"✓ Backup verified — {item_count} item(s), all intact.", percent=45)

    warnings = []
    restored_files = 0

    db_type = manifest.get("database_type")
    if db_type and db_target:
        dump_dir = os.path.join(extract_dir, "database")
        dump_files = os.listdir(dump_dir) if os.path.isdir(dump_dir) else []

        if db_type == "postgres" and len(dump_files) > 1:
            db_target = resolve_db_config(db_target, target_path, client)
            target_name = db_target.get("name")
            host = db_target.get("host", "localhost")
            port = db_target.get("port", 5432)
            user = db_target.get("user", "postgres")
            password = db_target.get("password", "")

            if target_name:
                matching = f"{target_name}.sql"
                if matching not in dump_files:
                    available = ", ".join(f.rsplit(".sql", 1)[0] for f in dump_files)
                    raise RuntimeError(
                        f"This backup has {len(dump_files)} databases in it, and none is named "
                        f"'{target_name}'. Available: {available}. Either use one of those names, "
                        f"or leave the database name blank to restore all of them."
                    )
                log(f"Restoring just '{target_name}' out of {len(dump_files)} databases in this backup...")
                restore_one_postgres_db(
                    os.path.join(dump_dir, matching), host, port, user, password, target_name, client, percent=70
                )
            else:
                log(f"No specific database name given — restoring all {len(dump_files)} databases from this backup...")
                client.report_progress(f"Restoring all {len(dump_files)} databases...", percent=50)
                for i, fname in enumerate(sorted(dump_files)):
                    db_name = fname.rsplit(".sql", 1)[0]
                    percent = 50 + int(25 * (i + 1) / len(dump_files))
                    restore_one_postgres_db(
                        os.path.join(dump_dir, fname), host, port, user, password, db_name, client, percent=percent
                    )
                log(f"All {len(dump_files)} databases restored.")

        elif dump_files:
            dump_file = os.path.join(dump_dir, dump_files[0])
            dump_file_size = os.path.getsize(dump_file)
            log(f"Database backup inside the package is {human_size(dump_file_size)}.")

            if db_type == "postgres":
                db_target = resolve_db_config(db_target, target_path, client)
                if not db_target.get("name"):
                    raise RuntimeError(
                        "No target database name was given, and I couldn't figure one out.\n"
                        "       Either type in the database name on the import form, or "
                        "point the target path at an existing SnailyCAD install so it can be read from there."
                    )
                log(f"Restoring your database ('{db_target.get('name')}') — this can take a while for a big database...")
                client.report_progress(
                    f"Restoring your database ({db_target.get('name')})... this can take a while.", percent=55
                )
                restore_one_postgres_db(
                    dump_file, db_target.get("host", "localhost"), db_target.get("port", 5432),
                    db_target.get("user", "postgres"), db_target.get("password", ""),
                    db_target["name"], client, percent=80,
                )
            elif db_type == "sqlite":
                dest = clean_path(db_target.get("path"))
                if dest:
                    log(f"Restoring your database to {dest}...")
                    client.report_progress(f"Restoring your database to {dest}...", percent=55)
                    if os.path.exists(dest):
                        shutil.copy2(dest, dest + ".bak")
                        warnings.append(f"Your old database file was backed up to {dest}.bak before being replaced.")
                    os.makedirs(os.path.dirname(dest) or ".", exist_ok=True)
                    shutil.copy2(dump_file, dest)
                    restored_size = os.path.getsize(dest)
                    if restored_size != dump_file_size:
                        warnings.append(
                            f"⚠ The restored database file is {human_size(restored_size)}, but the backup "
                            f"was {human_size(dump_file_size)} — these should match. Something may have gone wrong."
                        )
                        log(f"⚠ Warning: restored file size ({human_size(restored_size)}) doesn't match the backup ({human_size(dump_file_size)}).")
                    else:
                        log(f"✓ Database restore finished — {human_size(restored_size)}, matches the backup exactly.")
                    client.report_progress(f"✓ Database restored ({human_size(restored_size)}).", percent=80)
    elif db_type and not db_target:
        warnings.append("This backup includes a database, but no restore target was set up, so the database was NOT restored.")

    if restore_files and target_path:
        log("Copying your files into place...")
        client.report_progress("Copying your files into place...", percent=85)
        os.makedirs(target_path, exist_ok=True)
        for item in manifest.get("items", []):
            if item["category"] == "database":
                continue
            parts = item["archive_path"].split("/", 1)
            rel_to_install = parts[1] if len(parts) > 1 else parts[0]
            src = os.path.join(extract_dir, *item["archive_path"].split("/"))
            dest = os.path.join(target_path, *rel_to_install.split("/"))
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            shutil.copy2(src, dest)
            restored_files += 1
        log(f"✓ Copied {restored_files} file(s) to {target_path}.")
        client.report_progress(f"✓ Copied {restored_files} file(s) into place.", percent=95)

        if detect_os() == "linux":
            try:
                for root, dirs, files in os.walk(target_path):
                    for d in dirs:
                        os.chmod(os.path.join(root, d), 0o755)
                    for fname in files:
                        os.chmod(os.path.join(root, fname), 0o644)
            except OSError as e:
                warnings.append(f"Couldn't fully set file permissions: {e}")
    else:
        if target_path:
            log(f"Not restoring files — {target_path} was only used to look up database settings.")
            client.report_progress("Database-only restore — used target path only for DB settings.", percent=95)
        else:
            log("No files to restore — this was a database-only restore.")
            client.report_progress("Database-only restore — no files to copy.", percent=95)

    shutil.rmtree(work_dir, ignore_errors=True)
    return restored_files, warnings


def main():
    parser = argparse.ArgumentParser(description="SnailyCAD Migration Platform remote agent")
    parser.add_argument("--server", required=EMBEDDED_SERVER is None, default=EMBEDDED_SERVER,
                         help="Platform base URL, e.g. https://migrate.example.com")
    parser.add_argument("--token", required=EMBEDDED_TOKEN is None, default=EMBEDDED_TOKEN,
                         help="One-time job token shown on the platform")
    args = parser.parse_args()

    client = ApiClient(args.server, args.token)

    log(f"Connecting to the migration platform ({args.server})...")

    def do_handshake():
        return client.post_json("/agent/api/handshake", {
            "hostname": socket.gethostname(),
            "os": detect_os(),
            "agent_version": AGENT_VERSION,
        })

    try:
        handshake = do_handshake()
    except urllib.error.HTTPError as e:
        body = e.read().decode(errors="replace")
        if e.code == 410:
            log("This access grant has expired. Ask whoever's helping you to request a new one.")
            sys.exit(1)
        log(f"Couldn't connect ({e.code}): {body}")
        sys.exit(1)
    except urllib.error.URLError as e:
        log(f"Couldn't reach {args.server}: {e.reason}")
        sys.exit(1)

    if handshake.get("status") == "waiting_for_admin":
        log("Connected! An admin needs to fill in a few details on their end before this can start.")
        log("This window can just sit here — it'll pick up automatically once they do (up to 12 hours).")
        poll_count = 0
        while handshake.get("status") == "waiting_for_admin":
            time.sleep(30)
            poll_count += 1
            if poll_count % 10 == 0:  # roughly every 5 minutes
                remaining = handshake.get("remaining_seconds")
                if remaining:
                    hours = remaining // 3600
                    minutes = (remaining % 3600) // 60
                    log(f"Still waiting on an admin... ({hours}h {minutes}m left before this expires)")
                else:
                    log("Still waiting on an admin...")
            try:
                handshake = do_handshake()
            except urllib.error.HTTPError as e:
                if e.code == 410:
                    log("This access grant expired while waiting. Ask whoever's helping you to request a new one.")
                    sys.exit(1)
                # transient network/server hiccup — keep trying rather than giving up
                continue
            except urllib.error.URLError:
                continue
        log("An admin just filled in the details — starting now.")

    job_id = handshake["job_id"]
    kind = handshake["kind"]
    config = handshake["config"]
    client.job_id = job_id
    log(f"Connected! Starting your {kind}...")
    client.report_progress("Connected — getting started...", percent=2)

    try:
        if kind == "export":
            known_paths = handshake.get("known_paths", {})
            result = run_export(client, job_id, config, known_paths)
            log(f"✓ All done! Your backup is uploaded and ready on the platform.")
        elif kind == "import":
            restored_files, warnings = run_import(client, job_id, config)
            client.post_json(f"/agent/api/{job_id}/complete", {
                "restored_files": restored_files, "warnings": warnings,
            })
            log(f"✓ All done! {restored_files} file(s) restored.")
            for w in warnings:
                log(f"Note: {w}")
        else:
            raise RuntimeError(f"Unknown job kind: {kind}")
    except Exception as e:  # noqa: BLE001 - report any failure back to the platform
        log(f"Something went wrong: {e}")
        client.report_progress(f"Failed: {e}", percent=None)
        try:
            client.post_json(f"/agent/api/{job_id}/fail", {"message": str(e)})
        except Exception:  # noqa: BLE001
            pass
        sys.exit(1)

    log("Finished — you can close this window.")


if __name__ == "__main__":
    try:
        main()
    finally:
        # If launched by double-click (embedded config, no CLI args passed),
        # the console window would otherwise close instantly on exit —
        # pause so the person can actually read what happened.
        if EMBEDDED_SERVER and len(sys.argv) == 1:
            try:
                input("\nPress Enter to close this window...")
            except (KeyboardInterrupt, EOFError):
                pass
