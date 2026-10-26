from datetime import datetime
from urllib.parse import urlparse

from flask import Blueprint, g, redirect, render_template, request, url_for
from flask_login import current_user, login_required, login_user, logout_user

from .audit import log_audit
from .extensions import db
from .models import Settings, User

auth_bp = Blueprint("auth", __name__)


def _safe_next(value):
    """Only ever redirect to a same-site relative path - `next` is
    attacker-controlled (it's a query string a victim could be sent),
    so without this check it's an open-redirect vector: a link like
    /login?next=https://evil.example.com would bounce a logged-in victim
    straight to an attacker's site right after they authenticate."""
    if not value:
        return None
    parsed = urlparse(value)
    if parsed.scheme or parsed.netloc:
        return None
    if not value.startswith("/") or value.startswith("//"):
        return None
    return value


@auth_bp.route("/login", methods=["GET", "POST"])
def login():
    next_target = _safe_next(request.form.get("next") or request.args.get("next"))

    if current_user.is_authenticated:
        return redirect(next_target or url_for("views.dashboard"))

    error = None
    if request.method == "POST":
        username = (request.form.get("username") or "").strip()
        password = request.form.get("password") or ""
        user = User.query.filter_by(username=username).first()

        if user is None or not user.check_password(password):
            error = "Invalid username or password."
        elif not user.is_active_account:
            error = "This account is awaiting admin approval."
        else:
            user.last_login_at = datetime.utcnow()
            db.session.commit()
            login_user(user)
            return redirect(next_target or url_for("views.dashboard"))

    return render_template("login.html", error=error, next=next_target or "")


@auth_bp.route("/signup", methods=["GET", "POST"])
def signup():
    if current_user.is_authenticated:
        return redirect(url_for("views.dashboard"))

    # g.tenant here is only ever host-based (subdomain/custom domain) - there's no logged-in user yet for
    # tenant_resolve.py's other fallback to apply to, which is exactly right: an officer joining a specific
    # community's own existing account is only meaningful from that community's own URL.
    community_id = g.tenant.id if g.tenant else None
    settings = Settings.get(community_id=community_id)
    error = None
    pending = False

    if request.method == "POST":
        username = (request.form.get("username") or "").strip()
        password = request.form.get("password") or ""
        confirm = request.form.get("confirm") or ""
        invite_code = request.form.get("invite_code") or ""

        if settings.signup_mode == "invite" and (not settings.invite_code or invite_code != settings.invite_code):
            error = "Invalid invite code."
        elif len(username) < 3:
            error = "Username must be at least 3 characters."
        elif len(password) < 8:
            error = "Password must be at least 8 characters."
        elif password != confirm:
            error = "Passwords don't match."
        elif User.query.filter_by(username=username).first() is not None:
            error = "That username is taken."

        if error is None:
            user = User(
                username=username,
                role="officer",
                is_active_account=(settings.signup_mode != "approval"),
                community_id=community_id,
            )
            user.set_password(password)
            db.session.add(user)
            db.session.commit()

            if settings.signup_mode == "approval":
                pending = True
            else:
                login_user(user)
                return redirect(url_for("views.dashboard"))

    return render_template("signup.html", settings=settings, error=error, pending=pending)


@auth_bp.route("/logout", methods=["POST"])
@login_required
def logout():
    logout_user()
    return redirect(url_for("site.welcome"))


@auth_bp.route("/account", methods=["GET", "POST"])
@login_required
def account():
    error = None
    saved = False
    if request.method == "POST":
        current_password = request.form.get("current_password") or ""
        new_password = request.form.get("new_password") or ""
        confirm = request.form.get("confirm") or ""

        if not current_user.check_password(current_password):
            error = "Current password is incorrect."
        elif len(new_password) < 8:
            error = "New password must be at least 8 characters."
        elif new_password != confirm:
            error = "Passwords don't match."
        else:
            current_user.set_password(new_password)
            log_audit("account.password_change", f"{current_user.username} changed their own password")
            db.session.commit()
            saved = True

    return render_template("account.html", error=error, saved=saved)
