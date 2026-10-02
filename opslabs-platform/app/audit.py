import json

from .extensions import db
from .models import AuditLog


def log(action, actor_user_id=None, target_type=None, target_id=None, **details):
    """Records an admin-mutating action. Doesn't commit — call sites already commit
    their own change right after, so this just rides along in the same transaction
    (one commit, not two, and if the main change rolls back so does the log entry)."""
    db.session.add(AuditLog(
        actor_user_id=actor_user_id, action=action,
        target_type=target_type, target_id=target_id,
        details=json.dumps(details, default=str),
    ))
