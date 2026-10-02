from datetime import datetime, timezone
from urllib.parse import urlparse
from flask import Blueprint, render_template, redirect, url_for, flash, request, session
from flask_login import login_user, logout_user, login_required, current_user
from app.extensions import db
from app.models.user import User, Role
from app.models.audit_log import AuditLog, AuditAction

auth_bp = Blueprint("auth", __name__)


def _is_safe_next_url(target: str) -> bool:
    """Only allow redirecting to same-origin, relative paths after login.

    Without this check, an attacker could craft a link like
    /login?next=https://evil.example.com and, after a victim logs in,
    send them straight to a phishing site (open redirect).
    """
    if not target:
        return False
    parsed = urlparse(target)
    # A safe "next" target has no scheme/netloc (i.e. it's a relative path)
    return not parsed.scheme and not parsed.netloc and target.startswith("/")


def _log(action, user, detail="", request=None):
    ip = request.remote_addr if request else None
    entry = AuditLog(
        user_id=user.id if user else None,
        action=action,
        entity_type="user",
        entity_id=user.id if user else None,
        entity_name=user.username if user else None,
        detail=detail,
        ip_address=ip,
    )
    db.session.add(entry)
    db.session.commit()


@auth_bp.route("/", methods=["GET"])
def index():
    if current_user.is_authenticated:
        return redirect(url_for("dashboard.index"))
    return redirect(url_for("auth.login"))


@auth_bp.route("/login", methods=["GET", "POST"])
def login():
    if current_user.is_authenticated:
        return redirect(url_for("dashboard.index"))

    if request.method == "POST":
        username = request.form.get("username", "").strip()
        password = request.form.get("password", "")
        remember = request.form.get("remember") == "on"

        user = User.query.filter_by(username=username).first()

        if not user or not user.check_password(password):
            flash("Invalid username or password.", "danger")
            return render_template("auth/login.html")

        if not user.is_active:
            flash("Your account has been disabled. Contact an administrator.", "warning")
            return render_template("auth/login.html")

        login_user(user, remember=remember)
        user.last_login = datetime.now(timezone.utc)
        db.session.commit()

        _log(AuditAction.USER_LOGIN, user, f"Login from {request.remote_addr}", request)

        if user.force_password_change:
            flash("You must change your password before continuing.", "warning")
            return redirect(url_for("auth.change_password"))

        next_page = request.args.get("next")
        if next_page and _is_safe_next_url(next_page):
            return redirect(next_page)
        return redirect(url_for("dashboard.index"))

    return render_template("auth/login.html")


@auth_bp.route("/logout")
@login_required
def logout():
    _log(AuditAction.USER_LOGOUT, current_user, "Logged out", request)
    logout_user()
    flash("You have been logged out.", "info")
    return redirect(url_for("auth.login"))


@auth_bp.route("/change-password", methods=["GET", "POST"])
@login_required
def change_password():
    if request.method == "POST":
        current_pw = request.form.get("current_password", "")
        new_pw = request.form.get("new_password", "")
        confirm_pw = request.form.get("confirm_password", "")

        if not current_user.check_password(current_pw):
            flash("Current password is incorrect.", "danger")
            return render_template("auth/change_password.html")

        if len(new_pw) < 6:
            flash("New password must be at least 6 characters.", "danger")
            return render_template("auth/change_password.html")

        if new_pw != confirm_pw:
            flash("New passwords do not match.", "danger")
            return render_template("auth/change_password.html")

        current_user.set_password(new_pw)
        current_user.force_password_change = False
        db.session.commit()

        _log(AuditAction.USER_PASSWORD_CHANGED, current_user,
             "Password changed via web UI", request)
        flash("Password updated successfully.", "success")
        return redirect(url_for("dashboard.index"))

    return render_template("auth/change_password.html")
