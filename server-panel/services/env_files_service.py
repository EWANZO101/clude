import os
import shutil
import time

from services import file_browser_service as fb

MAX_FILE_SIZE = fb.MAX_FILE_SIZE

# Roots scanned in addition to any ServiceDefinition.working_dir already
# known to the panel. Kept shallow + skip-list guarded so a scan never
# wanders into venvs / node_modules / the whole filesystem.
DEFAULT_SEARCH_ROOTS = ["/root", "/home", "/opt", "/srv", "/var/www"]

SKIP_DIR_NAMES = {
    "venv", ".venv", "env", "node_modules", "__pycache__", ".git",
    "site-packages", "dist", "build", ".cache", ".mypy_cache",
    ".pytest_cache", "backups",
}

MAX_DEPTH = 5
MAX_RESULTS = 400


class EnvFilesError(Exception):
    pass


def _is_env_filename(name):
    if name == ".env":
        return True
    if name.startswith(".env."):
        return True
    if name.startswith(".env-"):
        return True
    if ".env.bak-" in name:
        return True
    if name.endswith(".env"):
        return True
    return False


def _walk(root, depth, results, seen):
    if depth > MAX_DEPTH or len(results) >= MAX_RESULTS:
        return
    try:
        entries = os.scandir(root)
    except (PermissionError, FileNotFoundError, NotADirectoryError):
        return
    with entries:
        for entry in entries:
            if len(results) >= MAX_RESULTS:
                return
            try:
                if entry.is_symlink():
                    continue
                if entry.is_dir():
                    if entry.name in SKIP_DIR_NAMES or entry.name.startswith("."):
                        continue
                    _walk(entry.path, depth + 1, results, seen)
                elif entry.is_file():
                    if _is_env_filename(entry.name) and entry.path not in seen:
                        seen.add(entry.path)
                        try:
                            stat = entry.stat()
                        except OSError:
                            continue
                        results.append({
                            "path": entry.path,
                            "dir": os.path.dirname(entry.path),
                            "name": entry.name,
                            "size": stat.st_size,
                            "mtime": stat.st_mtime,
                            "is_backup": ".env.bak-" in entry.name,
                        })
            except OSError:
                continue


def discover_env_files(extra_dirs=None):
    """Scan DEFAULT_SEARCH_ROOTS plus any extra_dirs (e.g. known service
    working dirs) for .env-style files. Returns a de-duped, sorted list."""
    results = []
    seen = set()

    roots = list(DEFAULT_SEARCH_ROOTS)
    for d in (extra_dirs or []):
        if d and d not in roots:
            roots.append(d)

    for root in roots:
        _walk(root, 0, results, seen)

    results.sort(key=lambda r: (r["is_backup"], r["path"].lower()))
    return results


def read_env_file(path):
    return fb.read_file(path)


def write_env_file(path, content):
    fb.write_file(path, content)


def create_env_file(path):
    if os.path.exists(path):
        raise EnvFilesError(f"'{path}' already exists.")
    parent = os.path.dirname(path)
    if not os.path.isdir(parent):
        raise EnvFilesError(f"Directory '{parent}' doesn't exist.")
    try:
        with open(path, "w", encoding="utf-8") as f:
            f.write("")
    except OSError as exc:
        raise EnvFilesError(f"Couldn't create '{path}': {exc}") from exc


def backup_env_file(path):
    if not os.path.isfile(path):
        raise EnvFilesError(f"'{path}' isn't a file.")
    stamp = time.strftime("%Y%m%d-%H%M%S")
    backup_path = f"{path}.bak-{stamp}"
    try:
        shutil.copy2(path, backup_path)
    except OSError as exc:
        raise EnvFilesError(f"Backup failed: {exc}") from exc
    return backup_path


def delete_env_file(path):
    if not os.path.isfile(path):
        raise EnvFilesError(f"'{path}' isn't a file.")
    try:
        os.remove(path)
    except OSError as exc:
        raise EnvFilesError(f"Delete failed: {exc}") from exc


def list_directory_all(path):
    """Like file_browser_service.list_directory but doesn't hide dotfiles —
    needed here since .env* is exactly what we want visible."""
    if not path:
        path = "/home"
    if not os.path.isdir(path):
        raise EnvFilesError(f"'{path}' isn't a directory, or doesn't exist yet.")

    entries = []
    try:
        for name in sorted(os.listdir(path)):
            full = os.path.join(path, name)
            try:
                is_dir = os.path.isdir(full)
            except OSError:
                continue
            entries.append({"name": name, "path": full, "is_dir": is_dir})
    except PermissionError as exc:
        raise EnvFilesError(f"No permission to read {path}.") from exc

    entries.sort(key=lambda e: (not e["is_dir"], e["name"].lower()))
    parent = os.path.dirname(path.rstrip("/")) or "/"
    return {"path": path, "parent": parent if path != "/" else None, "entries": entries}
