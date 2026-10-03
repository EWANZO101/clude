import os
import shutil
import time

BACKUP_ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "backups")
BACKUP_ROOT = os.path.abspath(BACKUP_ROOT)


class BackupError(Exception):
    pass


def backup_file(path):
    """Copy `path` into the backups dir with a timestamp suffix. No-op (returns None)
    if the file doesn't exist yet — nothing to protect on a first-time write."""
    if not os.path.isfile(path):
        return None

    os.makedirs(BACKUP_ROOT, exist_ok=True)
    ts = time.strftime("%Y%m%d-%H%M%S")
    name = os.path.basename(path)
    dest = os.path.join(BACKUP_ROOT, f"{name}.{ts}.bak")
    try:
        shutil.copy2(path, dest)
    except OSError as exc:
        raise BackupError(f"Failed to back up {path}: {exc}") from exc
    return dest


def list_backups(name_prefix):
    """All backups for a given original filename, newest first."""
    if not os.path.isdir(BACKUP_ROOT):
        return []
    matches = [f for f in os.listdir(BACKUP_ROOT) if f.startswith(name_prefix + ".") and f.endswith(".bak")]
    matches.sort(reverse=True)
    return [{"filename": m, "path": os.path.join(BACKUP_ROOT, m)} for m in matches]


def restore_backup(backup_path, original_path):
    if not os.path.isfile(backup_path):
        raise BackupError(f"Backup file {backup_path} not found.")
    try:
        shutil.copy2(backup_path, original_path)
    except OSError as exc:
        raise BackupError(f"Failed to restore {original_path}: {exc}") from exc
    return True
