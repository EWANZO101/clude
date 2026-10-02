from functools import wraps
from flask import abort, redirect, url_for
from flask_login import current_user
from app.models.user import Role


def admin_required(f):
    """Web route decorator — admins only."""
    @wraps(f)
    def decorated(*args, **kwargs):
        if not current_user.is_authenticated:
            return redirect(url_for("auth.login"))
        if not current_user.is_admin:
            abort(403)
        return f(*args, **kwargs)
    return decorated


def stock_or_admin_required(f):
    """Web route decorator — any active authenticated user."""
    @wraps(f)
    def decorated(*args, **kwargs):
        if not current_user.is_authenticated:
            return redirect(url_for("auth.login"))
        if current_user.role not in Role.ALL:
            abort(403)
        return f(*args, **kwargs)
    return decorated
