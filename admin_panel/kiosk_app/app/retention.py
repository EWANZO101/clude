"""POPIA Condition 5 (retention and restriction of records) support.

Nothing in here runs on its own opinion of "how long is too long" — there
is no single retention period that's correct for every deployment (e.g. an
OHS-driven PPE issuance trail may need to outlive a plain login-activity
log), so purging only ever happens once an admin has explicitly set
`activity_log_retention_days` in the kiosk config (same Agent-applied
config channel as auto_logout_minutes/tenant_name — see app/config.py and
app/backup.py's identical pattern for the daily backup schedule). Until
that's set, purge_older_than() is only ever reachable from the manual
"Purge now" admin action, never from the background scheduler.

Only rows that are both past the cutoff AND already closed/historical are
ever eligible — a tool that's still checked out or a wire spool still
issued is live operational state, not a stale record, no matter how old
its start timestamp is.
"""
from datetime import datetime, timedelta

from app.extensions import db
from app.models import (
    ActivityEvent, ActivityFlag, IssuanceEvent, ToolCheckoutEvent, WireIssuanceEvent, AuditLogEntry,
)

MIN_RETENTION_DAYS = 30  # anything shorter is almost certainly a misconfiguration, not a deliberate policy


def purge_older_than(days: int) -> dict:
    """Deletes personal-data-bearing history rows older than `days`.
    Returns a dict of table -> rows deleted, for the audit log entry the
    caller writes and for the flash message shown back to the admin."""
    if days < MIN_RETENTION_DAYS:
        raise ValueError(f"retention window must be at least {MIN_RETENTION_DAYS} days, got {days}")

    cutoff = datetime.utcnow() - timedelta(days=days)
    counts = {}

    # Never purge an ActivityEvent that's part of a "wasn't me" flag review
    # (see auth.py's activity_review / ActivityFlag) — that's an open (or
    # resolved-but-still-referenced) integrity record, not routine history,
    # and ActivityFlag.activity_event_id is a non-nullable FK to it.
    flagged_event_ids = db.session.query(ActivityFlag.activity_event_id).distinct()
    counts["activity_events"] = ActivityEvent.query.filter(
        ActivityEvent.created_at < cutoff,
        ~ActivityEvent.id.in_(flagged_event_ids),
    ).delete(synchronize_session=False)

    counts["issuance_events"] = IssuanceEvent.query.filter(
        IssuanceEvent.created_at < cutoff,
    ).delete(synchronize_session=False)

    counts["tool_checkout_events"] = ToolCheckoutEvent.query.filter(
        ToolCheckoutEvent.checked_in_at.isnot(None),
        ToolCheckoutEvent.checked_in_at < cutoff,
    ).delete(synchronize_session=False)

    counts["wire_issuance_events"] = WireIssuanceEvent.query.filter(
        WireIssuanceEvent.resolved_at.isnot(None),
        WireIssuanceEvent.resolved_at < cutoff,
    ).delete(synchronize_session=False)

    counts["audit_log_entries"] = AuditLogEntry.query.filter(
        AuditLogEntry.created_at < cutoff,
    ).delete(synchronize_session=False)

    db.session.commit()
    return counts


def run_scheduled_purge_if_due(config: dict) -> dict | None:
    """Called once a day by run.py's background thread, same re-read-fresh
    pattern as backup.run_scheduled_local_backup_if_due — a retention
    period set from the Client Portal takes effect within a day, no kiosk
    restart needed. Returns the purge counts if a purge ran, else None."""
    days = config.get("activity_log_retention_days")
    if not days:
        return None
    try:
        days = int(days)
    except (TypeError, ValueError):
        return None
    if days < MIN_RETENTION_DAYS:
        return None
    return purge_older_than(days)
