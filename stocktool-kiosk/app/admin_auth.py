"""
Admin Panel auth: a thin permission layer on top of app.auth's existing
session store, not a second login system. Logging into /ui/admin uses
the same LocalUser accounts and the same Bearer-token session mechanism
as the kiosk screen (app.auth.create_session/login_required) -- this
module just adds "and does this role actually have Admin Panel access"
on top of "is this a valid session".

super_admin is a hardcoded bypass everywhere here, on purpose: it must
never be possible to lock every account out of the Admin Panel just by
misconfiguring (or emptying) an AdminRole row.
"""
from functools import wraps

from flask import g, jsonify

from app.auth import login_required
from app.admin_models import AdminRole, PERMISSIONS


def role_has_panel_access(role_name: str) -> bool:
    if role_name == "super_admin":
        return True
    role = AdminRole.query.filter_by(name=role_name).first()
    return bool(role and role.permissions)


def role_has_permission(role_name: str, perm_key: str) -> bool:
    if role_name == "super_admin":
        return True
    role = AdminRole.query.filter_by(name=role_name).first()
    return bool(role and perm_key in role.permissions)


def admin_login_required(fn):
    """Valid session AND that account's role has *some* Admin Panel
    access. Use for read-only endpoints anyone let into the panel should
    be able to see (dashboard counts, the sidebar itself, etc)."""
    @wraps(fn)
    @login_required
    def wrapper(*args, **kwargs):
        if not role_has_panel_access(g.session["role"]):
            return jsonify({"error": "Your role doesn't have Admin Panel access."}), 403
        return fn(*args, **kwargs)
    return wrapper


def require_permission(perm_key: str):
    """Valid session AND that specific permission. Use for anything that
    creates/edits/deletes admin-panel-managed data."""
    if perm_key not in PERMISSIONS:
        raise ValueError(f"Unknown admin panel permission: {perm_key!r}")

    def decorator(fn):
        @wraps(fn)
        @login_required
        def wrapper(*args, **kwargs):
            role_name = g.session["role"]
            if not role_has_permission(role_name, perm_key):
                return jsonify({"error": "You don't have permission to do that."}), 403
            return fn(*args, **kwargs)
        return wrapper
    return decorator
