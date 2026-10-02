"""txAdmin / FXServer instance management for the /tx page.

Layout of a panel-managed instance (TX_ROOT/<slug>/):
    server  -> symlink to TX_ROOT/_artifacts/<build>/  (run.sh + alpine/)
    txData/                                            (txAdmin data, deployed servers)
plus:
    /etc/systemd/system/txadmin-<slug>.service
    /etc/systemd/system/<unit>.d/opslab-tx.conf  -> EnvironmentFile=ENV_DIR/<slug>.env

The env file holds the TXHOST_* vars txAdmin 8 reads at boot
(docs/env-config.md in the txAdmin resource). That's what makes setup
automatic: TXHOST_DEFAULT_ACCOUNT pre-creates the master admin (no PIN
step), and TXHOST_DEFAULT_DB* pre-fill the database step of the setup wizard
with a MySQL db/user the panel creates for the instance.

Artifacts are cached per build and shared between instances, since each one
is ~280MB unpacked.
"""
import glob
import json
import os
import re
import secrets
import shutil
import socket
import string
import subprocess
import time
from datetime import datetime

import bcrypt
import requests

from services import database_service as dbsvc

TX_ROOT = os.environ.get("TX_ROOT", "/root/txadmin")
ARTIFACT_CACHE = os.path.join(TX_ROOT, "_artifacts")
ENV_DIR = os.path.join(os.environ.get("SERVER_PANEL_DATA_DIR", "/root/server-panel-data"), "txadmin")
SYSTEMD_DIR = "/etc/systemd/system"
DROPIN_NAME = "opslab-tx.conf"

ARTIFACTS_API = "https://changelogs-live.fivem.net/api/changelog/versions/linux/server"
ARTIFACT_URL_RE = re.compile(r"^https://runtime\.fivem\.net/artifacts/fivem/build_proot_linux/master/(\d+)-[0-9a-f]+/fx\.tar\.xz$")

TX_PORT_START, GAME_PORT_START = 40121, 30121
USERNAME_RE = re.compile(r"^\w[\w.-]{1,18}\w$")  # txAdmin's regexValidFivemUsername
SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9_]{1,22}$")
CFX_KEY_RE = re.compile(r"^(cfxk_\w{1,60}_\w{1,20}|\w{32})$")
PROVIDER_NAME = "OpsLab Panel"


class TxError(Exception):
    pass


# ---------------------------------------------------------------- small helpers

def _run(args, timeout=30, check=True):
    try:
        r = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired as exc:
        raise TxError(f"Timed out: {' '.join(args)}") from exc
    if check and r.returncode != 0:
        raise TxError((r.stderr or r.stdout).strip() or f"{args[0]} exited {r.returncode}")
    return r


def gen_password(length=20):
    alphabet = string.ascii_letters + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(length))


def bcrypt_hash(password):
    # txAdmin verifies with bcryptjs; $2a$ and $2b$ are the same algorithm
    # for these lengths, and $2a$ is the variant every bcryptjs accepts.
    h = bcrypt.hashpw(password.encode(), bcrypt.gensalt(rounds=11)).decode()
    return "$2a$" + h[4:]


def public_ip():
    ip = os.environ.get("PANEL_PUBLIC_IP")
    if ip:
        return ip
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("1.1.1.1", 80))
            return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"


def slugify(name):
    slug = re.sub(r"[^a-z0-9]+", "_", (name or "").lower()).strip("_")[:22]
    return slug if len(slug) >= 2 else f"tx_{secrets.token_hex(2)}"


def _listening_ports():
    r = _run(["ss", "-Htlnu"], check=False)
    ports = set()
    for line in r.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 5:
            m = re.search(r":(\d+)$", parts[4])
            if m:
                ports.add(int(m.group(1)))
    return ports


def allocate_ports(taken_tx, taken_game):
    busy = _listening_ports()
    tx = TX_PORT_START
    while tx in busy or tx in taken_tx or tx == 40120:
        tx += 1
    game = GAME_PORT_START
    while game in busy or game in taken_game or game == 30120:
        game += 1
    return tx, game


def _unit_path(unit):
    return os.path.join(SYSTEMD_DIR, unit)


def _env_path(slug):
    return os.path.join(ENV_DIR, f"{slug}.env")


def _systemctl(*args, check=True, timeout=60):
    return _run(["systemctl", *args], timeout=timeout, check=check)


def _strip_ansi(s):
    return re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", s)


def _du(path, timeout=10):
    r = _run(["du", "-sb", path], timeout=timeout, check=False)
    try:
        return int(r.stdout.split()[0])
    except (IndexError, ValueError):
        return None


def _is_inside(path, parent):
    path, parent = os.path.realpath(path), os.path.realpath(parent)
    return path != parent and path.startswith(parent + os.sep)


# ---------------------------------------------------------------- artifacts

def artifact_versions():
    try:
        r = requests.get(ARTIFACTS_API, timeout=10)
        r.raise_for_status()
        data = r.json()
    except (requests.RequestException, ValueError) as exc:
        raise TxError(f"Couldn't reach the FiveM artifacts API: {exc}") from exc
    out = {}
    for channel in ("recommended", "latest", "optional", "critical"):
        url = data.get(f"{channel}_download")
        if url and ARTIFACT_URL_RE.match(url):
            out[channel] = {"build": str(data.get(channel)), "url": url, "txadmin": data.get(f"{channel}_txadmin")}
    if "recommended" not in out:
        raise TxError("Artifacts API didn't return a recommended build.")
    return out


