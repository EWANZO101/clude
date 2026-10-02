import os
import shutil
from datetime import datetime, timedelta

from flask import Blueprint, render_template, redirect, url_for, flash, request, current_app
from flask_login import current_user
from itsdangerous import URLSafeTimedSerializer

from app.extensions import db
from app.models import User, Export, ExportStatus, ImportJob, AuditLog, Setting, Role
from app.admin.decorators import admin_required
from app.admin.forms import EditUserForm, SystemSettingsForm
from app.auth.routes import log_action

admin_bp = Blueprint("admin", __name__, url_prefix="/admin")


@admin_bp.before_request
@admin_required
def _guard():
    """Applies admin_required (which also implies auth) to every route in this blueprint."""
    pass


def _dir_size_bytes(path):
    total = 0
    if not os.path.isdir(path):
        return 0
    for root, _dirs, files in os.walk(path):
        for fname in files:
            try:
                total += os.path.getsize(os.path.join(root, fname))
            except OSError:
                continue
    return total


@admin_bp.route("/")
def overview():
    user_count = User.query.count()
    active_temp = User.query.filter_by(is_temporary=True).count()
    export_count = Export.query.count()
    running_exports = Export.query.filter_by(status=ExportStatus.RUNNING).count()
    import_count = ImportJob.query.count()

    since = datetime.utcnow() - timedelta(hours=24)
    active_sessions = User.query.filter(User.last_login_at >= since).count()

    exports_dir = current_app.config["EXPORTS_DIR"]
    exports_size = _dir_size_bytes(exports_dir)

    try:
        disk_total, disk_used, disk_free = shutil.disk_usage(exports_dir)
    except OSError:
        disk_total = disk_used = disk_free = 0

    recent_logs = AuditLog.query.order_by(AuditLog.created_at.desc()).limit(15).all()

    return render_template(
        "admin/overview.html",
        user_count=user_count,
        active_temp=active_temp,
        export_count=export_count,
        running_exports=running_exports,
        import_count=import_count,
        active_sessions=active_sessions,
        exports_size=exports_size,
        disk_total=disk_total,
        disk_used=disk_used,
        disk_free=disk_free,
        recent_logs=recent_logs,
    )


# ---- User management --------------------------------------------------

@admin_bp.route("/users")
def users():
    q = request.args.get("q", "").strip()
    query = User.query
    if q:
        query = query.filter(User.email.ilike(f"%{q}%"))
    user_list = query.order_by(User.created_at.desc()).limit(200).all()
    return render_template("admin/users.html", users=user_list, q=q)


@admin_bp.route("/users/<user_id>", methods=["GET", "POST"])
def user_detail(user_id):
    user = User.query.get_or_404(user_id)
    form = EditUserForm(obj=user)

    if form.validate_on_submit():
        if user.id == current_user.id and form.role.data != Role.ADMIN:
            flash("You can't demote your own account.", "warning")
            return redirect(url_for("admin.user_detail", user_id=user_id))

        user.role = form.role.data
        user.is_suspended = form.is_suspended.data
        db.session.commit()
        log_action(current_user.id, "admin_user_updated", detail=user_id)
        flash("User updated.", "success")
        return redirect(url_for("admin.user_detail", user_id=user_id))

    exports = user.exports.order_by(Export.created_at.desc()).limit(20).all()
    return render_template("admin/user_detail.html", user=user, form=form, exports=exports)


@admin_bp.route("/users/<user_id>/force-logout", methods=["POST"])
def force_logout(user_id):
    user = User.query.get_or_404(user_id)
    user.force_logout_at = datetime.utcnow()
    db.session.commit()
    log_action(current_user.id, "admin_force_logout", detail=user_id)
    flash(f"All sessions for {user.email} will be invalidated.", "info")
    return redirect(url_for("admin.user_detail", user_id=user_id))


@admin_bp.route("/users/<user_id>/reset-link", methods=["POST"])
def generate_reset_link(user_id):
    user = User.query.get_or_404(user_id)
    serializer = URLSafeTimedSerializer(current_app.config["SECRET_KEY"])
    token = serializer.dumps(user.email, salt="password-reset")
    reset_url = url_for("auth.reset_password", token=token, _external=True)
    log_action(current_user.id, "admin_reset_link_generated", detail=user_id)
    flash(f"Reset link for {user.email}: {reset_url}", "info")
    return redirect(url_for("admin.user_detail", user_id=user_id))


