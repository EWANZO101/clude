"""
Local embedded database models for StockTool Kiosk v2.

Every syncable table carries three bookkeeping columns used by the sync
engine (Part 3) — none of this is wired up to the cloud yet in Part 1,
but the schema is designed so Part 3 doesn't need a migration to add it
later:

  - server_id     nullable int  — the row's ID on the cloud API, once synced
  - updated_at    datetime      — last local modification time
  - dirty         bool          — True if this row has local changes that
                                   haven't been pushed to the cloud yet
"""
from datetime import datetime, timezone
from flask_sqlalchemy import SQLAlchemy

db = SQLAlchemy()


def _now():
    return datetime.now(timezone.utc)


class SyncMixin:
    server_id = db.Column(db.Integer, nullable=True, index=True)
    updated_at = db.Column(db.DateTime, default=_now, onupdate=_now, nullable=False)
    dirty = db.Column(db.Boolean, default=True, nullable=False)  # True until first sync


class Item(db.Model, SyncMixin):
    __tablename__ = "items"

    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(200), nullable=False)
    sku = db.Column(db.String(100), nullable=True, index=True)
    description = db.Column(db.Text, nullable=True)
    quantity = db.Column(db.Integer, nullable=False, default=0)
    unit = db.Column(db.String(32), nullable=True)
    barcode_code = db.Column(db.String(32), nullable=True, unique=True, index=True)

    def adjust_stock(self, delta: int):
        self.quantity = max(0, self.quantity + delta)
        self.dirty = True
        self.updated_at = _now()

    def to_dict(self):
        return {
            "id": self.id, "name": self.name, "sku": self.sku,
            "description": self.description, "quantity": self.quantity,
            "unit": self.unit, "barcode_code": self.barcode_code,
            "updated_at": self.updated_at.isoformat() if self.updated_at else None,
        }


class Tool(db.Model, SyncMixin):
    __tablename__ = "tools"

    STATUS_AVAILABLE = "available"
    STATUS_CHECKED_OUT = "checked_out"
    STATUS_MAINTENANCE = "maintenance"

    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(200), nullable=False)
    description = db.Column(db.Text, nullable=True)
    status = db.Column(db.String(32), nullable=False, default=STATUS_AVAILABLE)
    checked_out_by_name = db.Column(db.String(120), nullable=True)
    barcode_code = db.Column(db.String(32), nullable=True, unique=True, index=True)

    def to_dict(self):
        return {
            "id": self.id, "name": self.name, "description": self.description,
            "status": self.status, "checked_out_by_name": self.checked_out_by_name,
            "barcode_code": self.barcode_code,
            "updated_at": self.updated_at.isoformat() if self.updated_at else None,
        }


class Project(db.Model, SyncMixin):
    __tablename__ = "projects"

    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(200), nullable=False)
    description = db.Column(db.Text, nullable=True)
    is_active = db.Column(db.Boolean, default=True, nullable=False)
    barcode_code = db.Column(db.String(32), nullable=True, unique=True, index=True)

    def to_dict(self):
        return {
            "id": self.id, "name": self.name, "description": self.description,
            "is_active": self.is_active, "barcode_code": self.barcode_code,
            "updated_at": self.updated_at.isoformat() if self.updated_at else None,
        }


class Barcode(db.Model):
    """
    Central lookup table: scanning a code means finding the row here first,
    then following entity_type/entity_id to the actual item/tool/project.
    Kept as its own table (rather than a code column on each entity only)
    so barcode registration/lookup is a single fast indexed query
    regardless of what the code turns out to be.
    """
    __tablename__ = "barcodes"

    id = db.Column(db.Integer, primary_key=True)
    code = db.Column(db.String(32), unique=True, nullable=False, index=True)
    entity_type = db.Column(db.String(20), nullable=False)  # item | tool | project
    entity_id = db.Column(db.Integer, nullable=False)
    created_at = db.Column(db.DateTime, default=_now, nullable=False)

    def to_dict(self):
        return {"code": self.code, "entity_type": self.entity_type, "entity_id": self.entity_id}


class LocalUser(db.Model):
    """
    Read-mostly local mirror of cloud users, for badge-scan kiosk login.
    No password management here — this app has NO administrative
    functionality per spec. Password/account admin lives in the cloud
    admin app; this table is populated by the sync engine (Part 3).
    """
    __tablename__ = "local_users"

    id = db.Column(db.Integer, primary_key=True)
    server_id = db.Column(db.Integer, nullable=True, index=True)
    username = db.Column(db.String(64), nullable=False, unique=True)
    badge_code = db.Column(db.String(32), nullable=True, unique=True, index=True)
    role = db.Column(db.String(32), nullable=False, default="stock_user")
    is_active = db.Column(db.Boolean, default=True, nullable=False)

    def to_dict(self):
        return {"id": self.id, "username": self.username, "role": self.role,
                "is_active": self.is_active}


class SyncLog(db.Model):
    """Foundation for Part 3 — every sync attempt (push or pull) gets a row
    here so the app can show sync status/history and support retry."""
    __tablename__ = "sync_log"

    id = db.Column(db.Integer, primary_key=True)
    direction = db.Column(db.String(10), nullable=False)  # push | pull
    entity_type = db.Column(db.String(20), nullable=True)
    status = db.Column(db.String(20), nullable=False)  # success | error | conflict
    message = db.Column(db.Text, nullable=True)
    created_at = db.Column(db.DateTime, default=_now, nullable=False)

    def to_dict(self):
        return {
            "id": self.id, "direction": self.direction, "entity_type": self.entity_type,
            "status": self.status, "message": self.message,
            "created_at": self.created_at.isoformat() if self.created_at else None,
        }
