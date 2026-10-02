from functools import wraps

from flask import abort, session
from flask_login import current_user, logout_user


def admin_required(view_func):
    @wraps(view_func)
    def wrapped(*args, **kwargs):
        if not current_user.is_authenticated or not current_user.is_admin():
            abort(403)
        return view_func(*args, **kwargs)
    return wrapped


def enforce_force_logout():
    """Call on every request. Logs a user out if an admin force-logged them
    out after their current session began."""
    if not current_user.is_authenticated:
        return
    if not getattr(current_user, "force_logout_at", None):
        return

    authenticated_at = session.get("authenticated_at")
    if not authenticated_at:
        logout_user()
        return

    from datetime import datetime
    try:
        session_start = datetime.fromisoformat(authenticated_at)
    except ValueError:
        logout_user()
        return

    if current_user.force_logout_at > session_start:
        logout_user()