def cached_artifacts():
    builds = []
    for d in sorted(glob.glob(os.path.join(ARTIFACT_CACHE, "*"))):
        if os.path.isfile(os.path.join(d, "run.sh")):
            builds.append(os.path.basename(d))
    return builds


def resolve_build(choice):
    """`choice` is a channel name (recommended/latest) or a build number that
    is already cached. Returns (build, download_url_or_None)."""
    choice = (choice or "recommended").strip()
    if choice.isdigit():
        if choice in cached_artifacts():
            return choice, None
        for v in artifact_versions().values():
            if v["build"] == choice:
                return choice, v["url"]
        raise TxError(f"Build {choice} isn't cached and isn't a current recommended/latest build.")
    versions = artifact_versions()
    if choice not in versions:
        raise TxError(f"Unknown artifact channel '{choice}'.")
    v = versions[choice]
    return v["build"], (None if v["build"] in cached_artifacts() else v["url"])


def ensure_artifact(ctx, choice):
    build, url = resolve_build(choice)
    target = os.path.join(ARTIFACT_CACHE, build)
    if url is None:
        ctx.log(f"Using cached FXServer build {build}")
        return build, target
    os.makedirs(ARTIFACT_CACHE, exist_ok=True)
    archive = target + ".tar.xz.part"
    ctx.log(f"Downloading FXServer build {build}…")
    with requests.get(url, stream=True, timeout=30) as r:
        r.raise_for_status()
        total = int(r.headers.get("content-length") or 0)
        done, last = 0, -1
        with open(archive, "wb") as f:
            for chunk in r.iter_content(1024 * 512):
                f.write(chunk)
                done += len(chunk)
                if total:
                    pct = int(done * 100 / total)
                    if pct // 10 != last:
                        last = pct // 10
                        ctx.log(f"  download {pct}% ({done // (1024 * 1024)} MB)")
    ctx.log("Extracting artifact…")
    tmp_dir = target + ".tmp"
    shutil.rmtree(tmp_dir, ignore_errors=True)
    os.makedirs(tmp_dir)
    # System tar: much faster than tarfile for .xz, and keeps the artifact's
    # internal library symlinks exactly as shipped.
    try:
        _run(["tar", "-xJf", archive, "-C", tmp_dir, "--no-same-owner"], timeout=900)
    finally:
        os.remove(archive)
    if not os.path.isfile(os.path.join(tmp_dir, "run.sh")):
        shutil.rmtree(tmp_dir, ignore_errors=True)
        raise TxError("Downloaded artifact doesn't contain run.sh — unexpected archive layout.")
    os.chmod(os.path.join(tmp_dir, "run.sh"), 0o755)
    os.replace(tmp_dir, target)
    ctx.log(f"Build {build} ready")
    return build, target


def _artifact_build_of(server_dir):
    real = os.path.realpath(server_dir)
    if os.path.dirname(real) == os.path.realpath(ARTIFACT_CACHE):
        return os.path.basename(real)
    try:  # adopted installs: citizen/version.txt isn't always there; fall back to unknown
        with open(os.path.join(real, "alpine/opt/cfx-server/citizen/version.txt")) as f:
            m = re.search(r"\d{4,6}", f.read())
            return m.group(0) if m else None
    except OSError:
        return None


# ---------------------------------------------------------------- env + units

def build_env(inst, include_account=True):
    host = public_ip()
    env = {
        "TXHOST_PROVIDER_NAME": PROVIDER_NAME,
        "TXHOST_TXA_URL": f"http://{host}:{inst.tx_port}",
        "TXHOST_DEFAULT_DBHOST": "127.0.0.1",
        "TXHOST_DEFAULT_DBPORT": "3306",
    }
    if inst.managed:
        env.update({
            "TXHOST_DATA_PATH": inst.txdata_dir,
            "TXHOST_TXA_PORT": str(inst.tx_port),
            "TXHOST_FXS_PORT": str(inst.game_port),
            "TXHOST_IGNORE_DEPRECATED_CONFIGS": "true",
        })
    if inst.db_user:
        env["TXHOST_DEFAULT_DBUSER"] = inst.db_user
    if inst.db_password:
        env["TXHOST_DEFAULT_DBPASS"] = inst.db_password
    if inst.db_name:
        env["TXHOST_DEFAULT_DBNAME"] = inst.db_name
    if inst.cfx_key:
        env["TXHOST_DEFAULT_CFXKEY"] = inst.cfx_key
    if include_account and inst.tx_username and inst.tx_password:
        env["TXHOST_DEFAULT_ACCOUNT"] = f"{inst.tx_username}::{bcrypt_hash(inst.tx_password)}"
    return env


