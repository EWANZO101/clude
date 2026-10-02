from datetime import datetime

from database import db


class Job(db.Model):
    __tablename__ = "jobs"

    id = db.Column(db.String(36), primary_key=True)  # uuid4 hex
    name = db.Column(db.String(128), nullable=False)
    target = db.Column(db.String(64), nullable=False)  # e.g. "installer:snailycad"

    status = db.Column(db.String(16), nullable=False, default="pending")  # pending/running/success/failed
    progress = db.Column(db.Integer, nullable=False, server_default="0", default=0)

    log_text = db.Column(db.Text, nullable=False, server_default="", default="")
    error = db.Column(db.Text, nullable=True)

    user_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=True)

    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    started_at = db.Column(db.DateTime, nullable=True)
    finished_at = db.Column(db.DateTime, nullable=True)

    def to_dict(self):
        return {
            "id": self.id,
            "name": self.name,
            "target": self.target,
            "status": self.status,
            "progress": self.progress,
            "log_text": self.log_text,
            "error": self.error,
            "created_at": self.created_at.isoformat() if self.created_at else None,
            "started_at": self.started_at.isoformat() if self.started_at else None,
            "finished_at": self.finished_at.isoformat() if self.finished_at else None,
        }
