from datetime import datetime, timezone
from app.extensions import db
from app.units import normalise_measurement


class Item(db.Model):
    __tablename__ = "items"

    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(128), nullable=False)
    sku = db.Column(db.String(64), unique=True, nullable=True, index=True)
    description = db.Column(db.Text, nullable=True)
    category = db.Column(db.String(64), nullable=True, index=True)  # legacy free-text category, kept for back-compat; see Category for the current many-to-many model
    location = db.Column(db.String(128), nullable=True)

    # ── Stock ──────────────────────────────────────────────────────────────
    quantity = db.Column(db.Integer, default=0, nullable=False)
    unit = db.Column(db.String(32), nullable=True)          # e.g. pcs, kg, m
    low_stock_threshold = db.Column(db.Integer, default=5, nullable=False)

    # measurement_type/stock_amount let an admin track stock a different way
    # than a plain integer count. 'count' keeps using `quantity` above
    # (unchanged, so every existing count-tracked item and every call site
    # that adjusts `quantity` keeps working exactly as before); 'weight' /
    # 'volume' / 'length' use `stock_amount` (a float) instead, paired with
    # `unit` drawn from app/units.py's catalog for that type.
    measurement_type = db.Column(db.String(16), default="count", nullable=False)
    stock_amount = db.Column(db.Float, nullable=True)

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
    categories = db.relationship("Category", secondary="item_categories", back_populates="items")

    # ── Helpers ────────────────────────────────────────────────────────────
    @property
    def is_low_stock(self) -> bool:
        if self.measurement_type != "count":
            return False  # low-stock threshold only makes sense for whole-unit counts today
        return self.quantity <= self.low_stock_threshold

    @property
    def stock_status(self) -> str:
        if self.measurement_type == "count":
            if self.quantity == 0:
                return "out_of_stock"
            if self.is_low_stock:
                return "low_stock"
            return "in_stock"
        amount = self.stock_amount or 0
        return "out_of_stock" if amount <= 0 else "in_stock"

    @property
    def display_stock(self) -> str:
        """Human-readable stock line respecting the configured measurement
        type, e.g. '12 pcs' or '3.5 kg'."""
        if self.measurement_type == "count":
            return f"{self.quantity} {self.unit or 'pcs'}"
        amount = self.stock_amount if self.stock_amount is not None else 0
        # Trim trailing .0 for whole numbers, keep decimals otherwise
        amount_str = f"{amount:g}"
        return f"{amount_str} {self.unit or ''}".strip()

    def adjust_stock(self, delta: int):
        """Add or subtract from quantity. Pass negative delta to reduce.
        Only meaningful for measurement_type == 'count' — weight/volume/
        length items are edited directly via stock_amount instead."""
        self.quantity = max(0, self.quantity + delta)
        self.updated_at = datetime.now(timezone.utc)

    def set_measurement(self, measurement_type: str, unit: str):
        self.measurement_type, self.unit = normalise_measurement(measurement_type, unit)

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "name": self.name,
            "sku": self.sku,
            "description": self.description,
            "category": self.category,
            "categories": [c.to_dict(counts=False) for c in self.categories],
            "location": self.location,
            "quantity": self.quantity,
            "unit": self.unit,
            "measurement_type": self.measurement_type,
            "stock_amount": self.stock_amount,
            "display_stock": self.display_stock,
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
