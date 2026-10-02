from functools import wraps

from flask import Blueprint, render_template, redirect, url_for, flash, request, abort
from flask_login import login_required, current_user

from app.extensions import db
from app.models import User, Motorcycle, AppSetting, ApiLog
from app.admin.forms import (
    AdminCreateUserForm, AdminResetPasswordForm, MOTSettingsForm, AppSettingsForm
)

admin_bp = Blueprint("admin", __name__, url_prefix="/admin")


def admin_required(view):
    @wraps(view)
    def wrapped(*args, **kwargs):
        if not current_user.is_authenticated or not current_user.is_admin:
            abort(403)
        return view(*args, **kwargs)
    return wrapped


@admin_bp.route("/")
@login_required
@admin_required
def dashboard():
    user_count = User.query.count()
    moto_count = Motorcycle.query.count()
    recent_errors = ApiLog.query.filter_by(status="error").order_by(ApiLog.created_at.desc()).limit(10).all()
    return render_template(
        "admin/dashboard.html", user_count=user_count, moto_count=moto_count, recent_errors=recent_errors
    )


# ---------- Users ----------

@admin_bp.route("/users")
@login_required
@admin_required
def users():
    all_users = User.query.order_by(User.created_at.desc()).all()
    return render_template("admin/users.html", users=all_users)


@admin_bp.route("/users/new", methods=["GET", "POST"])
@login_required
@admin_required
def user_new():
    form = AdminCreateUserForm()
    if form.validate_on_submit():
        if User.query.filter_by(username=form.username.data.strip()).first():
            flash("That username is already taken.", "error")
        else:
            u = User(username=form.username.data.strip(), is_admin=form.is_admin.data)
            u.set_password(form.password.data)
            db.session.add(u)
            db.session.commit()
            flash(f"User '{u.username}' created.", "success")
            return redirect(url_for("admin.users"))
    return render_template("admin/user_form.html", form=form)


@admin_bp.route("/users/<user_id>/reset-password", methods=["GET", "POST"])
@login_required
@admin_required
def user_reset_password(user_id):
    u = User.query.get_or_404(user_id)
    form = AdminResetPasswordForm()
    if form.validate_on_submit():
        u.set_password(form.new_password.data)
        db.session.commit()
        flash(f"Password reset for '{u.username}'.", "success")
        return redirect(url_for("admin.users"))
    return render_template("admin/user_reset_password.html", form=form, u=u)


@admin_bp.route("/users/<user_id>/toggle-disabled", methods=["POST"])
@login_required
@admin_required
def user_toggle_disabled(user_id):
    u = User.query.get_or_404(user_id)
    if u.id == current_user.id:
        flash("You cannot disable your own account.", "error")
        return redirect(url_for("admin.users"))
    u.is_disabled = not u.is_disabled
    db.session.commit()
    flash(f"'{u.username}' is now {'disabled' if u.is_disabled else 'enabled'}.", "info")
    return redirect(url_for("admin.users"))


@admin_bp.route("/users/<user_id>/toggle-admin", methods=["POST"])
@login_required
@admin_required
def user_toggle_admin(user_id):
    u = User.query.get_or_404(user_id)
    if u.id == current_user.id:
        flash("You cannot change your own admin status.", "error")
        return redirect(url_for("admin.users"))
    u.is_admin = not u.is_admin
    db.session.commit()
    return redirect(url_for("admin.users"))


@admin_bp.route("/users/<user_id>/delete", methods=["POST"])
@login_required
@admin_required
def user_delete(user_id):
    u = User.query.get_or_404(user_id)
    if u.id == current_user.id:
        flash("You cannot delete your own account.", "error")
        return redirect(url_for("admin.users"))
    db.session.delete(u)
    db.session.commit()
    flash(f"User '{u.username}' deleted.", "info")
    return redirect(url_for("admin.users"))


# ---------- Motorcycles (support view) ----------

@admin_bp.route("/motorcycles")
@login_required
@admin_required
def motorcycles():
    all_motos = Motorcycle.query.order_by(Motorcycle.created_at.desc()).all()
    return render_template("admin/motorcycles.html", motorcycles=all_motos)


# ---------- MOT API settings ----------

@admin_bp.route("/settings/mot", methods=["GET", "POST"])
@login_required
@admin_required
def mot_settings():
    form = MOTSettingsForm()
    if form.validate_on_submit():
        AppSetting.set("dvsa_api_key", form.dvsa_api_key.data, is_secret=True)
        AppSetting.set("dvsa_client_id", form.dvsa_client_id.data, is_secret=True)
        AppSetting.set("dvsa_client_secret", form.dvsa_client_secret.data, is_secret=True)
        AppSetting.set("dvsa_token_url", form.dvsa_token_url.data)
        AppSetting.set("dvsa_scope_url", form.dvsa_scope_url.data)
        AppSetting.set("dvsa_api_base", form.dvsa_api_base.data)
        flash("MOT API settings saved.", "success")
        return redirect(url_for("admin.mot_settings"))
    if request.method == "GET":
        form.dvsa_api_key.data = AppSetting.get("dvsa_api_key")
        form.dvsa_client_id.data = AppSetting.get("dvsa_client_id")
        form.dvsa_client_secret.data = AppSetting.get("dvsa_client_secret")
        form.dvsa_token_url.data = AppSetting.get("dvsa_token_url")
        form.dvsa_scope_url.data = AppSetting.get("dvsa_scope_url")
        form.dvsa_api_base.data = AppSetting.get(
            "dvsa_api_base", "https://history.mot.api.gov.uk/v1/trade/vehicles/registration"
        )
    return render_template("admin/mot_settings.html", form=form)


@admin_bp.route("/settings/app", methods=["GET", "POST"])
@login_required
@admin_required
def app_settings():
    form = AppSettingsForm()
    if form.validate_on_submit():
        AppSetting.set("site_name", form.site_name.data)
        AppSetting.set("support_email", form.support_email.data)
        flash("Application settings saved.", "success")
        return redirect(url_for("admin.app_settings"))
    if request.method == "GET":
        form.site_name.data = AppSetting.get("site_name", "Moto Service History")
        form.support_email.data = AppSetting.get("support_email")
    return render_template("admin/app_settings.html", form=form)


@admin_bp.route("/logs")
@login_required
@admin_required
def logs():
    all_logs = ApiLog.query.order_by(ApiLog.created_at.desc()).limit(200).all()
    return render_template("admin/logs.html", logs=all_logs)
