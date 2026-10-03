"""
Decides WHEN the Pastel/Sage Active sync runs automatically, mirroring
app/audit_scheduler.py's split between "when" (this file) and "what"
(app/pastel_sync.py). Runs as a daemon thread started from create_app(),
same convention as the audit scheduler and backup_loop.

Does nothing at all unless pastel_enabled is set AND the OAuth flow has
already produced an access token -- this is purely opt-in.
"""
import threading
import time
import logging

log = logging.getLogger("pastel")

CHECK_INTERVAL_SECONDS = 60  # how often we check "is it time yet"; actual sync cadence is pastel_sync_interval_seconds

_last_run_at = 0.0
_wake_event = threading.Event()


def trigger_sync_now():
    """Lets an admin action (or another module) skip the wait for the
    next scheduled cycle, same pattern as backup_loop.trigger_backup_now."""
    _wake_event.set()


def _loop(app):
    global _last_run_at
    from app.settings import load_settings
    from app.pastel_sync import PastelSyncEngine
    from app.pastel_client import PastelAuthError

    engine = PastelSyncEngine(app)

    while True:
        _wake_event.wait(timeout=CHECK_INTERVAL_SECONDS)
        _wake_event.clear()

        with app.app_context():
            settings = load_settings(app.config["DATA_DIR"])
            if not settings.get("pastel_enabled") or not settings.get("pastel_access_token"):
                continue

            interval = settings.get("pastel_sync_interval_seconds", 900)
            if time.time() - _last_run_at < interval:
                continue

            try:
                engine.run_full_sync(settings)
            except PastelAuthError as e:
                log.warning("Pastel auto-sync skipped: %s", e)
            except Exception:
                log.exception("Pastel auto-sync pass failed unexpectedly")
            finally:
                _last_run_at = time.time()


def start_scheduler(app):
    thread = threading.Thread(target=_loop, args=(app,), daemon=True, name="pastel-sync-loop")
    thread.start()
