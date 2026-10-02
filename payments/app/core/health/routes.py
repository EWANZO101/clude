import os
from datetime import datetime

from flask import Blueprint, render_template, current_app
from flask_login import login_required
from sqlalchemy import text

from app.extensions import db
from app.core.jobs.models import BackgroundJob, ScheduledJob

health_bp = Blueprint("health", __name__, url_prefix="/system-health", template_folder="../../templates/health")


@health_bp.route("/")
@login_required
def index():
    try:
        db.session.execute(text("SELECT 1"))
        db_status = "ok"
    except Exception:
        db_status = "error"

    failed_jobs = BackgroundJob.query.filter_by(status="failed").count()
    queued_jobs = BackgroundJob.query.filter_by(status="queued").count()
    scheduled = ScheduledJob.query.filter_by(enabled=True).count()

    storage_ok = os.path.isdir(current_app.config["UPLOAD_FOLDER"])

    backups = os.listdir(current_app.config["BACKUP_FOLDER"]) if os.path.isdir(current_app.config["BACKUP_FOLDER"]) else []
    last_backup = max(backups, default=None)

    from app.core.modules.models import ModuleRecord
    modules = ModuleRecord.query.all()

    return render_template(
        "health/index.html",
        db_status=db_status, failed_jobs=failed_jobs, queued_jobs=queued_jobs,
        scheduled=scheduled, storage_ok=storage_ok, last_backup=last_backup,
        modules=modules, now=datetime.utcnow(), app_version="0.5.0-dev",
    )
