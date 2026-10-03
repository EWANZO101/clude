from functools import wraps

from flask import abort
from flask_login import current_user, login_required


def require_permission(permission):
    """Route decorator: 403s unless the logged-in user holds `permission`
    (or is a super admin / Owner with '*')."""

    def decorator(view_func):
        @wraps(view_func)
        @login_required
        def wrapped(*args, **kwargs):
            if not current_user.has_permission(permission):
                abort(403)
            return view_func(*args, **kwargs)

        return wrapped

    return decorator
