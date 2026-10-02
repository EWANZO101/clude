from flask import request
from app.extensions import db
from app.models.audit_log import AuditLog


def log_action(action: str, entity_type: str = None, entity_id: int = None,
               entity_name: str = None, detail: str = None, user=None,
               quantity_delta: int = None, device: str = None):
    """Write an audit log entry. Caller must db.session.commit() after.

    `user` should be the acting User object (or None for system actions —
    there's no session-based "current user" here since this app has no
    cookie-based login; every caller resolves the user themselves, usually
    from the validated JWT identity).
    """
    ip = None
    try:
        ip = request.remote_addr
    except RuntimeError:
        pass

    entry = AuditLog(
        user_id=user.id if user else None,
        action=action,
        entity_type=entity_type,
        entity_id=entity_id,
        entity_name=entity_name,
        detail=detail,
        ip_address=ip,
        quantity_delta=quantity_delta,
        device=device,
    )
    db.session.add(entry)
