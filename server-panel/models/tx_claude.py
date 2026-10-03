from datetime import datetime

from database import db


class TxClaudeLink(db.Model):
    """A server folder exposed to claude.ai/code through Claude Code Remote
    Control. rel_path is relative to the instance's resources/ folder
    ("" = the whole resources folder)."""

    __tablename__ = "tx_claude_links"

    id = db.Column(db.Integer, primary_key=True)
    instance_id = db.Column(db.Integer, db.ForeignKey("tx_instances.id", ondelete="CASCADE"), nullable=False)
    rel_path = db.Column(db.String(400), nullable=False, default="")
    name = db.Column(db.String(120), nullable=False)
    permission_mode = db.Column(db.String(20), nullable=False, default="default")
    enabled = db.Column(db.Boolean, nullable=False, default=True)   # restarted automatically after reboots
    created_by = db.Column(db.String(64), nullable=True)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)

    def to_dict(self):
        return {"id": self.id, "instance_id": self.instance_id, "rel_path": self.rel_path, "name": self.name,
                "permission_mode": self.permission_mode, "enabled": self.enabled, "created_by": self.created_by,
                "created_at": self.created_at.isoformat() + "Z" if self.created_at else None}
