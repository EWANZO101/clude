"""
Periodic background loop: checks stocktoolsetup.opslabsystems.cloud
for a newer published build (via update_checker.py) and, if verified,
hands off to updater.py / app/update_notifier.py to apply it with a
warning countdown -- the exact same apply mechanism sync_loop.py's
_maybe_apply_update uses for the (dormant) full-sync path, just fed by
UpdateChecker instead of SyncEngine.

No-ops entirely until paired with stocktoolsetup -- same
dormant-until-configured pattern as backup_loop.py and relay_client.py
-- so it's always safe to start unconditionally.
"""
import os
import threading
import time
import logging

log = logging.getLogger("update_check_loop")

CHECK_INTERVAL_SECONDS = 21600  # 6h -- matches the existing backup cadence


def _check_once(app):
    from version import __version__, is_newer
    from updater import download_update, verify_checksum, apply_update, _current_exe_path
    from app.update_notifier import schedule_update, get_status
    from update_checker import UpdateChecker

    if get_status()["pending"]:
        return  # already counting down to a previously-verified update

    checker = UpdateChecker(app)
    release = checker.check_for_update()
    if not release or not is_newer(release.get("version", "0"), __version__):
        return

    log.info("Update available: %s -> %s", __version__, release["version"])
    exe_dir = os.path.dirname(_current_exe_path())
    new_path = os.path.join(exe_dir, "StockToolKiosk_new.exe")

    if not download_update(release["download_url"], new_path):
        return

    if not verify_checksum(new_path, release.get("checksum_sha256", "")):
        os.remove(new_path)
        log.error("Update %s failed checksum verification -- discarded.", release["version"])
        return

    log.info("Update %s verified -- scheduling apply with a warning countdown.", release["version"])
    schedule_update(new_path, release["version"], apply_update)


def start_update_check_loop(app) -> threading.Thread:
    def loop():
        while True:
            try:
                _check_once(app)
            except Exception:
                log.exception("Update check cycle failed unexpectedly")
            time.sleep(CHECK_INTERVAL_SECONDS)

    t = threading.Thread(target=loop, daemon=True, name="UpdateCheckLoop")
    t.start()
    return t
