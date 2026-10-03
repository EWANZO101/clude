"""
Auto-deletes welding-wire coils 30 days after they became Empty /
Finished (WireCoil.empty_at) -- see routes_wire.py's docstring for
the full rule set this implements.

Kept as its own tiny scheduler (same daemon-thread pattern as
audit_scheduler.py / pastel_scheduler.py) rather than folded into
either of those, since this has nothing to do with audits or Pastel
sync and shouldn't get tangled up with their timing rules.
"""
import threading
import time
from datetime import datetime, timedelta, timezone

CHECK_INTERVAL_SECONDS = 3600  # hourly is plenty for a 30-day window
EMPTY_RETENTION_DAYS = 30


def purge_expired_empty_coils():
    """Deletes any WireCoil that's been Empty/Finished for 30+ days,
    along with its Barcode registration (so the code can be reused).
    Historical WireTransaction rows for that coil are deliberately
    left in place -- they still drive project/user usage reporting
    (see routes_wire.py's _coil_label, which already falls back to
    'coil #<id>' once the coil itself is gone) -- only the live coil
    record and its barcode go away. Returns the number of coils
    deleted, for logging/testing."""
    from app.models import db, WireCoil, Barcode

    cutoff = datetime.now(timezone.utc) - timedelta(days=EMPTY_RETENTION_DAYS)
    expired = WireCoil.query.filter(
        WireCoil.status == WireCoil.STATUS_EMPTY,
        WireCoil.empty_at.isnot(None),
        WireCoil.empty_at < cutoff,
    ).all()
    for coil in expired:
        Barcode.query.filter_by(entity_type="wire", entity_id=coil.id).delete()
        db.session.delete(coil)
    if expired:
        db.session.commit()
    return len(expired)


def start_scheduler(app):
    def loop():
        while True:
            try:
                with app.app_context():
                    deleted = purge_expired_empty_coils()
                    if deleted:
                        app.logger.info(
                            "Wire cleanup: deleted %d welding wire box(es) empty 30+ days.", deleted
                        )
            except Exception:
                app.logger.exception("Wire cleanup scheduler tick failed")
            time.sleep(CHECK_INTERVAL_SECONDS)

    t = threading.Thread(target=loop, daemon=True, name="WireCleanupScheduler")
    t.start()
    return t
