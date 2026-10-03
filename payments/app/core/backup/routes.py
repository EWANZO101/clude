from flask import Blueprint, render_template, redirect, url_for, flash, send_file, request
from flask_login import login_required

from app.core.audit.service import log_action
from app.core.backup import service

backup_bp = Blueprint("backup", __name__, url_prefix="/backups", template_folder="../../templates/backup")


@backup_bp.route("/")
@login_required
def index():
    from flask_login import current_user
    from app.core.jobs.models import ScheduledJob
    backups = service.list_backups()
    sched = ScheduledJob.query.filter_by(job_type="backup.create").first()
    return render_template("backup/index.html", backups=backups, db_backend=service.backend(),
                            scheduled_enabled=bool(sched and sched.enabled))


@backup_bp.route("/create", methods=["POST"])
@login_required
def create():
    from flask_login import current_user
    record = service.create_backup(source="manual")
    if record.status == "completed":
        log_action(current_user, "backup.created", target_type="backup", target_id=record.id)
        flash("Backup created.", "success")
    else:
        flash(f"Backup failed: {record.error}", "error")
    return redirect(url_for("backup.index"))


@backup_bp.route("/<int:backup_id>/download")
@login_required
def download(backup_id):
    from app.core.backup.models import Backup
    record = Backup.query.get_or_404(backup_id)
    return send_file(service.backup_path(record), as_attachment=True, download_name=record.filename)


@backup_bp.route("/<int:backup_id>/restore", methods=["POST"])
@login_required
def restore(backup_id):
    from flask_login import current_user
    from app.core.backup.models import Backup
    record = Backup.query.get_or_404(backup_id)
    try:
        restored_path = service.restore_backup(record)
        log_action(current_user, "backup.restore_prepared", target_type="backup", target_id=record.id)
        backend = service.backend()
        if backend == "sqlite":
            flash(
                f"Database extracted to {restored_path}. To finish restoring: stop the app, "
                f"replace app.db with that file, then start the app again.",
                "success",
            )
        else:
            tool = "mysql" if backend == "mysql" else "psql"
            flash(
                f"SQL dump extracted to {restored_path}. To finish restoring, run it against your "
                f"database yourself, e.g.: {tool} < {restored_path} (this isn't run automatically — "
                f"restoring over a live database from inside a web request is too risky to do unsupervised).",
                "success",
            )
    except Exception as e:
        flash(f"Restore failed: {e}", "error")
    return redirect(url_for("backup.index"))


@backup_bp.route("/<int:backup_id>/delete", methods=["POST"])
@login_required
def delete(backup_id):
    from flask_login import current_user
    from app.core.backup.models import Backup
    record = Backup.query.get_or_404(backup_id)
    service.delete_backup(record)
    log_action(current_user, "backup.deleted", target_type="backup", target_id=backup_id)
    flash("Backup deleted.", "success")
    return redirect(url_for("backup.index"))


@backup_bp.route("/schedule", methods=["POST"])
@login_required
def schedule():
    """Enables/disables a daily scheduled backup job."""
    from app.extensions import db
    from app.core.jobs.models import ScheduledJob
    from datetime import datetime, timedelta

    enabled = request.form.get("enabled") == "on"
    sched = ScheduledJob.query.filter_by(job_type="backup.create").first()
    if not sched:
        sched = ScheduledJob(job_type="backup.create", interval_seconds=86400,
                              next_run_at=datetime.utcnow() + timedelta(seconds=86400))
        db.session.add(sched)
    sched.enabled = enabled
    db.session.commit()
    flash("Scheduled backups enabled." if enabled else "Scheduled backups disabled.", "success")
    return redirect(url_for("backup.index"))
