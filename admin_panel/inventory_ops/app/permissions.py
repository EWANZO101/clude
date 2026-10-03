from functools import wraps

from flask import redirect, url_for, flash, abort
from flask_login import current_user

from app.models import Settings


def current_actor() -> str:
    """Name to attribute an action to — the logged-in user's username when
    auth is on, or the shared pseudo-actor when it's off (see
    Settings.auth_enabled)."""
    if current_user.is_authenticated:
        return current_user.username
    return "shared"


def require_login_if_enabled(view):
    """Gates a route on being logged in, but only when Settings.auth_enabled
    is True. With auth off there's no identity concept at all, so every
    request passes through — same philosophy kiosk_app documents for its
    own badge-optional default, just taken one step further since this app
    can turn accounts off entirely."""

    @wraps(view)
    def wrapped(*args, **kwargs):
        if Settings.get().auth_enabled and not current_user.is_authenticated:
            flash("Please log in to continue.", "warning")
            return redirect(url_for("auth.login", next=None))
        return view(*args, **kwargs)

    return wrapped


def require_admin(view):
    """Admin-only gate — but only enforced while auth is actually on. This
    is deliberate, not an oversight: it's what lets someone reach the
    Settings page and turn auth back ON after switching it off, since
    there's no login screen to gate that page while auth is disabled."""

    @wraps(view)
    def wrapped(*args, **kwargs):
        settings = Settings.get()
        if settings.auth_enabled:
            if not current_user.is_authenticated:
                flash("Please log in to continue.", "warning")
                return redirect(url_for("auth.login"))
            if current_user.role != "admin":
                abort(403)
        return view(*args, **kwargs)

    return wrapped
