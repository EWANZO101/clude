from datetime import datetime, timezone
from app.extensions import db


class HistoryAction:
    CHECKED_OUT = "checked_out"
    CHECKED_IN = "checked_in"
    STATUS_CHANGED = "status_changed"
    NOTE_ADDED = "note_added"

    LABELS = {
        CHECKED_OUT: "Checked Out",
        CHECKED_IN: "Checked In",
        STATUS_CHANGED: "Status Changed",
        NOTE_ADDED: "Note Added",
    }


class ToolHistory(db.Model):
    __tablename__ = "tool_history"

    id = db.Column(db.Integer, primary_key=True)

    tool_id = db.Column(db.Integer, db.ForeignKey("tools.id"), nullable=False, index=True)
    user_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False, index=True)

    action = db.Column(db.String(32), nullable=False)          # HistoryAction.*
    from_status = db.Column(db.String(32), nullable=True)
    to_status = db.Column(db.String(32), nullable=True)
    notes = db.Column(db.Text, nullable=True)

    # Checkout duration tracking
    checked_out_at = db.Column(db.DateTime, nullable=True)
    checked_in_at = db.Column(db.DateTime, nullable=True)

    created_at = db.Column(db.DateTime, default=lambda: datetime.now(timezone.utc))

    # ── Relationships ──────────────────────────────────────────────────────
    tool = db.relationship("Tool", back_populates="history")
    user = db.relationship("User", back_populates="tool_histories")

    # ── Helpers ────────────────────────────────────────────────────────────
    @property
    def action_label(self) -> str:
        return HistoryAction.LABELS.get(self.action, self.action)

    @property
    def duration_hours(self):
        """Returns hours between checkout and checkin, or None if not completed."""
        if self.checked_out_at and self.checked_in_at:
            delta = self.checked_in_at - self.checked_out_at
            return round(delta.total_seconds() / 3600, 1)
        return None

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "tool_id": self.tool_id,
            "tool_name": self.tool.name if self.tool else None,
            "user_id": self.user_id,
            "username": self.user.username if self.user else None,
            "action": self.action,
            "action_label": self.action_label,
            "from_status": self.from_status,
            "to_status": self.to_status,
            "notes": self.notes,
            "checked_out_at": self.checked_out_at.isoformat() if self.checked_out_at else None,
            "checked_in_at": self.checked_in_at.isoformat() if self.checked_in_at else None,
            "duration_hours": self.duration_hours,
            "created_at": self.created_at.isoformat() if self.created_at else None,
        }

    def __repr__(self):
        return f"<ToolHistory tool={self.tool_id} action={self.action}>"
