import json
import logging
from datetime import datetime, timedelta

from app.extensions import db
from app.core.jobs.models import BackgroundJob, ScheduledJob

logger = logging.getLogger(__name__)

_handlers = {}


def register_job(job_type):
    def decorator(fn):
        _handlers[job_type] = fn
        return fn
    return decorator


def enqueue(job_type, module_id=None, user_id=None, **payload):
    job = BackgroundJob(job_type=job_type, module_id=module_id, user_id=user_id,
                         payload_json=json.dumps(payload, default=str))
    db.session.add(job)
    db.session.commit()
    run_job(job.id)
    return job


def run_job(job_id):
    """Runs synchronously in-request for now. Swap for a real worker/queue in production."""
    job = db.session.get(BackgroundJob, job_id)
    if not job:
        return
    handler = _handlers.get(job.job_type)
    job.status = "processing"
    job.started_at = datetime.utcnow()
    db.session.commit()

    try:
        payload = json.loads(job.payload_json or "{}")
        result = handler(**payload) if handler else None
        job.status = "completed"
        job.result_json = json.dumps(result, default=str) if result is not None else None
    except Exception as e:
        logger.exception("Job %s failed", job.job_type)
        job.status = "failed"
        job.error = str(e)
    finally:
        job.finished_at = datetime.utcnow()
        db.session.commit()


def run_due_scheduled_jobs():
    now = datetime.utcnow()
    due = ScheduledJob.query.filter(ScheduledJob.enabled == True, ScheduledJob.next_run_at <= now).all()  # noqa: E712
    for sched in due:
        enqueue(sched.job_type, module_id=sched.module_id)
        sched.last_run_at = now
        sched.next_run_at = now + timedelta(seconds=sched.interval_seconds)
    db.session.commit()
    return len(due)
