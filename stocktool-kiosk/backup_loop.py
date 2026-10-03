"""
Periodic backup upload to stocktoolsetup.opslabsystems.cloud.

No-ops entirely until app/cloud_setup.py has paired this kiosk (i.e.
settings.json has a setup_installation_token) — same "dormant until
configured" pattern sync_loop.py already uses for the cloud sync engine.
Started by server_supervisor.Supervisor alongside the embedded server; nothing
about this opens any inbound port or changes the kiosk's bind mode —
it's an outbound HTTPS POST only.
"""
import io
import json
import logging
import os
import threading
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timedelta, timezone

log = logging.getLogger("backup_loop")

DEFAULT_INTERVAL_SECONDS = 6 * 60 * 60  # every 6 hours -- used when no schedule is set
MIN_INTERVAL_SECONDS = 30 * 60  # floor, in case someone hand-edits settings.json
_TRIGGER = threading.Event()  # set by app/routes_backup.py's "Backup Now" endpoint


def trigger_backup_now():
    _TRIGGER.set()


def _log_sync(app, status: str, message: str) -> None:
    """Writes a SyncLog row so the Sync Log page shows real activity.
    Was previously a Part-3-only placeholder table with nothing writing
    to it -- backups are the sync activity that actually happens today,
    so this repurposes it rather than leaving it permanently empty."""
    from app.models import db, SyncLog
    try:
        with app.app_context():
            db.session.add(SyncLog(direction="push", entity_type="backup", status=status, message=message))
            db.session.commit()
    except Exception:
        log.exception("Could not write backup attempt to SyncLog (backup itself is unaffected)")


def _upload_once(app, base: str, token: str, db_path: str, timeout: int = 60) -> bool:
    if not os.path.isfile(db_path):
        log.warning("No local DB file at %s yet — skipping this backup cycle.", db_path)
        _log_sync(app, "error", "No local database file found to back up.")
        return False

    boundary = uuid.uuid4().hex
    with open(db_path, "rb") as f:
        file_bytes = f.read()

    body = io.BytesIO()
    body.write(f"--{boundary}\r\n".encode())
    body.write(
        b'Content-Disposition: form-data; name="db"; filename="kiosk_local.db"\r\n'
        b"Content-Type: application/octet-stream\r\n\r\n"
    )
    body.write(file_bytes)
    body.write(f"\r\n--{boundary}--\r\n".encode())

    req = urllib.request.Request(
        f"{base.rstrip('/')}/api/kiosk/backup",
        data=body.getvalue(),
        method="POST",
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": f"multipart/form-data; boundary={boundary}",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            ok = 200 <= resp.status < 300
            if ok:
                _log_sync(app, "success", f"Backup uploaded ({len(file_bytes)} bytes).")
            else:
                log.warning("Backup upload returned HTTP %d", resp.status)
                _log_sync(app, "error", f"Backup upload returned HTTP {resp.status}.")
            return ok
    except (urllib.error.URLError, OSError) as exc:
        log.warning("Backup upload failed (will retry next cycle): %s", exc)
        _log_sync(app, "error", f"Backup upload failed: {exc}")
        return False


def _fetch_schedule_hour_utc(base: str, token: str, timeout: int = 10) -> int | None:
    """Checks whether an admin has pinned backups to a specific UTC hour
    from the stocktoolsetup portal. Returns None (-> use the default flat
    interval) on no-schedule-set OR on any network/parse failure -- a
    schedule-check hiccup should never be able to stop backups happening
    entirely, just fall back to the safe default cadence for this cycle."""
    req = urllib.request.Request(
        f"{base.rstrip('/')}/api/kiosk/backup-schedule",
        headers={"Authorization": f"Bearer {token}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            hour = data.get("hour_utc")
            return int(hour) if hour is not None else None
    except (urllib.error.URLError, OSError, ValueError, TypeError) as exc:
        log.warning("Could not fetch backup schedule (using default interval this cycle): %s", exc)
        return None


def _seconds_until_next_hour_utc(hour: int) -> float:
    now = datetime.now(timezone.utc)
    target = now.replace(hour=hour, minute=0, second=0, microsecond=0)
    if target <= now:
        target += timedelta(days=1)
    return (target - now).total_seconds()


def start_backup_loop(app) -> threading.Thread | None:
    from app.settings import load_settings

    settings = load_settings(app.config["DATA_DIR"])
    token = settings.get("setup_installation_token")
    base = settings.get("setup_api_base")
    if not token or not base:
        log.info("Not paired with StockTool Setup yet — no backup loop this run "
                 "(run 'StockTool Kiosk Setup' to pair).")
        return None

    db_path = os.path.join(app.config["DATA_DIR"], "kiosk_local.db")

    def loop():
        # First backup shortly after startup, not immediately — let the
        # app finish settling in (migrations, sync, etc.) first.
        _TRIGGER.wait(timeout=60)
        _TRIGGER.clear()

        while True:
            try:
                _upload_once(app, base, token, db_path)
            except Exception:
                log.exception("Backup cycle failed unexpectedly")
                _log_sync(app, "error", "Backup cycle failed unexpectedly -- see service.log.")

            hour_utc = _fetch_schedule_hour_utc(base, token)
            if hour_utc is not None:
                wait_seconds = _seconds_until_next_hour_utc(hour_utc)
                log.info(
                    "Backup schedule set to %02d:00 UTC — next backup in %.0f minutes.",
                    hour_utc, wait_seconds / 60,
                )
            else:
                wait_seconds = max(MIN_INTERVAL_SECONDS, DEFAULT_INTERVAL_SECONDS)

            # Wake up early if something calls trigger_backup_now().
            _TRIGGER.wait(timeout=wait_seconds)
            _TRIGGER.clear()

    t = threading.Thread(target=loop, daemon=True)
    t.start()
    return t
