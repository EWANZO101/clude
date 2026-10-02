from datetime import datetime

from database import db


class BackupTarget(db.Model):
    """A path/folder an admin has registered for on-demand tar.gz backups.
    Archives themselves are not tracked in the DB — they live on disk under
    DATA_DIR/backups/archives and are listed by scanning that directory, so
    a target can be deleted without losing its archive history."""

    __tablename__ = "backup_targets"

    id = db.Column(db.Integer, primary_key=True)
    label = db.Column(db.String(80), nullable=False)
    path = db.Column(db.String(1024), nullable=False)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    last_backup_at = db.Column(db.DateTime, nullable=True)

    def slug(self):
        """Filesystem-safe prefix used for this target's archive filenames."""
        import re
        s = re.sub(r"[^a-zA-Z0-9._-]+", "-", self.label.strip().lower()).strip("-")
        return s or f"target-{self.id}"

    def to_dict(self):
        return {
            "id": self.id,
            "label": self.label,
            "path": self.path,
            "created_at": self.created_at.isoformat() if self.created_at else None,
            "last_backup_at": self.last_backup_at.isoformat() if self.last_backup_at else None,
        }