@admin_bp.route("/users/<user_id>/delete", methods=["POST"])
def delete_user(user_id):
    user = User.query.get_or_404(user_id)
    if user.id == current_user.id:
        flash("You can't delete your own account.", "danger")
        return redirect(url_for("admin.user_detail", user_id=user_id))

    for export in user.exports.all():
        if export.file_path and os.path.exists(export.file_path):
            os.remove(export.file_path)

    db.session.delete(user)
    db.session.commit()
    log_action(current_user.id, "admin_user_deleted", detail=user_id)
    flash("User deleted.", "info")
    return redirect(url_for("admin.users"))


# ---- Export management --------------------------------------------------

@admin_bp.route("/exports")
def exports():
    status_filter = request.args.get("status", "")
    query = Export.query
    if status_filter:
        query = query.filter_by(status=status_filter)
    export_list = query.order_by(Export.created_at.desc()).limit(200).all()
    return render_template("admin/exports.html", exports=export_list, status_filter=status_filter,
                            statuses=[ExportStatus.PENDING, ExportStatus.RUNNING,
                                      ExportStatus.COMPLETE, ExportStatus.FAILED, ExportStatus.EXPIRED])


@admin_bp.route("/exports/<export_id>/delete", methods=["POST"])
def delete_export(export_id):
    export = Export.query.get_or_404(export_id)
    if export.file_path and os.path.exists(export.file_path):
        os.remove(export.file_path)
    sidecar = f"{export.file_path}.sha256" if export.file_path else None
    if sidecar and os.path.exists(sidecar):
        os.remove(sidecar)
    db.session.delete(export)
    db.session.commit()
    log_action(current_user.id, "admin_export_deleted", detail=export_id)
    flash("Export deleted.", "info")
    return redirect(url_for("admin.exports"))


@admin_bp.route("/exports/cleanup-expired", methods=["POST"])
def cleanup_expired_exports():
    retention_days = int(Setting.get("export_retention_days", "30"))
    cutoff = datetime.utcnow() - timedelta(days=retention_days)

    stale = Export.query.filter(
        Export.status == ExportStatus.COMPLETE, Export.created_at < cutoff
    ).all()

    removed = 0
    for export in stale:
        if export.file_path and os.path.exists(export.file_path):
            os.remove(export.file_path)
        export.status = ExportStatus.EXPIRED
        removed += 1
    db.session.commit()
    log_action(current_user.id, "admin_cleanup_expired", detail=f"{removed} export(s)")
    flash(f"Marked {removed} export(s) expired and removed their files.", "success")
    return redirect(url_for("admin.exports"))


# ---- Import management --------------------------------------------------

@admin_bp.route("/imports")
def imports():
    import_list = ImportJob.query.order_by(ImportJob.created_at.desc()).limit(200).all()
    return render_template("admin/imports.html", imports=import_list)


# ---- Audit log --------------------------------------------------------

@admin_bp.route("/audit-logs")
def audit_logs():
    page = request.args.get("page", 1, type=int)
    pagination = AuditLog.query.order_by(AuditLog.created_at.desc()).paginate(
        page=page, per_page=50, error_out=False
    )
    return render_template("admin/audit_logs.html", pagination=pagination)


# ---- Settings --------------------------------------------------------

@admin_bp.route("/settings", methods=["GET", "POST"])
def settings():
    form = SystemSettingsForm()

    if form.validate_on_submit():
        Setting.set("export_retention_days", str(form.export_retention_days.data))
        Setting.set("temp_account_lifetime_hours", str(form.temp_account_lifetime_hours.data))
        Setting.set("cleanup_enabled", "true" if form.cleanup_enabled.data else "false")
        Setting.set("mail_server", form.mail_server.data or "")
        Setting.set("mail_from", form.mail_from.data or "")
        log_action(current_user.id, "admin_settings_updated")
        flash("Settings saved.", "success")
        return redirect(url_for("admin.settings"))

    if request.method == "GET":
        form.export_retention_days.data = int(Setting.get("export_retention_days", "30"))
        form.temp_account_lifetime_hours.data = int(Setting.get("temp_account_lifetime_hours", "12"))
        form.cleanup_enabled.data = Setting.get("cleanup_enabled", "true") == "true"
        form.mail_server.data = Setting.get("mail_server", "")
        form.mail_from.data = Setting.get("mail_from", "")

    return render_template("admin/settings.html", form=form)
