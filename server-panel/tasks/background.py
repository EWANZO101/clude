import traceback
import uuid
from datetime import datetime

from extensions import socketio
from database import db
from models.job import Job


class JobContext:
    """Passed into every installer/task callable so it can report progress."""

    def __init__(self, job_id, app):
        self.job_id = job_id
        self._app = app

    def _emit(self, job):
        socketio.emit("job_update", job.to_dict(), room=f"job-{self.job_id}", namespace="/jobs")
        socketio.emit("job_update", job.to_dict(), room="jobs-list", namespace="/jobs")

    def log(self, message):
        with self._app.app_context():
            job = db.session.get(Job, self.job_id)
            if not job:
                return
            timestamp = datetime.utcnow().strftime("%H:%M:%S")
            job.log_text = (job.log_text or "") + f"[{timestamp}] {message}\n"
            db.session.commit()
            self._emit(job)

    def set_progress(self, percent, message=None):
        with self._app.app_context():
            job = db.session.get(Job, self.job_id)
            if not job:
                return
            job.progress = max(0, min(100, int(percent)))
            db.session.commit()
            self._emit(job)
        if message:
            self.log(message)


def _run_job_thread(app, job_id, target_fn, *args, **kwargs):
    ctx = JobContext(job_id, app)

    with app.app_context():
        job = db.session.get(Job, job_id)
        job.status = "running"
        job.started_at = datetime.utcnow()
        db.session.commit()
        ctx._emit(job)

    try:
        target_fn(ctx, *args, **kwargs)
        with app.app_context():
            job = db.session.get(Job, job_id)
            job.status = "success"
            job.progress = 100
            job.finished_at = datetime.utcnow()
            db.session.commit()
            ctx._emit(job)
    except Exception as exc:  # noqa: BLE001 - job errors must never crash the emitter thread
        tb = traceback.format_exc()
        with app.app_context():
            job = db.session.get(Job, job_id)
            job.status = "failed"
            job.error = str(exc)
            job.log_text = (job.log_text or "") + f"\n[error] {exc}\n{tb}\n"
            job.finished_at = datetime.utcnow()
            db.session.commit()
            ctx._emit(job)


def start_job(app, name, target, target_fn, user_id=None, *args, **kwargs):
    """Create a Job row and run target_fn(ctx, *args, **kwargs) in a background thread.
    Returns the new job id immediately; the caller should redirect to the job's progress page."""
    job_id = uuid.uuid4().hex

    with app.app_context():
        job = Job(id=job_id, name=name, target=target, status="pending", user_id=user_id)
        db.session.add(job)
        db.session.commit()

    socketio.start_background_task(_run_job_thread, app, job_id, target_fn, *args, **kwargs)
    return job_id
