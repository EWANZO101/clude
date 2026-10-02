from flask import request
from app.extensions import db
from app.core.audit.models import AuditLog


def log_action(user, action, target_type=None, target_id=None, details=None):
    try:
        ip = request.headers.get("X-Forwarded-For", request.remote_addr) if request else None
    except RuntimeError:
        ip = None
    db.session.add(AuditLog(
        user_id=user.id if user else None, action=action, target_type=target_type,
        target_id=str(target_id) if target_id is not None else None, details=details, ip_address=ip,
    ))
    db.session.commit()
