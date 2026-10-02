from datetime import datetime, timezone
import uuid
from app.extensions import db


class Barcode(db.Model):
    __tablename__ = "barcodes"

    id = db.Column(db.Integer, primary_key=True)

    # Short alphanumeric code encoded into the printed Code128 barcode.
    # A barcode scanner reads this value and types it (as keyboard input)
    # wherever the operator's cursor is focused -- e.g. the lookup box on
    # the scan page -- unlike a QR code, it does not encode a full URL.
    code = db.Column(db.String(36), unique=True, nullable=False, index=True,
                      default=lambda: uuid.uuid4().hex[:12].upper())

    # Exactly one of these four should be set. item/tool predate this
    # change; user/project were added for kiosk badge-scan login and
    # project stock tracking.
    item_id = db.Column(db.Integer, db.ForeignKey("items.id"), nullable=True, index=True)
    tool_id = db.Column(db.Integer, db.ForeignKey("tools.id"), nullable=True, index=True)
    user_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=True, index=True)
    project_id = db.Column(db.Integer, db.ForeignKey("projects.id"), nullable=True, index=True)

    # Path to the generated Code128 PNG stored in /static/barcodes/
    image_path = db.Column(db.String(256), nullable=True)

    created_at = db.Column(db.DateTime, default=lambda: datetime.now(timezone.utc))

    # -- Relationships --------------------------------------------------
    item = db.relationship("Item", back_populates="barcode", foreign_keys=[item_id])
    tool = db.relationship("Tool", back_populates="barcode", foreign_keys=[tool_id])
    user = db.relationship("User", back_populates="barcode", foreign_keys=[user_id])
    project = db.relationship("Project", back_populates="barcode", foreign_keys=[project_id])

    # -- Helpers ----------------------------------------------------------
    @property
    def entity_type(self) -> str:
        if self.tool_id:
            return "tool"
        if self.item_id:
            return "item"
        if self.project_id:
            return "project"
        if self.user_id:
            return "user"
        return "unknown"

    @property
    def entity_name(self) -> str:
        if self.tool:
            return self.tool.name
        if self.item:
            return self.item.name
        if self.project:
            return self.project.name
        if self.user:
            return self.user.username
        return "Unknown"

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "code": self.code,
            "entity_type": self.entity_type,
            "entity_name": self.entity_name,
            "item_id": self.item_id,
            "tool_id": self.tool_id,
            "user_id": self.user_id,
            "project_id": self.project_id,
            "image_path": self.image_path,
            "created_at": self.created_at.isoformat() if self.created_at else None,
        }

    def __repr__(self):
        return f"<Barcode code={self.code} type={self.entity_type}>"
