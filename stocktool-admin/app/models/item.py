from datetime import datetime, timezone
from app.extensions import db


class Item(db.Model):
    __tablename__ = "items"

    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(128), nullable=False)
    sku = db.Column(db.String(64), unique=True, nullable=True, index=True)
    description = db.Column(db.Text, nullable=True)
    category = db.Column(db.String(64), nullable=True, index=True)
    location = db.Column(db.String(128), nullable=True)

    # ── Stock ──────────────────────────────────────────────────────────────
    quantity = db.Column(db.Integer, default=0, nullable=False)
    unit = db.Column(db.String(32), nullable=True)          # e.g. pcs, kg, m
    low_stock_threshold = db.Column(db.Integer, default=5, nullable=False)

    # ── Metadata ───────────────────────────────────────────────────────────
    is_active = db.Column(db.Boolean, default=True, nullable=False)
    created_at = db.Column(db.DateTime, default=lambda: datetime.now(timezone.utc))
    updated_at = db.Column(
        db.DateTime,
        default=lambda: datetime.now(timezone.utc),
        onupdate=lambda: datetime.now(timezone.utc)
    )

    # ── Relationships ──────────────────────────────────────────────────────
    barcode = db.relationship("Barcode", back_populates="item", uselist=False,
                               foreign_keys="Barcode.item_id")

    # ── Helpers ────────────────────────────────────────────────────────────
    @property
    def is_low_stock(self) -> bool:
        return self.quantity <= self.low_stock_threshold

    @property
    def stock_status(self) -> str:
        if self.quantity == 0:
            return "out_of_stock"
        if self.is_low_stock:
            return "low_stock"
        return "in_stock"

    def adjust_stock(self, delta: int):
        """Add or subtract from quantity. Pass negative delta to reduce."""
        self.quantity = max(0, self.quantity + delta)
        self.updated_at = datetime.now(timezone.utc)

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "name": self.name,
            "sku": self.sku,
            "description": self.description,
            "category": self.category,
            "location": self.location,
            "quantity": self.quantity,
            "unit": self.unit,
            "low_stock_threshold": self.low_stock_threshold,
            "stock_status": self.stock_status,
            "is_low_stock": self.is_low_stock,
            "is_active": self.is_active,
            "barcode_code": self.barcode.code if self.barcode else None,
            "created_at": self.created_at.isoformat() if self.created_at else None,
            "updated_at": self.updated_at.isoformat() if self.updated_at else None,
        }

    def __repr__(self):
        return f"<Item {self.name} qty={self.quantity}>"
