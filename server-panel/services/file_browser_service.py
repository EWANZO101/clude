import json
import os
import shutil
import time

MAX_FILE_SIZE = 2 * 1024 * 1024  # 2MB safety cap for the browser-based editor

ENTRY_CANDIDATES = {
    "python": ["app.py", "main.py", "run.py", "wsgi.py", "manage.py", "server.py"],
    "node": ["index.js", "server.js", "app.js", "main.js"],
    "php": ["index.php", "server.php", "app.php"],
    "ruby": ["config.ru", "app.rb", "main.rb"],
    "go": ["main.go"],
    "dotnet": ["Program.cs"],
    "java": [],  # usually jar-based; no single conventional entry filename
    "static": [],
    "custom": [],
}

RUNTIME_LABELS = {
    "python": "Python",
    "node": "Node.js",
    "php": "PHP",
    "ruby": "Ruby",
    "go": "Go",
    "dotnet": ".NET",
    "java": "Java",
    "static": "Static site (no process)",
    "custom": "Custom / other",
}


class FileBrowserError(Exception):
    pass


def list_directory(path):
    if not path:
        path = "/home"
    if not os.path.isdir(path):
        raise FileBrowserError(f"'{path}' isn't a directory, or doesn't exist yet.")

    entries = []
    try:
        for name in sorted(os.listdir(path)):
            if name.startswith("."):
                continue
            full = os.path.join(path, name)
            try:
                is_dir = os.path.isdir(full)
                stat = os.stat(full)
            except OSError:
                continue
            entries.append({
                "name": name,
                "path": full,
                "is_dir": is_dir,
                # Added for the file manager UI; existing callers (systemctl,
                # envfiles) only read name/path/is_dir so this is additive.
                "size": None if is_dir else stat.st_size,
                "modified": stat.st_mtime,
            })
    except PermissionError as exc:
        raise FileBrowserError(f"No permission to read {path}.") from exc

    entries.sort(key=lambda e: (not e["is_dir"], e["name"].lower()))
    parent = os.path.dirname(path.rstrip("/")) or "/"
    return {"path": path, "parent": parent if path != "/" else None, "entries": entries}


def detect_entry_files(working_dir, runtime):
    if not os.path.isdir(working_dir):
        raise FileBrowserError(f"'{working_dir}' doesn't exist yet — create/deploy the app there first.")

    found = []
    for name in ENTRY_CANDIDATES.get(runtime, []):
        full = os.path.join(working_dir, name)
        if os.path.isfile(full):
            found.append(full)

    if runtime == "node":
        pkg_path = os.path.join(working_dir, "package.json")
        if os.path.isfile(pkg_path):
            try:
                with open(pkg_path, "r", encoding="utf-8") as f:
                    pkg = json.load(f)
                main = pkg.get("main")
                if main:
                    main_full = os.path.join(working_dir, main)
                    if os.path.isfile(main_full) and main_full not in found:
                        found.insert(0, main_full)
                if isinstance(pkg.get("scripts"), dict) and "start" in pkg["scripts"]:
                    found.insert(0, "npm-start")  # sentinel, not a real path
            except (OSError, json.JSONDecodeError):
                pass

    return found


def build_exec_start(runtime, working_dir, entry_file=None, port=None):
    """Best-effort suggested start command. The user can still hand-edit it."""
    venv_python = os.path.join(working_dir, "venv", "bin", "python")

    if runtime == "python":
        python_bin = venv_python if os.path.isfile(venv_python) else "python3"
        target = entry_file or os.path.join(working_dir, "app.py")
        return f"{python_bin} {target}"

    if runtime == "node":
        if entry_file == "npm-start":
            return "npm start"
        target = entry_file or os.path.join(working_dir, "index.js")
        return f"node {target}"

    if runtime == "php":
        p = port or "8000"
        target = f" {entry_file}" if entry_file else ""
        return f"php -S 0.0.0.0:{p}{target}"

    if runtime == "ruby":
        if entry_file and entry_file.endswith("config.ru"):
            return "bundle exec rackup -o 0.0.0.0"
        target = entry_file or os.path.join(working_dir, "app.rb")
        return f"ruby {target}"

    if runtime == "go":
        target = entry_file or os.path.join(working_dir, "main.go")
        return f"go run {target}"

    if runtime == "dotnet":
        return "dotnet run"

    if runtime == "java":
        return "java -jar app.jar"

    return entry_file or ""


