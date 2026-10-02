import uuid
from datetime import datetime
from app.extensions import db

STATUS_RUNNING = "running"
STATUS_SUCCESS = "success"
STATUS_FAILED = "failed"


def gen_uuid():
    return str(uuid.uuid4())


class Backup(db.Model):
    """A record of a single backup attempt. A backup is only marked
    'success' after the copy has been independently opened and its
    integrity verified — starting a backup process is not the same as
    completing one."""

    __tablename__ = "backups"

    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    triggered_by = db.Column(db.String(20), nullable=False, default="manual")  # manual | scheduled
    status = db.Column(db.String(20), nullable=False, default=STATUS_RUNNING)
    file_path = db.Column(db.String(500), nullable=True)
    checksum_sha256 = db.Column(db.String(64), nullable=True)
    size_bytes = db.Column(db.Integer, nullable=True)
    verification_error = db.Column(db.Text, nullable=True)

    started_at = db.Column(db.DateTime, default=datetime.utcnow)
    finished_at = db.Column(db.DateTime, nullable=True)