def write_env(inst, include_account=True):
    os.makedirs(ENV_DIR, mode=0o700, exist_ok=True)
    path = _env_path(inst.slug)
    lines = ["# Managed by the OpsLab panel (/tx). Regenerated on install/reinstall/password reset."]
    for k, v in build_env(inst, include_account).items():
        if "'" in v or "\n" in v:
            raise TxError(f"Value for {k} contains a quote or newline.")
        lines.append(f"{k}='{v}'")
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write("\n".join(lines) + "\n")
    dropin_dir = _unit_path(inst.service_unit) + ".d"
    os.makedirs(dropin_dir, exist_ok=True)
    with open(os.path.join(dropin_dir, DROPIN_NAME), "w") as f:
        f.write(f"# Managed by the OpsLab panel (/tx)\n[Service]\nEnvironmentFile={path}\n")
    _systemctl("daemon-reload")
    return path


def write_unit(inst):
    unit = f"""# Managed by the OpsLab panel (/tx) — instance '{inst.slug}'
[Unit]
Description=txAdmin {inst.name} (panel-managed)
After=network.target mysql.service

[Service]
Type=simple
WorkingDirectory={inst.base_dir}
ExecStart={inst.server_dir}/run.sh
Restart=on-failure
RestartSec=10
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
"""
    with open(_unit_path(inst.service_unit), "w") as f:
        f.write(unit)
    _systemctl("daemon-reload")


def _open_firewall(ctx, inst):
    try:
        from services import firewall_service as fw
        if not fw.is_installed():
            return
        fw.open_port(inst.tx_port, "tcp", f"txadmin {inst.slug}")
        fw.open_port(inst.game_port, "tcp", f"fivem {inst.slug}")
        fw.open_port(inst.game_port, "udp", f"fivem {inst.slug}")
        ctx.log(f"Firewall: opened {inst.tx_port}/tcp and {inst.game_port}/tcp+udp")
    except Exception as exc:  # noqa: BLE001
        ctx.log(f"Warning: couldn't open firewall ports ({exc}) — open them in Firewall.")


def _close_firewall(ctx, inst):
    try:
        from services import firewall_service as fw
        if not fw.is_installed():
            return
        for port, proto in ((inst.tx_port, "tcp"), (inst.game_port, "tcp"), (inst.game_port, "udp")):
            try:
                fw.close_port(port, proto)
            except Exception:  # noqa: BLE001 - rule may not exist
                pass
        ctx.log("Firewall: closed instance ports")
    except Exception as exc:  # noqa: BLE001
        ctx.log(f"Warning: firewall cleanup failed ({exc})")


def _wait_for_port(port, timeout=90):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if port in _listening_ports():
            return True
        time.sleep(2)
    return False


# ---------------------------------------------------------------- status / control

def status(inst):
    r = _systemctl("show", inst.service_unit, "-p", "ActiveState,SubState,ActiveEnterTimestamp,MainPID", check=False)
    props = dict(line.split("=", 1) for line in r.stdout.splitlines() if "=" in line)
    ports = _listening_ports()
    profile = active_profile(inst)
    return {
        "active": props.get("ActiveState") == "active",
        "state": props.get("ActiveState", "unknown"),
        "sub_state": props.get("SubState", ""),
        "since": props.get("ActiveEnterTimestamp") or None,
        "tx_listening": inst.tx_port in ports,
        "game_listening": inst.game_port in ports,
        "configured": os.path.isfile(os.path.join(inst.txdata_dir, "admins.json")),
        "profile_path": profile,
        "setup_done": bool(profile),
    }


def control(inst, action):
    if action not in ("start", "stop", "restart"):
        raise TxError("Unknown action.")
    _systemctl(action, inst.service_unit, timeout=90)


def logs(inst, lines=200):
    lines = max(20, min(2000, int(lines)))
    r = _run(["journalctl", "-u", inst.service_unit, "-n", str(lines), "--no-pager", "-o", "short-iso"], check=False, timeout=15)
    return _strip_ansi(r.stdout)


# ---------------------------------------------------------------- server data folders

def active_profile(inst):
    cfg = os.path.join(inst.txdata_dir, "default", "config.json")
    try:
        with open(cfg) as f:
            path = (json.load(f).get("server") or {}).get("dataPath")
        return os.path.realpath(path) if path else None
    except (OSError, ValueError):
        return None


def server_data_folders(inst):
    active = active_profile(inst)
    out = []
    if not os.path.isdir(inst.txdata_dir):
        return out
    for entry in sorted(os.scandir(inst.txdata_dir), key=lambda e: e.name):
        if not entry.is_dir() or entry.name == "default":
            continue
        if not os.path.isfile(os.path.join(entry.path, "server.cfg")):
            continue
        real = os.path.realpath(entry.path)
        out.append({
            "name": entry.name, "path": real, "active": real == active,
            "size": _du(real), "modified": datetime.fromtimestamp(entry.stat().st_mtime).isoformat(timespec="minutes"),
        })
    if active and not any(f["active"] for f in out) and os.path.isdir(active):
        out.insert(0, {"name": os.path.basename(active.rstrip("/")), "path": active, "active": True,
                       "size": _du(active), "modified": None, "external": True})
    return out


def delete_server_data(inst, name):
    path = os.path.join(inst.txdata_dir, name)
    if "/" in name or name in ("", ".", "..", "default") or not _is_inside(path, inst.txdata_dir):
        raise TxError("Invalid folder.")
    if not os.path.isfile(os.path.join(path, "server.cfg")):
        raise TxError("That folder isn't a server data folder (no server.cfg).")
    if os.path.realpath(path) == active_profile(inst):
        raise TxError("That's the server data folder txAdmin is currently running. Switch txAdmin to another one or reinstall first.")
    shutil.rmtree(path)


