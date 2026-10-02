"""
Decides WHEN to run audits; audit_engine.py decides WHAT an audit
contains. Kept separate so the timing rules here (which are the part
most likely to need tweaking) don't risk breaking the audit math.

South Africa Standard Time (SAST) is UTC+2 year-round -- South Africa
does not observe daylight saving time, so a fixed offset is correct
and doesn't need a timezone database dependency.

Window: 07:00-18:00 SAST, every day.
  - If today's day-audit hasn't run yet and we're inside the window,
    run it now.
  - If YESTERDAY's day-audit is missing (the window came and went
    without one, e.g. the kiosk was off), back it up exactly one day
    -- this deliberately doesn't chase an arbitrary backlog of many
    missed days, only the immediately preceding one, matching what
    was asked for.
  - Once a new day-audit lands and completes a full calendar month,
    the previous month gets rolled up automatically. Same for years.

Runs as a daemon thread started from create_app(); checks every
CHECK_INTERVAL_SECONDS whether there's something to do rather than
trying to fire at exact clock times, since the process may not even
be running at 07:00:00 sharp.
"""
import threading
import time
from datetime import datetime, timedelta

SAST_OFFSET = timedelta(hours=2)
WINDOW_START_HOUR = 7
WINDOW_END_HOUR = 18
CHECK_INTERVAL_SECONDS = 600  # 10 minutes


def sast_now() -> datetime:
    return datetime.utcnow() + SAST_OFFSET


def _in_window(now: datetime) -> bool:
    return WINDOW_START_HOUR <= now.hour < WINDOW_END_HOUR


def check_and_run(app, now: datetime | None = None):
    """One pass of the scheduling logic. Takes an explicit `now` so
    tests can drive it without waiting on the real clock; production
    use (audit_scheduler_loop) always calls it with now=None, meaning
    'use the real current SAST time'."""
    from app.audit_engine import run_day_audit, run_month_audit, run_year_audit
    from app.models import AuditRun

    now = now or sast_now()
    if not _in_window(now):
        return

    with app.app_context():
        today = now.date()
        yesterday = today - timedelta(days=1)

        yesterday_key = yesterday.isoformat()
        if not AuditRun.query.filter_by(period_type=AuditRun.PERIOD_DAY, period_key=yesterday_key).first():
            app.logger.info("Audit: backfilling missed day audit for %s", yesterday_key)
            run_day_audit(yesterday, is_backfill=True)

        today_key = today.isoformat()
        if not AuditRun.query.filter_by(period_type=AuditRun.PERIOD_DAY, period_key=today_key).first():
            app.logger.info("Audit: running today's day audit for %s", today_key)
            run_day_audit(today, is_backfill=False)

        # Roll up the previous calendar month, once, whenever we notice
        # we've moved past it and it hasn't been rolled up yet.
        first_of_this_month = today.replace(day=1)
        last_month_end = first_of_this_month - timedelta(days=1)
        last_month_key = f"{last_month_end.year:04d}-{last_month_end.month:02d}"
        if not AuditRun.query.filter_by(period_type=AuditRun.PERIOD_MONTH, period_key=last_month_key).first():
            result = run_month_audit(last_month_end.year, last_month_end.month)
            if result:
                app.logger.info("Audit: rolled up month %s", last_month_key)

        # Same idea for the previous year, checked once we're into a new one.
        if today.month == 1:
            last_year = today.year - 1
            last_year_key = f"{last_year:04d}"
            if not AuditRun.query.filter_by(period_type=AuditRun.PERIOD_YEAR, period_key=last_year_key).first():
                result = run_year_audit(last_year)
                if result:
                    app.logger.info("Audit: rolled up year %s", last_year_key)


def start_scheduler(app):
    def loop():
        while True:
            try:
                check_and_run(app)
            except Exception:
                app.logger.exception("Audit scheduler tick failed")
            time.sleep(CHECK_INTERVAL_SECONDS)

    t = threading.Thread(target=loop, daemon=True, name="AuditScheduler")
    t.start()
    return t
