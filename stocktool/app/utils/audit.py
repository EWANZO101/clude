from flask import request
from flask_login import current_user
from app.extensions import db
from app.models.audit_log import AuditLog


def log_action(action: str, entity_type: str = None, entity_id: int = None,
               entity_name: str = None, detail: str = None, user=None,
               quantity_delta: int = None, device: str = None):
    """Write an audit log entry. Caller must db.session.commit() after.

    quantity_delta: signed stock change (e.g. -3 for a removal), if this
        action represents one. device: originating device name, e.g. a
        kiosk's name or "mobile" for a phone-relayed scan. Both are None
        for actions that don't apply (user CRUD, logins, etc).
    """
    actor = user or (current_user if current_user.is_authenticated else None)
    ip = None
    try:
        ip = request.remote_addr
    except RuntimeError:
        pass

    entry = AuditLog(
        user_id=actor.id if actor else None,
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
