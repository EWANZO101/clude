from functools import wraps
from flask import g, redirect, url_for, abort


def login_required(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        if not g.get("current_user"):
            return redirect(url_for("auth.login"))
        return f(*args, **kwargs)
    return decorated


def admin_required(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        if not g.get("current_user"):
            return redirect(url_for("auth.login"))
        if not g.current_user["is_admin"]:
            abort(403)
        return f(*args, **kwargs)
    return decorated
