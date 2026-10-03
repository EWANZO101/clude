import json
import secrets
import uuid
from datetime import datetime

from flask_login import UserMixin
from argon2 import PasswordHasher
from argon2.exceptions import VerifyMismatchError

from app.extensions import db

_ph = PasswordHasher()


def gen_uuid() -> str:
    return str(uuid.uuid4())


def gen_sku() -> str:
    return "SKU" + secrets.token_hex(4).upper()


def gen_serial_number() -> str:
    return "SN" + secrets.token_hex(5).upper()


def gen_inventory_barcode() -> str:
    return "INV" + secrets.token_hex(4).upper()


def unique_sku() -> str:
    code = gen_sku()
    while InventoryItem.query.filter_by(sku=code).first() is not None:
        code = gen_sku()
    return code


def unique_serial_number() -> str:
    code = gen_serial_number()
    while InventoryItem.query.filter_by(serial_number=code).first() is not None:
        code = gen_serial_number()
    return code


ROLES = ("admin", "staff")


class Settings(db.Model):
    """Singleton row (always id=1) holding this install's runtime toggles —
    read fresh on every request rather than cached, so flipping a toggle on
    the Settings page takes effect immediately for every other open tab/
    session with no restart. See get() below for the always-exists-after-
    first-access guarantee the rest of the app relies on."""
    __tablename__ = "settings"

    id = db.Column(db.Integer, primary_key=True)
    tenant_name = db.Column(db.String(120), nullable=False, default="Inventory Ops")

    # When False: no login screen, every page is open, actions are logged
    # under actor "shared". Off by default would be a strange first-run
    # experience, so this starts True; an admin can turn it off from the
    # Settings page once a business decides they don't need per-person
    # accounts, and back on again any time (see app/permissions.py for how
    # the Settings page itself stays reachable either way).
    auth_enabled = db.Column(db.Boolean, nullable=False, default=True)
    # Self-service account creation — off by default even when auth is on,
    # since a small shop normally wants its admin creating accounts, not a
    # public signup form. Irrelevant while auth_enabled is False.
    signup_enabled = db.Column(db.Boolean, nullable=False, default=False)
    # Code128 + QR label rendering on the item pages. Off by default — pure
    # opt-in extra, see app/barcode_render.py.
    barcode_enabled = db.Column(db.Boolean, nullable=False, default=False)

    @classmethod
    def get(cls) -> "Settings":
        row = cls.query.get(1)
        if row is None:
            row = cls(id=1)
            db.session.add(row)
            db.session.commit()
        return row


class LocalUser(UserMixin, db.Model):
    """A person who can log in — deliberately much simpler than kiosk_app's
    LocalUser (no badge codes, no cross-system sync fields, no per-login
    activity review): this app has no hardware-scanner workflow and no
    Admin Panel to sync with, so none of that machinery applies here."""
    __tablename__ = "local_users"

    id = db.Column(db.Integer, primary_key=True)
    username = db.Column(db.String(80), unique=True, nullable=False)
    role = db.Column(db.String(16), nullable=False, default="staff")  # admin | staff
    password_hash = db.Column(db.String(255), nullable=False)
    is_active = db.Column(db.Boolean, nullable=False, default=True)

    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    last_login_at = db.Column(db.DateTime, nullable=True)

    def set_password(self, raw_password: str):
        self.password_hash = _ph.hash(raw_password)

    def check_password(self, raw_password: str) -> bool:
        if not raw_password or not self.password_hash:
            return False
        try:
            return _ph.verify(self.password_hash, raw_password)
        except VerifyMismatchError:
            return False
        except Exception:
            return False

    def get_id(self):
        return str(self.id)

    def __repr__(self):
        return f"<LocalUser {self.username}>"


class AuditLogEntry(db.Model):
    __tablename__ = "audit_log_entries"

    id = db.Column(db.Integer, primary_key=True)
    actor = db.Column(db.String(255), nullable=True)
    action = db.Column(db.String(64), nullable=False)
    target = db.Column(db.String(255), nullable=True)
    detail = db.Column(db.Text, nullable=True)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)


class ItemType(db.Model):
    """A category of inventory item — 'Cable', 'Spare Part', or whatever
    else an admin defines. One built-in row ('general') is seeded at
    startup so a fresh install has somewhere to put items from minute one;
    is_builtin blocks deletion the same way a permanent role would."""
    __tablename__ = "item_types"

    key = db.Column(db.String(64), primary_key=True)
    name = db.Column(db.String(255), nullable=False)
    description = db.Column(db.Text, nullable=True)
    is_builtin = db.Column(db.Boolean, nullable=False, default=False)

    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    updated_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow, onupdate=datetime.utcnow)
    deleted_at = db.Column(db.DateTime, nullable=True)  # tombstone, never hard-deleted

    fields = db.relationship(
        "ItemTypeField", back_populates="item_type", cascade="all, delete-orphan",
        order_by="ItemTypeField.sort_order",
    )

    def __repr__(self):
        return f"<ItemType {self.key}>"