def cfg_paths(inst):
    """(profile_dir, main_cfg_name) for the server data folder txAdmin runs."""
    profile = active_profile(inst)
    cfg_name = "server.cfg"
    try:
        with open(os.path.join(inst.txdata_dir, "default", "config.json")) as f:
            cfg_name = ((json.load(f).get("server") or {}).get("cfgPath")) or cfg_name
    except (OSError, ValueError):
        pass
    return profile, cfg_name


def list_cfg_files(inst):
    """server.cfg first, then other .cfg files in the profile root and any
    `exec`'d files that live inside the profile."""
    profile, main = cfg_paths(inst)
    if not profile or not os.path.isdir(profile):
        return []
    names = []
    main_path = os.path.join(profile, main)
    if os.path.isfile(main_path):
        names.append(main)
    for e in sorted(os.scandir(profile), key=lambda e: e.name.lower()):
        if e.is_file() and e.name.endswith(".cfg") and e.name != main:
            names.append(e.name)
    try:
        text = open(main_path, encoding="utf-8", errors="replace").read()
        for m in re.finditer(r'^\s*exec\s+"?([^"\s#]+\.cfg)"?', text, re.M):
            rel = m.group(1).lstrip("@").lstrip("/")
            if rel not in names and _is_inside(os.path.join(profile, rel), profile) and os.path.isfile(os.path.join(profile, rel)):
                names.append(rel)
    except OSError:
        pass
    out = []
    for n in names:
        st = os.stat(os.path.join(profile, n))
        out.append({"name": n, "main": n == main, "size": st.st_size, "mtime": st.st_mtime})
    return out


def _cfg_file_path(inst, name):
    profile, _ = cfg_paths(inst)
    if not profile:
        raise TxError("txAdmin hasn't deployed a server yet, so there's no server.cfg.")
    allowed = {f["name"] for f in list_cfg_files(inst)}
    if name not in allowed:
        raise TxError("Unknown config file.")
    path = os.path.join(profile, name)
    if not _is_inside(path, profile):
        raise TxError("Invalid path.")
    return path


def read_cfg(inst, name):
    path = _cfg_file_path(inst, name)
    with open(path, encoding="utf-8", errors="replace") as f:
        return {"content": f.read(), "mtime": os.stat(path).st_mtime}


def write_cfg(inst, name, content, expected_mtime=None):
    """Direct write with a timestamped backup next to the file. Refuses if
    the file changed on disk since the editor loaded it."""
    path = _cfg_file_path(inst, name)
    cur = os.stat(path).st_mtime
    if expected_mtime is not None and abs(cur - float(expected_mtime)) > 0.001:
        raise TxError("The file changed on disk since you opened it. Reload it to see the latest version.")
    backup = f"{path}.bak-{datetime.now().strftime('%Y%m%d-%H%M%S-%f')}"
    shutil.copy2(path, backup)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        f.write(content)
    os.replace(tmp, path)
    # keep only the 10 newest panel backups for this file
    olds = sorted(glob.glob(path + ".bak-*"))
    for old in olds[:-10]:
        try:
            os.remove(old)
        except OSError:
            pass
    return {"backup": os.path.basename(backup), "mtime": os.stat(path).st_mtime}


def cfg_mtime(inst, name):
    return os.stat(_cfg_file_path(inst, name)).st_mtime


# ---------------------------------------------------------------- resource file editor

TEXT_EXTS = {".lua", ".js", ".mjs", ".cjs", ".ts", ".json", ".cfg", ".txt", ".md", ".yml", ".yaml", ".xml", ".meta",
             ".html", ".htm", ".css", ".scss", ".sql", ".ini", ".toml", ".env", ".csv", ".vue", ".jsx", ".tsx", ".sh", ".py", ".svg"}
TEXT_NAMES = {"fxmanifest.lua", "__resource.lua", "license", "readme", ".editorconfig", ".gitignore"}
SKIP_DIRS = {"node_modules", ".git", ".github", ".vscode", "__pycache__", "stream", ".idea"}
CONFIG_HINTS = ("config.lua", "config.json", "shared/config.lua", "config/config.lua", "shared/config.json", "settings.lua", "cfg.lua")
MAX_EDIT_BYTES = 1024 * 1024
FILE_BACKUP_DIR = os.path.join(ENV_DIR, "file-backups")
FILE_BACKUPS_KEPT = 5


def _resources_root(inst):
    profile = active_profile(inst)
    root = os.path.join(profile, "resources") if profile else None
    if not root or not os.path.isdir(root):
        raise TxError("No deployed server data folder (resources/) found.")
    return os.path.realpath(root)


def resource_dir(inst, name):
    root = _resources_root(inst)
    for r in scan_resources(inst):
        if r["name"] == name:
            path = os.path.realpath(os.path.join(root, r["folder"], name) if r["folder"] else os.path.join(root, name))
            if not path.startswith(root + os.sep):
                raise TxError("Resource is outside the resources folder.")
            return path, r["folder"]
    raise TxError(f"Resource '{name}' wasn't found on disk.")


def _is_text(name, size):
    low = name.lower()
    ext = os.path.splitext(low)[1]
    return size <= MAX_EDIT_BYTES and (ext in TEXT_EXTS or low in TEXT_NAMES)


