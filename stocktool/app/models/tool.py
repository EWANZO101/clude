from datetime import datetime, timezone
from app.extensions import db


class ToolStatus:
    AVAILABLE = "available"
    CHECKED_OUT = "checked_out"
    BROKEN = "broken"
    UNDER_REPAIR = "under_repair"
    STOLEN = "stolen"
    LOST = "lost"
    ALL = [AVAILABLE, CHECKED_OUT, BROKEN, UNDER_REPAIR, STOLEN, LOST]

    LABELS = {
        AVAILABLE: "Available",
        CHECKED_OUT: "Checked Out",
        BROKEN: "Broken",
        UNDER_REPAIR: "Under Repair",
        STOLEN: "Stolen",
        LOST: "Lost",
    }

    # Badge colours (Flowbite dark theme compatible)
    BADGE_CLASSES = {
        AVAILABLE: "bg-green-900 text-green-300",
        CHECKED_OUT: "bg-blue-900 text-blue-300",
        BROKEN: "bg-red-900 text-red-300",
        UNDER_REPAIR: "bg-yellow-900 text-yellow-300",
        STOLEN: "bg-purple-900 text-purple-300",
        LOST: "bg-gray-700 text-gray-300",
    }


class Tool(db.Model):
    __tablename__ = "tools"

    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(128), nullable=False)
    tool_number = db.Column(db.String(64), unique=True, nullable=True, index=True)
    brand = db.Column(db.String(64), nullable=True)
    model = db.Column(db.String(64), nullable=True)
    serial_number = db.Column(db.String(128), unique=True, nullable=True, index=True)
    description = db.Column(db.Text, nullable=True)
    category = db.Column(db.String(64), nullable=True, index=True)
    location = db.Column(db.String(128), nullable=True)

    # ── Status ─────────────────────────────────────────────────────────────
    status = db.Column(db.String(32), default=ToolStatus.AVAILABLE, nullable=False, index=True)
    condition_notes = db.Column(db.Text, nullable=True)

    # ── Current checkout (denormalised for fast lookup) ────────────────────
    checked_out_by_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=True)
    checked_out_at = db.Column(db.DateTime, nullable=True)
    checked_out_by = db.relationship("User", foreign_keys=[checked_out_by_id])

    # ── Metadata ───────────────────────────────────────────────────────────
    purchase_date = db.Column(db.Date, nullable=True)
    purchase_price = db.Column(db.Float, nullable=True)
    is_active = db.Column(db.Boolean, default=True, nullable=False)
    created_at = db.Column(db.DateTime, default=lambda: datetime.now(timezone.utc))
    updated_at = db.Column(
        db.DateTime,
        default=lambda: datetime.now(timezone.utc),
        onupdate=lambda: datetime.now(timezone.utc)
    )

    # ── Relationships ──────────────────────────────────────────────────────
    history = db.relationship("ToolHistory", back_populates="tool",
                               lazy="dynamic", order_by="ToolHistory.created_at.desc()")
    barcode = db.relationship("Barcode", back_populates="tool", uselist=False,
                               foreign_keys="Barcode.tool_id")

    # ── Helpers ────────────────────────────────────────────────────────────
    @property
    def status_label(self) -> str:
        return ToolStatus.LABELS.get(self.status, self.status)

    @property
    def status_badge(self) -> str:
        return ToolStatus.BADGE_CLASSES.get(self.status, "bg-gray-700 text-gray-300")

    @property
    def is_available(self) -> bool:
        return self.status == ToolStatus.AVAILABLE

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "name": self.name,
            "tool_number": self.tool_number,
            "brand": self.brand,
            "model": self.model,
            "serial_number": self.serial_number,
            "description": self.description,
            "category": self.category,
            "location": self.location,
            "status": self.status,
            "status_label": self.status_label,
            "condition_notes": self.condition_notes,
            "checked_out_by": self.checked_out_by.username if self.checked_out_by else None,
            "checked_out_at": self.checked_out_at.isoformat() if self.checked_out_at else None,
            "purchase_date": self.purchase_date.isoformat() if self.purchase_date else None,
            "purchase_price": self.purchase_price,
            "is_active": self.is_active,
            "created_at": self.created_at.isoformat() if self.created_at else None,
            "updated_at": self.updated_at.isoformat() if self.updated_at else None,
        }

    def __repr__(self):
        return f"<Tool {self.name} [{self.status}]>"
