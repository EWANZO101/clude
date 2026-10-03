from flask import Blueprint, render_template, redirect, url_for, flash, current_app
from flask_login import current_user

from database import db
from models.job import Job
from modules.system.forms import RootPasswordForm, CreateSystemUserForm, ResetUserPasswordForm
from services import system_admin_service as sysadmin
from utils.permissions import require_permission

system_bp = Blueprint("system", __name__, template_folder="templates")


@system_bp.route("/system")
@require_permission("system.admin")
def index():
    try:
        upgradable = sysadmin.count_upgradable()
    except sysadmin.SystemAdminError:
        upgradable = None

    recent_jobs = (
        Job.query.filter(Job.target.in_(["system:apt-update", "system:apt-upgrade"]))
        .order_by(Job.created_at.desc()).limit(10).all()
    )

    try:
        users = sysadmin.list_system_users()
        users_error = None
    except sysadmin.SystemAdminError as exc:
        users = []
        users_error = str(exc)

    return render_template(
        "system_index.html",
        upgradable=upgradable,
        recent_jobs=recent_jobs,
        users=users,
        users_error=users_error,
        root_form=RootPasswordForm(),
        create_user_form=CreateSystemUserForm(),
        reset_pw_form=ResetUserPasswordForm(),
    )


def _run_apt(ctx, mode):
    if mode == "update":
        sysadmin.apt_update(ctx)
    else:
        sysadmin.apt_upgrade(ctx)


@system_bp.route("/system/apt/update", methods=["POST"])
@require_permission("system.admin")
def apt_update():
    from tasks.background import start_job
    job_id = start_job(
        app=current_app._get_current_object(),
        name="apt-get update",
        target="system:apt-update",
        target_fn=_run_apt,
        user_id=current_user.id,
        mode="update",
    )
    return redirect(url_for("system.job_page", job_id=job_id))


@system_bp.route("/system/apt/upgrade", methods=["POST"])
@require_permission("system.admin")
def apt_upgrade():
    from tasks.background import start_job
    job_id = start_job(
        app=current_app._get_current_object(),
        name="apt-get upgrade",
        target="system:apt-upgrade",
        target_fn=_run_apt,
        user_id=current_user.id,
        mode="upgrade",
    )
    return redirect(url_for("system.job_page", job_id=job_id))


@system_bp.route("/system/job/<job_id>")
@require_permission("system.admin")
def job_page(job_id):
    job = db.session.get(Job, job_id)
    if job is None:
        flash("Job not found.", "error")
        return redirect(url_for("system.index"))
    return render_template("job_progress.html", job=job)


@system_bp.route("/system/root-password", methods=["POST"])
@require_permission("system.admin")
def reset_root_password():
    form = RootPasswordForm()
    if form.validate_on_submit():
        try:
            sysadmin.reset_root_password(form.password.data)
            current_app.logger.warning(
                "Root password was reset via the panel by user '%s' (id=%s).",
                current_user.username, current_user.id,
            )
            flash("Root password updated. This change is recorded in the system auth log.", "success")
        except sysadmin.SystemAdminError as exc:
            flash(str(exc), "error")
    else:
        flash("Passwords must match and be at least 8 characters.", "error")
    return redirect(url_for("system.index"))


@system_bp.route("/system/users/create", methods=["POST"])
@require_permission("system.admin")
def create_user():
    form = CreateSystemUserForm()
    if form.validate_on_submit():
        try:
            sysadmin.create_system_user(
                form.username.data.strip(),
                form.password.data,
                shell=form.shell.data,
                sudo=form.sudo.data,
                ssh_public_key=form.ssh_public_key.data,
            )
            current_app.logger.warning(
                "Linux user '%s' created via the panel by '%s' (sudo=%s).",
                form.username.data.strip(), current_user.username, form.sudo.data,
            )
            flash(f"Created Linux user '{form.username.data.strip()}'.", "success")
        except sysadmin.SystemAdminError as exc:
            flash(str(exc), "error")
    else:
        for field_errors in form.errors.values():
            for err in field_errors:
                flash(err, "error")
    return redirect(url_for("system.index"))


@system_bp.route("/system/users/<username>/delete", methods=["POST"])
@require_permission("system.admin")
def delete_user(username):
    try:
        sysadmin.delete_system_user(username)
        current_app.logger.warning(
            "Linux user '%s' deleted via the panel by '%s'.", username, current_user.username,
        )
        flash(f"Deleted Linux user '{username}'.", "success")
    except sysadmin.SystemAdminError as exc:
        flash(str(exc), "error")
    return redirect(url_for("system.index"))


@system_bp.route("/system/users/<username>/sudo", methods=["POST"])
@require_permission("system.admin")
def toggle_sudo(username):
    from flask import request
    enabled = request.form.get("enabled") == "1"
    try:
        sysadmin.set_sudo(username, enabled)
        current_app.logger.warning(
            "Sudo access for Linux user '%s' set to %s via the panel by '%s'.",
            username, enabled, current_user.username,
        )
        flash(f"Sudo {'granted to' if enabled else 'removed from'} '{username}'.", "success")
    except sysadmin.SystemAdminError as exc:
        flash(str(exc), "error")
    return redirect(url_for("system.index"))


@system_bp.route("/system/users/<username>/reset-password", methods=["POST"])
@require_permission("system.admin")
def reset_user_password(username):
    form = ResetUserPasswordForm()
    if form.validate_on_submit():
        try:
            sysadmin.reset_user_password(username, form.password.data)
            current_app.logger.warning(
                "Password reset for Linux user '%s' via the panel by '%s'.",
                username, current_user.username,
            )
            flash(f"Password updated for '{username}'.", "success")
        except sysadmin.SystemAdminError as exc:
            flash(str(exc), "error")
    else:
        flash("Password must be at least 8 characters.", "error")
    return redirect(url_for("system.index"))
