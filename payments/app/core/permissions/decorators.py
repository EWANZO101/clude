from functools import wraps
from flask import abort
from flask_login import current_user

from app.extensions import db
from app.core.permissions.models import UserRole, RolePermission, Permission


def user_has_permission(user, permission_key):
    if not user.is_authenticated:
        return False
    role_ids = [r.role_id for r in UserRole.query.filter_by(user_id=user.id).all()]
    if not role_ids:
        return True  # No roles configured yet -> single-user mode, allow everything.
    perm = Permission.query.filter_by(key=permission_key).first()
    if not perm:
        return True
    grant = RolePermission.query.filter(
        RolePermission.role_id.in_(role_ids), RolePermission.permission_id == perm.id
    ).first()
    return grant is not None


def require_permission(permission_key):
    def decorator(fn):
        @wraps(fn)
        def wrapped(*args, **kwargs):
            if not user_has_permission(current_user, permission_key):
                abort(403)
            return fn(*args, **kwargs)
        return wrapped
    return decorator