class ItemTypeField(db.Model):
    """One custom field definition belonging to an ItemType. Values
    themselves live in InventoryItem.custom_fields (one JSON column per
    item, not a full EAV table)."""
    __tablename__ = "item_type_fields"
    __table_args__ = (
        db.UniqueConstraint("item_type_key", "key", name="uq_item_type_field_key"),
    )

    id = db.Column(db.Integer, primary_key=True)
    item_type_key = db.Column(db.String(64), db.ForeignKey("item_types.key"), nullable=False)
    key = db.Column(db.String(64), nullable=False)
    label = db.Column(db.String(255), nullable=False)
    # text | number | boolean | date | select | measurement | serial_number | sku | custom_unit
    field_type = db.Column(db.String(32), nullable=False, default="text")
    options_json = db.Column(db.Text, nullable=True)  # choices for field_type == "select"
    required = db.Column(db.Boolean, nullable=False, default=False)
    sort_order = db.Column(db.Integer, nullable=False, default=0)

    item_type = db.relationship("ItemType", back_populates="fields")

    def options(self) -> list:
        try:
            return json.loads(self.options_json) if self.options_json else []
        except ValueError:
            return []


class InventoryItem(db.Model):
    """One row per physical thing being tracked, typed by item_type_key
    rather than a fixed schema — a cable, a spare part, anything the
    business wants to call something. checked_out_by_name/current_project
    are real columns (not custom fields) since 'who has this / what job is
    it on' is common enough across types to deserve first-class support,
    alongside InventoryItemEvent's history below."""
    __tablename__ = "inventory_items"

    id = db.Column(db.Integer, primary_key=True)
    public_id = db.Column(db.String(36), unique=True, nullable=False, default=gen_uuid)
    item_type_key = db.Column(db.String(64), db.ForeignKey("item_types.key"), nullable=False)

    name = db.Column(db.String(255), nullable=False)
    sku = db.Column(db.String(64), unique=True, nullable=True, index=True)
    serial_number = db.Column(db.String(128), unique=True, nullable=True, index=True)
    status = db.Column(db.String(16), nullable=False, default="active")

    # Measurement system: quantity_value is a plain float in quantity_unit's
    # own terms (see app/measurement.py) — converting units keeps this value
    # meaningful via measurement.convert(), never silently rescaling data.
    quantity_value = db.Column(db.Float, nullable=True)
    quantity_unit = db.Column(db.String(16), nullable=True)  # key into MEASUREMENT_KINDS[...]["units"]

    # One JSON blob per item for every ItemTypeField value, keyed by field key.
    custom_fields = db.Column(db.Text, nullable=True)

    # Own column rather than a separate barcode registry table — this app
    # only ever puts a barcode on an InventoryItem, unlike kiosk_app where
    # several different tables shared one Barcode table.
    barcode_code = db.Column(db.String(32), unique=True, nullable=True)

    checked_out_by_name = db.Column(db.String(255), nullable=True)
    current_project = db.Column(db.String(255), nullable=True)

    deleted_at = db.Column(db.DateTime, nullable=True)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    updated_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow, onupdate=datetime.utcnow)

    item_type = db.relationship("ItemType")
    events = db.relationship(
        "InventoryItemEvent", back_populates="item", cascade="all, delete-orphan",
        order_by="InventoryItemEvent.occurred_at.desc()",
    )

    def custom_fields_dict(self) -> dict:
        try:
            return json.loads(self.custom_fields) if self.custom_fields else {}
        except ValueError:
            return {}


class InventoryItemEvent(db.Model):
    """One event-log row per notable thing that happened to an item —
    issue | checkin | scrap | maintenance_start | maintenance_end | note."""
    __tablename__ = "inventory_item_events"

    id = db.Column(db.Integer, primary_key=True)
    item_id = db.Column(db.Integer, db.ForeignKey("inventory_items.id"), nullable=False)

    event_type = db.Column(db.String(32), nullable=False)
    actor = db.Column(db.String(255), nullable=True)
    project = db.Column(db.String(255), nullable=True)

    occurred_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    resolved_at = db.Column(db.DateTime, nullable=True)
    outcome = db.Column(db.String(32), nullable=True)
    detail = db.Column(db.Text, nullable=True)

    item = db.relationship("InventoryItem", back_populates="events")