def read_file(path):
    if not os.path.isfile(path):
        raise FileBrowserError(f"'{path}' isn't a file.")
    size = os.path.getsize(path)
    if size > MAX_FILE_SIZE:
        raise FileBrowserError(
            f"That file is {size // 1024}KB — larger than the {MAX_FILE_SIZE // 1024 // 1024}MB editor limit."
        )
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read()
    except PermissionError as exc:
        raise FileBrowserError(f"No permission to read {path}.") from exc


def write_file(path, content):
    if os.path.isdir(path):
        raise FileBrowserError(f"'{path}' is a directory, not a file.")
    try:
        with open(path, "w", encoding="utf-8") as f:
            f.write(content)
    except PermissionError as exc:
        raise FileBrowserError(f"No permission to write {path}.") from exc
    except OSError as exc:
        raise FileBrowserError(f"Failed to save {path}: {exc}") from exc
    return True


# ---------------------------------------------------------------------------
# File manager operations (upload / download / mkdir / rename / delete).
# This panel already runs as root (see systemd/opslab-panel.service) and
# other modules (systemctl, env editor, installers) already grant broad
# filesystem access, so these deliberately aren't sandboxed to one root
# directory — an admin using this panel already has full filesystem access
# via SSH anyway. The guards below catch mistakes (typos, accidental '/'
# operations), not a determined admin.
# ---------------------------------------------------------------------------

_PROTECTED_PATHS = {"/", "/root", "/home", "/etc", "/var", "/usr", "/bin", "/boot", "/lib", "/sys", "/proc", "/dev"}


def safe_filename(name):
    """Strip path separators and null bytes from a filename an admin
    typed or an uploaded file's original name — not a full jail, just
    enough to stop an upload from writing outside the target directory."""
    name = os.path.basename((name or "").replace("\x00", "").strip())
    if not name or name in (".", ".."):
        raise FileBrowserError("Invalid filename.")
    return name


def create_directory(parent_path, name):
    if not os.path.isdir(parent_path):
        raise FileBrowserError(f"'{parent_path}' doesn't exist.")
    safe_name = safe_filename(name)
    dest = os.path.join(parent_path, safe_name)
    if os.path.exists(dest):
        raise FileBrowserError(f"'{safe_name}' already exists here.")
    try:
        os.makedirs(dest)
    except OSError as exc:
        raise FileBrowserError(f"Failed to create folder: {exc}") from exc
    return dest


def save_upload(dest_dir, filename, file_storage):
    """Saves a Werkzeug FileStorage into dest_dir under a sanitized filename."""
    if not os.path.isdir(dest_dir):
        raise FileBrowserError(f"'{dest_dir}' doesn't exist.")
    safe_name = safe_filename(filename)
    dest = os.path.join(dest_dir, safe_name)
    try:
        file_storage.save(dest)
    except OSError as exc:
        raise FileBrowserError(f"Failed to upload {safe_name}: {exc}") from exc
    return dest


def rename_path(path, new_name):
    if not os.path.exists(path):
        raise FileBrowserError(f"'{path}' doesn't exist.")
    safe_name = safe_filename(new_name)
    dest = os.path.join(os.path.dirname(path.rstrip("/")), safe_name)
    if os.path.exists(dest):
        raise FileBrowserError(f"'{safe_name}' already exists here.")
    try:
        os.rename(path, dest)
    except OSError as exc:
        raise FileBrowserError(f"Failed to rename: {exc}") from exc
    return dest


def delete_path(path):
    normalized = os.path.abspath(path.rstrip("/") or "/")
    if normalized in _PROTECTED_PATHS:
        raise FileBrowserError(f"Refusing to delete '{normalized}' — it's a core system path.")
    if not os.path.exists(path):
        raise FileBrowserError(f"'{path}' doesn't exist.")
    try:
        if os.path.isdir(path) and not os.path.islink(path):
            shutil.rmtree(path)
        else:
            os.remove(path)
    except OSError as exc:
        raise FileBrowserError(f"Failed to delete {path}: {exc}") from exc
    return True


def download_path(path):
    """Validated absolute path for send_file, or raises FileBrowserError."""
    if not os.path.isfile(path):
        raise FileBrowserError(f"'{path}' isn't a downloadable file.")
    return path


def format_size(num_bytes):
    if num_bytes is None:
        return "—"
    units = ["B", "KB", "MB", "GB", "TB"]
    val = float(num_bytes)
    for unit in units:
        if val < 1024 or unit == units[-1]:
            return f"{val:.1f} {unit}" if unit != "B" else f"{int(val)} {unit}"
        val /= 1024
    return f"{val:.1f} TB"


def format_modified(epoch_seconds):
    if not epoch_seconds:
        return "—"
    return time.strftime("%Y-%m-%d %H:%M", time.localtime(epoch_seconds))
