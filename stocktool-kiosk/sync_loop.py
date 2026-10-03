import os
import time
import logging
import threading

log = logging.getLogger("sync_loop")

MIN_INTERVAL_SECONDS = 30  # floor, regardless of what the cloud config says


def _maybe_apply_update(app, engine):
    """Checks for a newer release and, if the download verifies against
    its published checksum, SCHEDULES it to apply after a countdown
    (see app/update_notifier.py) rather than applying immediately --
    that used to happen with zero warning to whoever was using the
    kiosk. Any failure here is logged and simply tried again next
    cycle; it never crashes the app."""
    from version import __version__, is_newer
    from updater import download_update, verify_checksum, apply_update, _current_exe_path
    from app.update_notifier import schedule_update, get_status

    if get_status()["pending"]:
        return  # already counting down to a previously-verified update

    release = engine.check_for_update()
    if not release or not is_newer(release.get("version", "0"), __version__):
        return

    log.info("Update available: %s -> %s", __version__, release["version"])
    exe_dir = os.path.dirname(_current_exe_path())
    new_path = os.path.join(exe_dir, "StockToolKiosk_new.exe")

    if not download_update(release["download_url"], new_path):
        with app.app_context():
            from app.models import db, SyncLog
            db.session.add(SyncLog(direction="pull", entity_type=None, status="error",
                                    message=f"Update download failed for {release['version']}"))
            db.session.commit()
        return

    if not verify_checksum(new_path, release.get("checksum_sha256", "")):
        os.remove(new_path)
        with app.app_context():
            from app.models import db, SyncLog
            db.session.add(SyncLog(direction="pull", entity_type=None, status="error",
                                    message=f"Update {release['version']} failed checksum verification — discarded"))
            db.session.commit()
        return

    log.info("Update %s verified — scheduling apply with a warning countdown.", release["version"])
    schedule_update(new_path, release["version"], apply_update)


def start_sync_loop(app) -> threading.Thread:
    engine = app.config["SYNC_ENGINE"]

    def loop():
        # Run an initial sync immediately on startup rather than waiting a
        # full interval, so the kiosk has fresh data as soon as possible.
        engine.ensure_registered()
        engine.fetch_config()
        engine.pull()
        engine.push()
        engine.heartbeat()

        while True:
            from app.models import SyncState
            with app.app_context():
                interval = SyncState.get().sync_interval_seconds
            time.sleep(max(MIN_INTERVAL_SECONDS, interval))

            try:
                if not engine.ensure_registered():
                    log.warning("Still not registered with the cloud (offline?) — will retry next cycle.")
                    continue
                engine.pull()
                engine.push()
                engine.heartbeat()
                _maybe_apply_update(app, engine)
            except Exception:
                # A sync cycle failing must never take down the kiosk —
                # log it and try again on the next interval.
                log.exception("Sync cycle failed unexpectedly")

    t = threading.Thread(target=loop, daemon=True)
    t.start()
    return t
