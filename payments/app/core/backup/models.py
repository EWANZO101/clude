from datetime import datetime
from app.extensions import db


class Backup(db.Model):
    """Records a single backup archive (DB + config + module metadata +
    user-uploaded files) written to BACKUP_FOLDER. Backups are whole-system
    (single-user deployment), not per-user, matching how the DB itself
    works today."""
    __tablename__ = "backups"
    id = db.Column(db.Integer, primary_key=True)
    filename = db.Column(db.String(255), nullable=False)
    size_bytes = db.Column(db.Integer, default=0)
    source = db.Column(db.String(20), default="manual")  # manual, scheduled
    status = db.Column(db.String(20), default="completed")  # completed, failed
    error = db.Column(db.Text)
    created_at = db.Column(db.DateTime, default=datetime.utcnow, index=True)
