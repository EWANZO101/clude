"""
Recovery points (spec Section 19): a snapshot of the application files and
config taken immediately before an update is applied, kept in a directory
tree entirely separate from app_install_dir (spec Section 46) so an update
can never accidentally delete the only copy of what it's about to replace.

One recovery point per deployment_id — never overwritten, so a chain of
back-to-back updates always has each step's true "before" state available,
not just the most recent one.
"""
import json
import logging
import os
import shutil
from datetime import datetime

log = logging.getLogger("agent.recovery")

META_FILENAME = "meta.json"
APP_BACKUP_DIRNAME = "app"
CONFIG_BACKUP_FILENAME = "kiosk_config.json"


class RecoveryError(Exception):
    pass


def _deployment_recovery_path(recovery_dir: str, deployment_id: str) -> str:
    return os.path.join(recovery_dir, deployment_id)


def make_recovery_point(recovery_dir: str, deployment_id: str, app_install_dir: str,
                         kiosk_config_path: str, previous_version: str) -> str:
    """Snapshots the current state before an update touches anything.
    Returns the path to the recovery point directory. Safe to call even when
    there's nothing installed yet (first-ever update on a fresh machine) —
    an empty/missing app_install_dir just produces an empty snapshot, which
    is exactly the correct thing to roll back to."""
    target = _deployment_recovery_path(recovery_dir, deployment_id)
    if os.path.exists(target):
        raise RecoveryError(f"recovery point already exists for deployment {deployment_id}")

    os.makedirs(target, exist_ok=True)

    app_backup = os.path.join(target, APP_BACKUP_DIRNAME)
    if os.path.isdir(app_install_dir):
        shutil.copytree(app_install_dir, app_backup)
        had_app = True
    else:
        os.makedirs(app_backup, exist_ok=True)
        had_app = False

    had_config = False
    if kiosk_config_path and os.path.isfile(kiosk_config_path):
        shutil.copy2(kiosk_config_path, os.path.join(target, CONFIG_BACKUP_FILENAME))
        had_config = True

    meta = {
        "deployment_id": deployment_id,
        "previous_version": previous_version,
        "created_at": datetime.utcnow().isoformat() + "Z",
        "had_app": had_app,
        "had_config": had_config,
        "kiosk_config_path": kiosk_config_path or None,
    }
    with open(os.path.join(target, META_FILENAME), "w", encoding="utf-8") as f:
        json.dump(meta, f, indent=2)

    log.info("Recovery point created for deployment %s (previous_version=%s)",
              deployment_id, previous_version)
    return target


def restore_recovery_point(recovery_dir: str, deployment_id: str, app_install_dir: str) -> dict:
    """Restores app_install_dir (and, if one was captured, kiosk_config_path)
    back to exactly what they were before this deployment started. Returns
    the recovery point's metadata so the caller can report which version was
    restored to. Raises RecoveryError if no recovery point exists — never
    guesses or falls back to "just leave it as-is", since that would silently
    convert a rollback into a no-op the caller believes succeeded."""
    target = _deployment_recovery_path(recovery_dir, deployment_id)
    meta_path = os.path.join(target, META_FILENAME)
    if not os.path.isfile(meta_path):
        raise RecoveryError(f"no recovery point found for deployment {deployment_id}")

    with open(meta_path, "r", encoding="utf-8") as f:
        meta = json.load(f)

    app_backup = os.path.join(target, APP_BACKUP_DIRNAME)
    if os.path.isdir(app_install_dir):
        shutil.rmtree(app_install_dir)
    if meta.get("had_app"):
        shutil.copytree(app_backup, app_install_dir)
    else:
        os.makedirs(app_install_dir, exist_ok=True)

    kiosk_config_path = meta.get("kiosk_config_path")
    if meta.get("had_config") and kiosk_config_path:
        config_backup = os.path.join(target, CONFIG_BACKUP_FILENAME)
        os.makedirs(os.path.dirname(kiosk_config_path) or ".", exist_ok=True)
        shutil.copy2(config_backup, kiosk_config_path)

    log.info("Restored recovery point for deployment %s (back to version=%s)",
              deployment_id, meta.get("previous_version"))
    return meta


def prune_old_recovery_points(recovery_dir: str, keep_latest: int = 5) -> None:
    """Housekeeping only — never called automatically mid-deployment. Keeps
    disk usage bounded on a machine that's been updated many times, without
    touching the most recent N recovery points."""
    if not os.path.isdir(recovery_dir):
        return
    entries = []
    for name in os.listdir(recovery_dir):
        path = os.path.join(recovery_dir, name)
        meta_path = os.path.join(path, META_FILENAME)
        if os.path.isfile(meta_path):
            entries.append((os.path.getmtime(meta_path), path))
    entries.sort(reverse=True)
    for _, path in entries[keep_latest:]:
        shutil.rmtree(path, ignore_errors=True)
        log.info("Pruned old recovery point: %s", path)
