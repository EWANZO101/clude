from datetime import datetime
from app.extensions import db


class BackgroundJob(db.Model):
    __tablename__ = "background_jobs"
    id = db.Column(db.Integer, primary_key=True)
    job_type = db.Column(db.String(80), nullable=False, index=True)
    module_id = db.Column(db.String(80))
    user_id = db.Column(db.String(36), db.ForeignKey("users.id"), nullable=True)
    status = db.Column(db.String(20), default="queued")  # queued, processing, completed, failed
    payload_json = db.Column(db.Text)
    result_json = db.Column(db.Text)
    error = db.Column(db.Text)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    started_at = db.Column(db.DateTime)
    finished_at = db.Column(db.DateTime)


class ScheduledJob(db.Model):
    __tablename__ = "scheduled_jobs"
    id = db.Column(db.Integer, primary_key=True)
    job_type = db.Column(db.String(80), nullable=False)
    module_id = db.Column(db.String(80))
    interval_seconds = db.Column(db.Integer, nullable=False)
    last_run_at = db.Column(db.DateTime)
    next_run_at = db.Column(db.DateTime, default=datetime.utcnow)
    enabled = db.Column(db.Boolean, default=True)
