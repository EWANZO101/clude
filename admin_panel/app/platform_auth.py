from functools import wraps

from flask import abort
from flask_login import current_user


def platform_admin_required(view):
    """Gates OpsLab-internal routes (release uploads, etc.) — separate from
    any company's roles. A company owner is NOT automatically a platform
    admin."""
    @wraps(view)
    def wrapper(*args, **kwargs):
        if not current_user.is_authenticated:
            abort(401)
        # getattr, not a direct attribute access: current_user may be a
        # ClientUser (the separate Client Portal account type — see
        # models.py), which has no is_platform_admin concept at all.
        # confine_client_portal_sessions in app/__init__.py already keeps a
        # ClientUser from reaching here in practice; this is a defensive
        # fallback so a gap in that confinement 403s instead of 500ing.
        if not getattr(current_user, "is_platform_admin", False):
            abort(403)
        return view(*args, **kwargs)
    return wrapper
