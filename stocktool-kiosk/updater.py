"""
Self-update logic for the single-file .exe.

Windows (like Linux) allows renaming/moving a running executable's file
even while it's open — what it won't allow is overwriting/deleting it in
place. That's what makes this rename-swap-relaunch pattern safe without
needing a separate installer or updater helper binary:

  1. Download the new build to <dir>/StockToolKiosk_new.exe, next to the
     currently-running one.
  2. Verify its SHA-256 against what the server published. Abort (and
     delete the partial download) on any mismatch — a corrupted or
     tampered download must never be applied.
  3. Rename the running exe -> StockToolKiosk_old.exe (safe: renaming an
     open/running executable doesn't affect the running process).
  4. Rename the verified new download -> StockToolKiosk.exe (the exact
     path the running exe had).
  5. Write a pending-update marker recording both paths.
  6. Spawn the new exe as a detached process, then exit this one.

On the NEW process's very first startup, main.py calls
confirm_or_rollback() before anything else:
  - No marker file -> normal startup, nothing to do.
  - Marker present -> this process IS the just-applied update. Try to
    boot for real (the caller supplies a boot-check function). If it
    succeeds within the timeout, delete the old backup and the marker —
    the update is committed. If it fails, relaunch the OLD backup exe
    (restoring its original filename) and exit(1) — rolling back to the
    last-known-good build automatically, with no user action needed.
"""
import os
import sys
import json
import time
import hashlib
import logging
import subprocess
import urllib.request

log = logging.getLogger("updater")

_MARKER_NAME = "update_pending.json"


def _current_exe_path() -> str:
    """Path to the running executable — the frozen .exe when packaged,
    or this script's own path when run from source (dev/test)."""
    if getattr(sys, "frozen", False):
        return sys.executable
    return os.path.abspath(sys.argv[0])


def _marker_path(exe_dir: str) -> str:
    return os.path.join(exe_dir, _MARKER_NAME)


def download_update(url: str, dest_path: str, timeout: int = 60) -> bool:
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp, open(dest_path, "wb") as f:
            f.write(resp.read())
        return True
    except Exception:
        log.exception("Update download failed")
        if os.path.exists(dest_path):
            os.remove(dest_path)
        return False


def verify_checksum(path: str, expected_sha256: str) -> bool:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    actual = h.hexdigest()
    ok = actual.lower() == (expected_sha256 or "").lower()
    if not ok:
        log.error("Checksum mismatch: expected %s, got %s", expected_sha256, actual)
    return ok


def apply_update(new_file_path: str) -> bool:
    """Performs the rename-swap-relaunch dance. Never returns on success
    (the process exits); returns False if something went wrong before
    the point of no return, so the caller can log/clean up."""
    current_exe = _current_exe_path()
    exe_dir = os.path.dirname(current_exe)
    old_backup = os.path.join(exe_dir, "StockToolKiosk_old.exe")

    try:
        if os.path.exists(old_backup):
            os.remove(old_backup)  # leftover from a previous update cycle
        os.rename(current_exe, old_backup)
        os.rename(new_file_path, current_exe)
    except Exception:
        log.exception("Failed to swap files during update — leaving the running build untouched")
        # best-effort undo if the first rename succeeded but the second didn't
        if os.path.exists(old_backup) and not os.path.exists(current_exe):
            os.rename(old_backup, current_exe)
        return False

    marker = {
        "new_exe_path": current_exe,
        "old_backup_path": old_backup,
        "started_at": time.time(),
    }
    with open(_marker_path(exe_dir), "w") as f:
        json.dump(marker, f)

    log.info("Update applied — relaunching as the new build.")
    subprocess.Popen([current_exe], close_fds=True,
                      creationflags=subprocess.CREATE_NEW_PROCESS_GROUP if os.name == "nt" else 0)
    sys.exit(0)


def confirm_or_rollback(boot_check_fn, timeout_seconds: int = 20) -> None:
    """
    Call this FIRST thing in main(), before creating the app. If this
    process is the result of an update (marker file present), verifies
    the new build actually works by calling boot_check_fn() — which
    should create the app, start the server, and confirm it responds —
    within timeout_seconds. Commits (deletes the old backup) on success,
    or rolls back (relaunches the old backup, restoring its filename)
    and exits on failure.

    If there's no pending-update marker, this is a completely normal
    startup and the function returns immediately having done nothing.
    """
    current_exe = _current_exe_path()
    exe_dir = os.path.dirname(current_exe)
    marker_path = _marker_path(exe_dir)

    if not os.path.exists(marker_path):
        return  # normal startup, no pending update to confirm

    with open(marker_path) as f:
        marker = json.load(f)
    old_backup = marker.get("old_backup_path")

    log.info("Pending update detected — verifying this build boots correctly before committing.")
    deadline = time.time() + timeout_seconds
    booted_ok = False
    try:
        booted_ok = boot_check_fn(deadline)
    except Exception:
        log.exception("Boot check raised while confirming the update")
        booted_ok = False

    if booted_ok:
        log.info("New build confirmed healthy — committing update.")
        try:
            if old_backup and os.path.exists(old_backup):
                os.remove(old_backup)
        except Exception:
            log.exception("Could not remove old backup after a successful update (non-fatal)")
        try:
            os.remove(marker_path)
        except Exception:
            pass
        return

    log.error("New build failed its boot check — rolling back to the previous version.")
    try:
        if old_backup and os.path.exists(old_backup):
            if os.path.exists(current_exe):
                os.remove(current_exe)
            os.rename(old_backup, current_exe)
            subprocess.Popen([current_exe], close_fds=True,
                              creationflags=subprocess.CREATE_NEW_PROCESS_GROUP if os.name == "nt" else 0)
    finally:
        try:
            os.remove(marker_path)
        except Exception:
            pass
        log.error("Rolled back. Exiting the failed build.")
        sys.exit(1)