def list_resource_files(inst, name, limit=3000):
    base, folder = resource_dir(inst, name)
    files, truncated = [], False
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS and not d.startswith("."))
        rel_dir = os.path.relpath(dirpath, base)
        for fn in sorted(filenames, key=str.lower):
            full = os.path.join(dirpath, fn)
            if os.path.islink(full):
                continue
            try:
                size = os.path.getsize(full)
            except OSError:
                continue
            rel = fn if rel_dir == "." else f"{rel_dir}/{fn}"
            files.append({"path": rel, "size": size, "editable": _is_text(fn, size)})
            if len(files) >= limit:
                truncated = True
                break
        if truncated:
            break
    configs = [f["path"] for f in files if f["path"].lower() in CONFIG_HINTS or
               (f["editable"] and re.search(r"(^|/)config[^/]*\.(lua|json)$", f["path"].lower()))]
    return {"resource": name, "folder": folder, "files": files, "truncated": truncated, "configs": configs}


def _resource_file(inst, name, rel):
    base, _ = resource_dir(inst, name)
    if not rel or "\x00" in rel or rel.startswith("/") or any(p in ("..", "") for p in rel.split("/")):
        raise TxError("Invalid file path.")
    path = os.path.realpath(os.path.join(base, rel))
    if not path.startswith(base + os.sep):
        raise TxError("Invalid file path.")
    if not os.path.isfile(path):
        raise TxError("File not found.")
    if not _is_text(os.path.basename(path), os.path.getsize(path)):
        raise TxError("This file type can't be edited here (binary or larger than 1 MB).")
    return path


def read_resource_file(inst, name, rel):
    path = _resource_file(inst, name, rel)
    with open(path, "rb") as f:
        raw = f.read()
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        text = raw.decode("latin-1")
    return {"content": text, "mtime": os.stat(path).st_mtime, "eol": "crlf" if b"\r\n" in raw else "lf"}


def write_resource_file(inst, name, rel, content, expected_mtime=None):
    path = _resource_file(inst, name, rel)
    if expected_mtime is not None and abs(os.stat(path).st_mtime - float(expected_mtime)) > 0.001:
        raise TxError("This file changed on disk since you opened it. Reload it to get the latest version.")
    if len(content.encode("utf-8")) > MAX_EDIT_BYTES:
        raise TxError("File is too large to save here (max 1 MB).")
    # backup outside the resource folder so FXServer never sees it
    bdir = os.path.join(FILE_BACKUP_DIR, inst.slug, name, os.path.dirname(rel))
    os.makedirs(bdir, mode=0o700, exist_ok=True)
    bname = f"{os.path.basename(rel)}.{datetime.now().strftime('%Y%m%d-%H%M%S-%f')}"
    shutil.copy2(path, os.path.join(bdir, bname))
    olds = sorted(glob.glob(os.path.join(bdir, glob.escape(os.path.basename(rel)) + ".*")))
    for old in olds[:-FILE_BACKUPS_KEPT]:
        try:
            os.remove(old)
        except OSError:
            pass
    tmp = path + ".panel-tmp"
    with open(tmp, "w", encoding="utf-8", newline="") as f:
        f.write(content)
    shutil.copymode(path, tmp)
    os.replace(tmp, path)
    return {"mtime": os.stat(path).st_mtime}


def scan_resources(inst, max_depth=6):
    """Resources on disk in the active server data folder, with the
    [category] folder path they live under, e.g. "[cfx-default]/[system]".
    Stops descending once a folder has a manifest (that's a resource)."""
    profile = active_profile(inst)
    root = os.path.join(profile, "resources") if profile else None
    if not root or not os.path.isdir(root):
        return []
    found = []

    def walk(path, rel, depth):
        try:
            entries = sorted(os.scandir(path), key=lambda e: e.name.lower())
        except OSError:
            return
        for e in entries:
            if not e.is_dir(follow_symlinks=False) or e.name.startswith(".") or e.name == "node_modules":
                continue
            if os.path.isfile(os.path.join(e.path, "fxmanifest.lua")) or os.path.isfile(os.path.join(e.path, "__resource.lua")):
                has_cfg = any(os.path.isfile(os.path.join(e.path, h)) for h in CONFIG_HINTS)
                found.append({"name": e.name, "folder": rel, "has_config": has_cfg})
            elif depth < max_depth:
                walk(e.path, f"{rel}/{e.name}" if rel else e.name, depth + 1)

    walk(root, "", 0)
    return found


# ---------------------------------------------------------------- adopt existing installs

def _parse_conn_string(cs):
    """oxmysql/mysql-async connection string → dict(user, password, database)."""
    cs = cs.strip().strip('"')
    m = re.match(r"^mysql://([^:@/]*)(?::([^@/]*))?@[^/]+/([^?]+)", cs)
    if m:
        from urllib.parse import unquote
        return {"user": unquote(m.group(1)), "password": unquote(m.group(2) or ""), "database": m.group(3)}
    parts = dict(p.split("=", 1) for p in cs.split(";") if "=" in p)
    low = {k.strip().lower(): v.strip() for k, v in parts.items()}
    if low:
        return {"user": low.get("user") or low.get("userid") or low.get("uid"),
                "password": low.get("password") or low.get("pwd"),
                "database": low.get("database") or low.get("db")}
    return {}


