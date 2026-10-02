"""On-demand backup archiving for admin-registered paths/folders.

Distinct from services/backup_service.py, which silently snapshots
individual config files before the panel edits them (an internal safety
net). This module is the user-facing feature: an admin registers a path
(e.g. /etc/nginx, /var/www/myapp, a database dump directory), and can
create/download/restore/delete full tar.gz archives of it on demand.

Archives live under DATA_DIR/backups/archives, outside the code checkout,
so they survive a redeploy and are never accidentally shipped in a zip.
"""
import os
import re
import shutil
import tarfile
import time

from config import DATA_DIR

ARCHIVE_DIR = os.path.join(DATA_DIR, "backups", "archives")


class BackupError(Exception):
    pass


def _ensure_dir():
    os.makedirs(ARCHIVE_DIR, exist_ok=True)


def _safe_archive_path(filename):
    """Resolve `filename` under ARCHIVE_DIR and refuse anything that would
    escape it (path traversal via ../, absolute paths, symlink tricks)."""
    _ensure_dir()
    candidate = os.path.abspath(os.path.join(ARCHIVE_DIR, os.path.basename(filename)))
    root = os.path.abspath(ARCHIVE_DIR)
    if not candidate.startswith(root + os.sep):
        raise BackupError("Invalid archive filename.")
    return candidate


def validate_source_path(path):
    """Basic sanity checks before a path is registered as a backup target.
    Deliberately doesn't restrict *what* can be backed up (an admin running
    this panel already has root) — just guards against obvious mistakes."""
    if not path or not path.startswith("/"):
        raise BackupError("Path must be an absolute path (starting with /).")
    if not os.path.exists(path):
        raise BackupError(f"{path} does not exist on this server.")
    if path in ("/", ""):
        raise BackupError("Refusing to register '/' as a backup target.")
    return True


def estimate_size(path):
    """Best-effort recursive size of a path, in bytes. Returns None if it
    can't be measured quickly (permission errors etc.) rather than raising —
    this is informational only."""
    try:
        if os.path.isfile(path):
            return os.path.getsize(path)
        total = 0
        for dirpath, _dirnames, filenames in os.walk(path, onerror=lambda e: None):
            for f in filenames:
                fp = os.path.join(dirpath, f)
                try:
                    if not os.path.islink(fp):
                        total += os.path.getsize(fp)
                except OSError:
                    continue
        return total
    except OSError:
        return None


def create_archive(target):
    """tar.gz the target's path into ARCHIVE_DIR. Returns the archive filename."""
    validate_source_path(target.path)
    _ensure_dir()
    ts = time.strftime("%Y%m%d-%H%M%S")
    filename = f"{target.slug()}.{ts}.tar.gz"
    dest = os.path.join(ARCHIVE_DIR, filename)

    src = os.path.abspath(target.path)
    arcname = os.path.basename(src.rstrip("/")) or "root"
    try:
        with tarfile.open(dest, "w:gz") as tar:
            tar.add(src, arcname=arcname)
    except (OSError, tarfile.TarError) as exc:
        # don't leave a partial/corrupt archive behind
        if os.path.exists(dest):
            os.remove(dest)
        raise BackupError(f"Failed to archive {target.path}: {exc}") from exc

    return filename


def list_archives(slug_prefix=None):
    """All archives, newest first. If slug_prefix is given, only archives
    belonging to that target."""
    _ensure_dir()
    out = []
    for name in os.listdir(ARCHIVE_DIR):
        if not name.endswith(".tar.gz"):
            continue
        if slug_prefix and not name.startswith(slug_prefix + "."):
            continue
        full = os.path.join(ARCHIVE_DIR, name)
        try:
            stat = os.stat(full)
        except OSError:
            continue
        # filename shape: <slug>.<YYYYmmdd-HHMMSS>.tar.gz
        m = re.match(r"^(.*)\.(\d{8}-\d{6})\.tar\.gz$", name)
        slug = m.group(1) if m else name
        out.append({
            "filename": name,
            "slug": slug,
            "path": full,
            "size_bytes": stat.st_size,
            "created_at": stat.st_mtime,
            "created_str": time.strftime("%Y-%m-%d %H:%M", time.localtime(stat.st_mtime)),
        })
    out.sort(key=lambda a: a["created_at"], reverse=True)
    return out


def total_archive_bytes():
    return sum(a["size_bytes"] for a in list_archives())


def delete_archive(filename):
    path = _safe_archive_path(filename)
    if not os.path.isfile(path):
        raise BackupError("Archive not found.")
    try:
        os.remove(path)
    except OSError as exc:
        raise BackupError(f"Failed to delete {filename}: {exc}") from exc
    return True


def restore_archive(filename, destination):
    """Extract an archive back to `destination` (a directory). The archive's
    top-level entry is extracted as-is into destination — existing files
    with the same names are overwritten, nothing else under destination is
    touched or removed."""
    path = _safe_archive_path(filename)
    if not os.path.isfile(path):
        raise BackupError("Archive not found.")
    if not destination or not destination.startswith("/"):
        raise BackupError("Restore destination must be an absolute path.")

    os.makedirs(destination, exist_ok=True)
    try:
        with tarfile.open(path, "r:gz") as tar:
            # Guard against path-traversal members inside the archive
            # (CVE-2007-4559-style) before extracting anything.
            base = os.path.abspath(destination)
            for member in tar.getmembers():
                member_path = os.path.abspath(os.path.join(base, member.name))
                if not member_path.startswith(base + os.sep) and member_path != base:
                    raise BackupError(f"Refusing to extract unsafe path in archive: {member.name}")
            tar.extractall(path=destination)
    except (OSError, tarfile.TarError) as exc:
        raise BackupError(f"Failed to restore {filename}: {exc}") from exc
    return True


def archive_download_path(filename):
    """Validated absolute path for send_file, or raises BackupError."""
    path = _safe_archive_path(filename)
    if not os.path.isfile(path):
        raise BackupError("Archive not found.")
    return path


def disk_free_bytes():
    try:
        usage = shutil.disk_usage(ARCHIVE_DIR if os.path.isdir(ARCHIVE_DIR) else DATA_DIR)
        return usage.free
    except OSError:
        return None
