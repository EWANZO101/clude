"""Append-only audit trail for admin/security-relevant actions. Call
log_audit() right alongside the db.session.commit() for the action it's
recording - never batched, never best-effort-dropped, since the whole
point is a trustworthy record of what happened."""

from flask_login import current_user

from .extensions import db
from .models import AuditLog


def log_audit(action, detail=""):
    entry = AuditLog(
        actor_id=current_user.id if current_user.is_authenticated else None,
        actor_username=current_user.username if current_user.is_authenticated else "system",
        action=action[:64],
        detail=detail[:500],
    )
    db.session.add(entry)
