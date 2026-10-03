from flask import Blueprint, render_template, redirect, url_for, request, flash
from flask_login import current_user

from app.extensions import db
from app.models import Settings, LocalUser
from app.permissions import require_admin, current_actor

bp = Blueprint("settings", __name__, url_prefix="/settings")


@bp.route("/")
@require_admin
def index():
    settings = Settings.get()
    users = LocalUser.query.order_by(LocalUser.username).all() if settings.auth_enabled else []
    return render_template("settings/index.html", settings=settings, users=users)


@bp.route("/toggles", methods=["POST"])
@require_admin
def update_toggles():
    settings = Settings.get()
    was_auth_enabled = settings.auth_enabled
    settings.tenant_name = request.form.get("tenant_name", "").strip() or settings.tenant_name
    settings.auth_enabled = request.form.get("auth_enabled") == "on"
    settings.signup_enabled = request.form.get("signup_enabled") == "on"
    settings.barcode_enabled = request.form.get("barcode_enabled") == "on"

    # Turning auth on for the first time with no accounts yet would lock
    # everyone out (no login exists to create one) — bounce to signup
    # instead of leaving them stuck on a login screen with nowhere to go.
    needs_first_account = settings.auth_enabled and not was_auth_enabled and LocalUser.query.count() == 0

    db.session.commit()
    flash("Settings updated.", "success")
    if needs_first_account:
        flash("Login is now required — create the first account below.", "warning")
        return redirect(url_for("auth.signup"))
    return redirect(url_for("settings.index"))


@bp.route("/users/add", methods=["POST"])
@require_admin
def add_user():
    username = request.form.get("username", "").strip()
    password = request.form.get("password", "")
    role = request.form.get("role", "staff")
    if role not in ("admin", "staff"):
        role = "staff"
    if not username or not password:
        flash("Username and password are required.", "danger")
        return redirect(url_for("settings.index"))
    if LocalUser.query.filter_by(username=username).first() is not None:
        flash(f"Username '{username}' is already taken.", "danger")
        return redirect(url_for("settings.index"))
    user = LocalUser(username=username, role=role)
    user.set_password(password)
    db.session.add(user)
    db.session.commit()
    flash(f"User '{username}' created.", "success")
    return redirect(url_for("settings.index"))


@bp.route("/users/<int:user_id>/toggle-active", methods=["POST"])
@require_admin
def toggle_user_active(user_id):
    user = LocalUser.query.get_or_404(user_id)
    if current_user.is_authenticated and user.id == current_user.id:
        flash("You can't deactivate your own account.", "danger")
        return redirect(url_for("settings.index"))
    user.is_active = not user.is_active
    db.session.commit()
    flash(f"'{user.username}' is now {'active' if user.is_active else 'inactive'}.", "success")
    return redirect(url_for("settings.index"))


@bp.route("/users/<int:user_id>/reset-password", methods=["POST"])
@require_admin
def reset_user_password(user_id):
    user = LocalUser.query.get_or_404(user_id)
    password = request.form.get("password", "")
    if not password:
        flash("A new password is required.", "danger")
        return redirect(url_for("settings.index"))
    user.set_password(password)
    db.session.commit()
    flash(f"Password reset for '{user.username}'.", "success")
    return redirect(url_for("settings.index"))
