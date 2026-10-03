from flask import Blueprint, render_template, redirect, url_for, flash, current_app
from flask_login import current_user
from flask_socketio import join_room, leave_room

from extensions import socketio
from database import db
from models.job import Job
from modules.installers.base import InstallerError
from modules.installers import registry
from utils.permissions import require_permission

installers_bp = Blueprint("installers", __name__, template_folder="templates")


@installers_bp.route("/installers")
@require_permission("installers.run")
def index():
    recent_jobs = Job.query.order_by(Job.created_at.desc()).limit(20).all()
    return render_template("installers_index.html", installers=registry.all_installers(), jobs=recent_jobs)


def _run_installer_lifecycle(ctx, installer_key, mode):
    installer = registry.get(installer_key)
    if installer is None:
        raise InstallerError(f"No installer registered for '{installer_key}'.")

    if mode == "repair":
        installer.repair(ctx)
    else:
        installer.run_full_install(ctx)


@installers_bp.route("/installers/<key>/run", methods=["POST"])
@require_permission("installers.run")
def run(key):
    installer = registry.get(key)
    if installer is None:
        flash(f"No installer found for '{key}'.", "error")
        return redirect(url_for("installers.index"))

    from tasks.background import start_job

    job_id = start_job(
        app=current_app._get_current_object(),
        name=f"Install {installer.name}",
        target=f"installer:{key}",
        target_fn=_run_installer_lifecycle,
        user_id=current_user.id,
        installer_key=key,
        mode="install",
    )
    return redirect(url_for("installers.job_page", job_id=job_id))


@installers_bp.route("/installers/<key>/repair", methods=["POST"])
@require_permission("installers.run")
def repair(key):
    installer = registry.get(key)
    if installer is None:
        flash(f"No installer found for '{key}'.", "error")
        return redirect(url_for("installers.index"))

    from tasks.background import start_job

    job_id = start_job(
        app=current_app._get_current_object(),
        name=f"Repair {installer.name}",
        target=f"installer:{key}",
        target_fn=_run_installer_lifecycle,
        user_id=current_user.id,
        installer_key=key,
        mode="repair",
    )
    return redirect(url_for("installers.job_page", job_id=job_id))


@installers_bp.route("/installers/job/<job_id>")
@require_permission("installers.run")
def job_page(job_id):
    job = db.session.get(Job, job_id)
    if job is None:
        flash("Job not found.", "error")
        return redirect(url_for("installers.index"))
    return render_template("job_progress.html", job=job)


@socketio.on("subscribe", namespace="/jobs")
def handle_job_subscribe(data):
    job_id = (data or {}).get("job_id")
    if job_id:
        join_room(f"job-{job_id}")
    else:
        join_room("jobs-list")


@socketio.on("unsubscribe", namespace="/jobs")
def handle_job_unsubscribe(data):
    job_id = (data or {}).get("job_id")
    if job_id:
        leave_room(f"job-{job_id}")
    else:
        leave_room("jobs-list")