def _read_server_cfg(profile):
    info = {}
    try:
        with open(os.path.join(profile, "server.cfg"), encoding="utf-8", errors="replace") as f:
            text = f.read()
    except OSError:
        return info
    m = re.search(r'^\s*endpoint_add_tcp\s+"[^"]*:(\d+)"', text, re.M)
    if m:
        info["game_port"] = int(m.group(1))
    m = re.search(r'^\s*set\s+mysql_connection_string\s+(".*?"|\S+)', text, re.M)
    if m:
        info.update({k: v for k, v in _parse_conn_string(m.group(1)).items() if v})
    m = re.search(r"^\s*sv_licenseKey\s+\"?([\w]+)\"?", text, re.M)
    if m and CFX_KEY_RE.match(m.group(1)):
        info["cfx_key"] = m.group(1)
    return info


def discover_unmanaged(known_units):
    """Find systemd units that launch txAdmin/FXServer and aren't registered."""
    found = []
    for path in glob.glob(os.path.join(SYSTEMD_DIR, "*.service")):
        unit = os.path.basename(path)
        if unit in known_units:
            continue
        try:
            text = open(path, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        m = re.search(r"^ExecStart=(\S+)", text, re.M)
        if not m:
            continue
        exe = m.group(1)
        wd = (re.search(r"^WorkingDirectory=(\S+)", text, re.M) or [None, os.path.dirname(exe)])[1]
        script = ""
        if os.path.isfile(exe) and os.path.getsize(exe) < 200_000:
            try:
                script = open(exe, encoding="utf-8", errors="replace").read()
            except OSError:
                pass
        blob = text + script
        if not re.search(r"TXHOST_|FXServer|cfx-server|/run\.sh", blob):
            continue
        data_path = (re.search(r"TXHOST_DATA_PATH=['\"]?([^'\"\s]+)", blob) or [None, None])[1]
        tx_port = int((re.search(r"TXHOST_TXA_PORT=['\"]?(\d+)", blob) or [None, 40120])[1])
        run_sh = (re.search(r"(\S+/run\.sh)", blob) or [None, None])[1]
        server_dir = os.path.dirname(run_sh) if run_sh else os.path.join(wd, "server")
        data_path = data_path or os.path.join(wd, "txData")
        if not os.path.isdir(data_path):
            continue
        found.append({"unit": unit, "base_dir": wd, "txdata_dir": data_path, "server_dir": server_dir, "tx_port": tx_port})
    return found


def adopt_info(candidate):
    """Fill saved details for an adopted install from what's on disk."""
    info = dict(candidate)
    try:
        with open(os.path.join(candidate["txdata_dir"], "admins.json")) as f:
            master = next((a for a in json.load(f) if a.get("master")), None)
            if master:
                info["tx_username"] = master.get("name")
    except (OSError, ValueError):
        pass
    cfg = os.path.join(candidate["txdata_dir"], "default", "config.json")
    try:
        profile = (json.load(open(cfg)).get("server") or {}).get("dataPath")
    except (OSError, ValueError):
        profile = None
    if profile:
        info.update(_read_server_cfg(profile))
    info.setdefault("game_port", 30120)
    info["artifact_build"] = _artifact_build_of(candidate["server_dir"])
    return info


# ---------------------------------------------------------------- job bodies
# Each takes (ctx, app, inst_id, ...). They load the instance inside an app
# context, do slow work outside of it, and commit progress back.

def _load(app, inst_id):
    from models.tx_instance import TxInstance
    from database import db
    inst = db.session.get(TxInstance, inst_id)
    if not inst:
        raise TxError("Instance not found.")
    return inst


def _set_state(app, inst_id, state, **fields):
    from database import db
    with app.app_context():
        inst = _load(app, inst_id)
        inst.state = state
        for k, v in fields.items():
            setattr(inst, k, v)
        db.session.commit()


def job_install(ctx, app, inst_id, build_choice, open_firewall=True):
    try:
        with app.app_context():
            inst = _load(app, inst_id)
            from database import db
            ctx.set_progress(5, f"Installing txAdmin instance '{inst.name}'")

            ctx.log(f"Creating MySQL database {inst.db_name} and user {inst.db_user}")
            existing = {d["name"] for d in dbsvc.list_databases()}
            if inst.db_name not in existing:
                dbsvc.create_database(inst.db_name)
            if not any(u["user"] == inst.db_user for u in dbsvc.list_users()):
                dbsvc.create_user(inst.db_user, "localhost", inst.db_password, inst.db_name, "all")
            else:
                dbsvc.grant(inst.db_user, "localhost", inst.db_name, "all")
            ctx.set_progress(15)

            build, artifact_dir = ensure_artifact(ctx, build_choice)
            ctx.set_progress(70)

            os.makedirs(inst.txdata_dir, exist_ok=True)
            link = inst.server_dir
            if os.path.islink(link):
                os.remove(link)
            os.symlink(artifact_dir, link)
            inst.artifact_build = build
            db.session.commit()

            ctx.log("Writing systemd unit and txAdmin environment")
            write_unit(inst)
            write_env(inst)
            _systemctl("enable", inst.service_unit)
            if open_firewall:
                _open_firewall(ctx, inst)
            else:
                ctx.log(f"Firewall: ports {inst.tx_port}/tcp and {inst.game_port}/tcp+udp are waiting for admin approval")
            ctx.set_progress(85, "Starting txAdmin")
            _systemctl("restart", inst.service_unit)
            tx_port = inst.tx_port

        if not _wait_for_port(tx_port, 120):
            raise TxError(f"txAdmin didn't start listening on port {tx_port} within 2 minutes — check the instance logs.")
        ctx.log(f"txAdmin is up on port {tx_port}. Log in with the saved credentials and run the setup wizard.")
        _set_state(app, inst_id, "ready")
    except Exception:
        _set_state(app, inst_id, "failed")
        raise


def job_reinstall(ctx, app, inst_id, wipe_db=True, keep_backup=True):
    try:
        with app.app_context():
            from database import db
            inst = _load(app, inst_id)
            ctx.set_progress(5, f"Reinstalling '{inst.name}' — txAdmin will go back to its setup wizard")
            _systemctl("stop", inst.service_unit, timeout=90, check=False)
            ctx.log("Service stopped")

            ts = datetime.now().strftime("%Y%m%d-%H%M%S")
            backup_dir = f"{inst.txdata_dir.rstrip('/')}.bak-{ts}"
            if os.path.isdir(inst.txdata_dir):
                if keep_backup:
                    os.rename(inst.txdata_dir, backup_dir)
                    ctx.log(f"Old txData moved to {backup_dir}")
                else:
                    shutil.rmtree(inst.txdata_dir)
                    ctx.log("Old txData deleted")
            os.makedirs(inst.txdata_dir, exist_ok=True)
            ctx.set_progress(35)

            if wipe_db and inst.db_name:
                if inst.db_name.lower() in dbsvc.SYSTEM_DATABASES:
                    raise TxError("Refusing to wipe a system database.")
                if keep_backup and inst.db_name in {d["name"] for d in dbsvc.list_databases()}:
                    os.makedirs(backup_dir, exist_ok=True)
                    dump_path = os.path.join(backup_dir, f"{inst.db_name}.sql")
                    with open(dump_path, "wb") as f:
                        for chunk in dbsvc.export_stream(inst.db_name):
                            f.write(chunk)
                    ctx.log(f"Database dumped to {dump_path}")
                if inst.db_name in {d["name"] for d in dbsvc.list_databases()}:
                    dbsvc.drop_database(inst.db_name)
                dbsvc.create_database(inst.db_name)
                if inst.db_user and inst.db_user not in dbsvc.PROTECTED_USERS:
                    try:
                        dbsvc.grant(inst.db_user, "localhost", inst.db_name, "all")
                    except dbsvc.DatabaseError as exc:
                        ctx.log(f"Warning: couldn't re-grant {inst.db_user}: {exc}")
                ctx.log(f"Database {inst.db_name} recreated empty")
            ctx.set_progress(60)

            if not inst.tx_username:
                inst.tx_username = "admin"
            if not inst.tx_password:
                inst.tx_password = gen_password()
            db.session.commit()
            write_env(inst)
            ctx.log(f"txAdmin login will be: {inst.tx_username} (password saved in the panel)")
            ctx.set_progress(80, "Starting txAdmin")
            _systemctl("start", inst.service_unit)
            tx_port = inst.tx_port

        if not _wait_for_port(tx_port, 120):
            raise TxError(f"txAdmin didn't come back on port {tx_port} — check the logs.")
        ctx.log("Reinstall complete. Open txAdmin and run the setup wizard — database fields are pre-filled.")
        _set_state(app, inst_id, "ready")
    except Exception:
        _set_state(app, inst_id, "failed")
        raise


def job_update_artifact(ctx, app, inst_id, build_choice):
    try:
        with app.app_context():
            from database import db
            inst = _load(app, inst_id)
            if not inst.managed:
                raise TxError("Artifact switching is only available for panel-managed instances.")
            build, artifact_dir = ensure_artifact(ctx, build_choice)
            ctx.set_progress(80, f"Switching to build {build} and restarting")
            tmp = inst.server_dir + ".new"
            if os.path.lexists(tmp):
                os.remove(tmp)
            os.symlink(artifact_dir, tmp)
            os.replace(tmp, inst.server_dir)
            inst.artifact_build = build
            db.session.commit()
            _systemctl("restart", inst.service_unit, timeout=90)
            tx_port = inst.tx_port
        if not _wait_for_port(tx_port, 120):
            raise TxError("txAdmin didn't come back after the artifact switch — check the logs.")
        _set_state(app, inst_id, "ready")
        prune_artifacts(ctx, app)
    except Exception:
        _set_state(app, inst_id, "failed")
        raise


def job_delete(ctx, app, inst_id, drop_db=False, delete_files=True):
    try:
        _job_delete(ctx, app, inst_id, drop_db, delete_files)
    except Exception:
        try:
            _set_state(app, inst_id, "failed")
        except TxError:
            pass  # row already gone
        raise


def _job_delete(ctx, app, inst_id, drop_db, delete_files):
    from database import db
    with app.app_context():
        inst = _load(app, inst_id)
        snapshot = {k: getattr(inst, k) for k in ("slug", "name", "managed", "base_dir", "txdata_dir", "service_unit",
                                                  "tx_port", "game_port", "db_name", "db_user")}
    ctx.set_progress(5, f"Deleting '{snapshot['name']}'")
    unit = snapshot["service_unit"]
    _systemctl("disable", "--now", unit, timeout=90, check=False)
    ctx.log(f"Stopped and disabled {unit}")

    dropin = _unit_path(unit) + ".d"
    if os.path.isfile(os.path.join(dropin, DROPIN_NAME)):
        os.remove(os.path.join(dropin, DROPIN_NAME))
        try:
            os.rmdir(dropin)
        except OSError:
            pass
    if os.path.exists(_env_path(snapshot["slug"])):
        os.remove(_env_path(snapshot["slug"]))

    if delete_files:
        unit_file = _unit_path(unit)
        if os.path.isfile(unit_file):
            os.remove(unit_file)
            ctx.log(f"Removed {unit_file}")
        base = snapshot["base_dir"]
        safe = base and os.path.isdir(base) and os.path.realpath(base) not in ("/", "/root", "/home", "/etc", "/var", "/usr")
        if safe:
            shutil.rmtree(base)
            ctx.log(f"Deleted {base}")
        if snapshot["txdata_dir"] and os.path.isdir(snapshot["txdata_dir"]) and not _is_inside(snapshot["txdata_dir"], base or "/nonexistent"):
            shutil.rmtree(snapshot["txdata_dir"])
            ctx.log(f"Deleted {snapshot['txdata_dir']}")
    _systemctl("daemon-reload", check=False)
    ctx.set_progress(60)

    if drop_db and snapshot["db_name"]:
        try:
            if snapshot["db_name"] in {d["name"] for d in dbsvc.list_databases()}:
                dbsvc.drop_database(snapshot["db_name"])
                ctx.log(f"Dropped database {snapshot['db_name']}")
            if snapshot["db_user"] and snapshot["db_user"] not in dbsvc.PROTECTED_USERS and \
                    any(u["user"] == snapshot["db_user"] for u in dbsvc.list_users()):
                dbsvc.drop_user(snapshot["db_user"], "localhost")
                ctx.log(f"Dropped MySQL user {snapshot['db_user']}")
        except dbsvc.DatabaseError as exc:
            ctx.log(f"Warning: database cleanup failed: {exc}")

    class _Shim:  # firewall helpers only need the ports/slug
        pass
    shim = _Shim()
    shim.__dict__.update(snapshot)
    if snapshot["managed"]:
        _close_firewall(ctx, shim)

    with app.app_context():
        from models.tx_network import TxDomain, TxPortRequest
        from services import txadmin_net as net
        for dom in TxDomain.query.filter_by(instance_id=inst_id).all():
            if dom.kind == "managed":
                try:
                    net.delete_managed(dom.zone_id, dom.record_id, dom.hostname)
                    ctx.log(f"Removed DNS record {dom.hostname}")
                except Exception as exc:  # noqa: BLE001
                    ctx.log(f"Warning: couldn't remove DNS record {dom.hostname}: {exc}")
            db.session.delete(dom)
        TxPortRequest.query.filter_by(instance_id=inst_id).delete()
        from models.tx_claude import TxClaudeLink
        from services import claude_rc
        for link in TxClaudeLink.query.filter_by(instance_id=inst_id).all():
            claude_rc.stop_session(claude_rc.link_key(link.id))
            db.session.delete(link)
        db.session.delete(_load(app, inst_id))
        db.session.commit()
    ctx.log("Instance removed from the panel")
    prune_artifacts(ctx, app)


def prune_artifacts(ctx, app):
    """Delete cached builds no managed instance points at any more."""
    from models.tx_instance import TxInstance
    with app.app_context():
        used = {os.path.realpath(i.server_dir) for i in TxInstance.query.all()}
    for build in cached_artifacts():
        path = os.path.realpath(os.path.join(ARTIFACT_CACHE, build))
        if path not in used:
            shutil.rmtree(path, ignore_errors=True)
            ctx.log(f"Removed unused cached artifact {build}")


# ---------------------------------------------------------------- password reset

def reset_tx_password(inst, new_password):
    """txAdmin restores admins.json if it's edited while running, so this
    stops the service, rewrites the master hash, then starts it again."""
    if not inst.tx_username or not USERNAME_RE.match(inst.tx_username):
        raise TxError("Set a valid txAdmin username for this instance first.")
    if len(new_password) < 6:
        raise TxError("txAdmin passwords must be at least 6 characters.")
    admins_path = os.path.join(inst.txdata_dir, "admins.json")
    was_active = status(inst)["active"]
    _systemctl("stop", inst.service_unit, timeout=90, check=False)
    try:
        if os.path.isfile(admins_path):
            with open(admins_path) as f:
                admins = json.load(f)
            master = next((a for a in admins if a.get("master")), None)
            if not master:
                raise TxError("admins.json has no master account.")
            master["password_hash"] = bcrypt_hash(new_password)
            inst.tx_username = master.get("name") or inst.tx_username
            tmp = admins_path + ".tmp"
            with open(tmp, "w") as f:
                json.dump(admins, f)
            os.replace(tmp, admins_path)
        inst.tx_password = new_password
        write_env(inst)
    finally:
        if was_active or inst.managed:
            _systemctl("start", inst.service_unit, timeout=90, check=False)
