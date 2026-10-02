from functools import wraps
from flask import redirect, url_for, flash, abort
from flask_login import current_user


def require_current_business(view):
    @wraps(view)
    def wrapped(*args, **kwargs):
        business = current_user.current_business()
        if business is None:
            flash("Create or select a business first.", "info")
            return redirect(url_for("businesses.list_businesses"))
        return view(business=business, *args, **kwargs)
    return wrapped


def require_permission(permission):
    def decorator(view):
        @wraps(view)
        def wrapped(business, *args, **kwargs):
            role = current_user.role_in(business)
            if role is None:
                abort(403)
            from app.models.business import ROLE_PERMISSIONS
            if permission not in ROLE_PERMISSIONS.get(role, set()):
                abort(403)
            return view(business=business, *args, **kwargs)
        return wrapped
    return decorator
