"""InstanceItemType/InstanceItemTypeField/InstanceInventoryItem business
logic — Track 2's generic inventory system (see
/root/.claude/plans/sprightly-meandering-whisper.md), Admin Panel +
Client Portal side. Shared by both `app/blueprints/instances.py` and
`app/blueprints/client_portal.py`, same reasoning `_apply_equipment_fields`
already is — one implementation of every validation rule rather than two
copies that could drift apart.

Deliberately has NO audit-logging side effects of its own (unlike
kiosk_app's role_admin.py) — `AuditLogEntry.actor_id` is a hard FK to the
staff `users` table, so writing one here with whatever `actor` a caller
passed would silently store the wrong reference (or fail outright) when
called from client_portal.py with a ClientUser. Same division of
responsibility `_apply_equipment_fields` already uses: this module only
touches the inventory rows, and each ROUTE does its own audit logging —
`log_action(...)` in instances.py, `log_client_action(...)` in
client_portal.py — after a successful call.

`actor_name` parameters below are a plain display string (the caller's
`current_user.email` works for both a staff User and a ClientUser, since
both models carry that column) — used only for InstanceInventoryItem/
InstanceInventoryItemEvent's own plain-string actor/checked_out_by_name
columns, never as an audit-log FK.

Unlike kiosk_app's own item_type_admin.py/inventory_admin.py, there's no
separate "sync merge" function to keep in sync with — these ARE the
functions the sync merge calls into indirectly (agent_api.py's
apply_item_types_sync/apply_inventory_items_sync do their own
last-write-wins row-level merge directly against these same tables), so a
write here just needs a correct, fresh `updated_at` (the model's own
`onupdate=datetime.utcnow` already covers that) for the next sync pass to
carry it down to the kiosk correctly.

Every function returns (ok: bool, message: str) [+ the row, for creates].
"""
import json
import re
import secrets
from datetime import datetime

from app.extensions import db
from app.models import (
    InstanceItemType, InstanceItemTypeField, InstanceInventoryItem, InstanceInventoryItemEvent,
    InstanceNavEntry,
)
from app import measurement


def _slugify(name: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "_", (name or "").strip().lower()).strip("_")
    return slug or "type"


def _ensure_nav_entry_for_type(instance, item_type: InstanceItemType) -> None:
    """Mirrors kiosk_app's item_type_admin.ensure_nav_entry_for_type on
    this side's own InstanceNavEntry cache — created here immediately so
    the Sidebar panel shows it right away, rather than waiting a full
    sync round-trip for the kiosk's own copy to be created and pushed
    back up. The next inventory_sync pass reconciles both sides' NavEntry
    rows the same read-only-cache way roles already work; this is purely
    an instant-feedback convenience, not the system of record (kiosk is)."""
    key = f"type:{item_type.key}"
    if InstanceNavEntry.query.filter_by(instance_id=instance.id, key=key).first() is not None:
        return
    next_order = (
        db.session.query(db.func.max(InstanceNavEntry.sort_order))
        .filter_by(instance_id=instance.id).scalar() or -1
    ) + 1
    db.session.add(InstanceNavEntry(
        instance_id=instance.id, key=key, label=item_type.name, section=item_type.name,
        is_builtin=False, sort_order=next_order,
    ))


# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

def create_type(instance, name: str, description: str = None) -> tuple:
    name = (name or "").strip()
    if not name:
        return False, "Type name is required.", None
    key = _slugify(name)
    base_key = key
    n = 1
    while InstanceItemType.query.filter_by(instance_id=instance.id, key=key).first() is not None:
        n += 1
        key = f"{base_key}_{n}"
    item_type = InstanceItemType(instance_id=instance.id, key=key, name=name, description=(description or "").strip() or None)
    db.session.add(item_type)
    db.session.flush()
    _ensure_nav_entry_for_type(instance, item_type)
    db.session.commit()
    return True, f"Type '{name}' created.", item_type


def update_type(instance, type_key: str, name: str, description: str = None) -> tuple:
    item_type = InstanceItemType.query.filter_by(instance_id=instance.id, key=type_key).first()
    if item_type is None:
        return False, f"Unknown type '{type_key}'."
    name = (name or "").strip()
    if not name:
        return False, "Type name is required."
    item_type.name = name
    item_type.description = (description or "").strip() or None
    nav_row = InstanceNavEntry.query.filter_by(instance_id=instance.id, key=f"type:{type_key}").first()
    if nav_row is not None:
        nav_row.label = name
        nav_row.section = name
    db.session.commit()
    return True, f"Type '{name}' updated."


def delete_type(instance, type_key: str) -> tuple:
    item_type = InstanceItemType.query.filter_by(instance_id=instance.id, key=type_key).first()
    if item_type is None:
        return False, f"Unknown type '{type_key}'."
    if item_type.is_builtin:
        return False, f"'{item_type.name}' is a built-in type and can't be deleted."
    in_use = InstanceInventoryItem.query.filter_by(
        instance_id=instance.id, item_type_key=type_key, deleted_at=None,
    ).count()
    if in_use > 0:
        return False, f"'{item_type.name}' still has {in_use} item(s) — reassign or remove them first."
    item_type.deleted_at = datetime.utcnow()  # tombstone, not a hard delete — see InstanceEquipmentItem's own note
    nav_row = InstanceNavEntry.query.filter_by(instance_id=instance.id, key=f"type:{type_key}").first()
    if nav_row is not None:
        db.session.delete(nav_row)
    db.session.commit()
    return True, f"Type '{item_type.name}' deleted."


FIELD_TYPES = (
    "text", "number", "boolean", "date", "select",
    "measurement", "serial_number", "sku", "custom_unit",
)


def add_field(instance, type_key: str, label: str, field_type: str,
              options: list = None, required: bool = False) -> tuple:
    item_type = InstanceItemType.query.filter_by(instance_id=instance.id, key=type_key).first()
    if item_type is None:
        return False, f"Unknown type '{type_key}'."
    label = (label or "").strip()
    if not label:
        return False, "Field label is required."
    if field_type not in FIELD_TYPES:
        return False, f"Unsupported field type '{field_type}'."
    key = _slugify(label)
    base_key = key
    n = 1
    while InstanceItemTypeField.query.filter_by(instance_item_type_id=item_type.id, key=key).first() is not None:
        n += 1
        key = f"{base_key}_{n}"
    next_order = (
        db.session.query(db.func.max(InstanceItemTypeField.sort_order))
        .filter_by(instance_item_type_id=item_type.id).scalar() or -1
    ) + 1
    db.session.add(InstanceItemTypeField(
        instance_item_type_id=item_type.id, key=key, label=label, field_type=field_type,
        options_json=json.dumps(options or []), required=bool(required), sort_order=next_order,
    ))
    item_type.updated_at = datetime.utcnow()  # fields count as a change to the type for sync purposes
    db.session.commit()
    return True, f"Field '{label}' added to '{item_type.name}'."


def update_field(instance, field_id: int, label: str, field_type: str,
                  options: list = None, required: bool = False) -> tuple:
    field = InstanceItemTypeField.query.get(field_id)
    if field is None or field.item_type.instance_id != instance.id:
        return False, "Unknown field."
    label = (label or "").strip()
    if not label:
        return False, "Field label is required."
    if field_type not in FIELD_TYPES:
        return False, f"Unsupported field type '{field_type}'."
    field.label = label
    field.field_type = field_type
    field.options_json = json.dumps(options or [])
    field.required = bool(required)
    field.item_type.updated_at = datetime.utcnow()
    db.session.commit()
    return True, f"Field '{label}' updated."


def delete_field(instance, field_id: int) -> tuple:
    field = InstanceItemTypeField.query.get(field_id)
    if field is None or field.item_type.instance_id != instance.id:
        return False, "Unknown field."
    field.item_type.updated_at = datetime.utcnow()
    key = field.key
    db.session.delete(field)
    db.session.commit()
    return True, f"Field '{key}' removed."


def type_state(instance, type_key: str) -> dict:
    item_type = InstanceItemType.query.filter_by(instance_id=instance.id, key=type_key).first()
    if item_type is None:
        return None
    return {
        "key": item_type.key, "name": item_type.name, "description": item_type.description,
        "is_builtin": item_type.is_builtin,
        "item_count": InstanceInventoryItem.query.filter_by(
            instance_id=instance.id, item_type_key=type_key, deleted_at=None
        ).count(),
        "fields": [
            {"id": f.id, "key": f.key, "label": f.label, "field_type": f.field_type,
             "options": f.options(), "required": f.required, "sort_order": f.sort_order}
            for f in item_type.fields
        ],
    }


def all_types_state(instance) -> list:
    types = InstanceItemType.query.filter_by(instance_id=instance.id, deleted_at=None).order_by(InstanceItemType.name).all()
    return [type_state(instance, t.key) for t in types]


# ---------------------------------------------------------------------------
# Items
# ---------------------------------------------------------------------------

def create_item(instance, added_by_id, type_key: str, name: str, sku: str = None,
                 serial_number: str = None, quantity_value: float = None, quantity_unit: str = None,
                 custom_fields: dict = None, status: str = "active") -> tuple:
    item_type = InstanceItemType.query.filter_by(instance_id=instance.id, key=type_key).first()
    if item_type is None:
        return False, "Unknown item type.", None
    name = (name or "").strip()
    if not name:
        return False, "Name is required.", None
    sku = (sku or "").strip() or None
    serial_number = (serial_number or "").strip() or None
    if sku and InstanceInventoryItem.query.filter_by(instance_id=instance.id, sku=sku).first():
        return False, f"SKU '{sku}' is already in use.", None
    if serial_number and InstanceInventoryItem.query.filter_by(instance_id=instance.id, serial_number=serial_number).first():
        return False, f"Serial number '{serial_number}' is already in use.", None

    item = InstanceInventoryItem(
        instance_id=instance.id, item_type_key=type_key, name=name, sku=sku, serial_number=serial_number,
        status=status or "active", quantity_value=quantity_value, quantity_unit=quantity_unit,
        custom_fields=json.dumps(custom_fields or {}), added_by_id=added_by_id,
    )
    db.session.add(item)
    db.session.commit()
    return True, f"'{name}' created — it will reach the kiosk on the next sync.", item


def update_item(instance, item_id: int, name: str = None, sku: str = None,
                 serial_number: str = None, status: str = None, custom_fields: dict = None,
                 checked_out_by_name: str = None, current_project: str = None) -> tuple:
    item = InstanceInventoryItem.query.filter_by(instance_id=instance.id, id=item_id, deleted_at=None).first()
    if item is None:
        return False, "Unknown item."
    if name is not None:
        name = name.strip()
        if not name:
            return False, "Name is required."
        item.name = name
    if sku is not None:
        sku = sku.strip() or None
        if sku and InstanceInventoryItem.query.filter(
            InstanceInventoryItem.instance_id == instance.id, InstanceInventoryItem.sku == sku,
            InstanceInventoryItem.id != item.id,
        ).first():
            return False, f"SKU '{sku}' is already in use."
        item.sku = sku
    if serial_number is not None:
        serial_number = serial_number.strip() or None
        if serial_number and InstanceInventoryItem.query.filter(
            InstanceInventoryItem.instance_id == instance.id, InstanceInventoryItem.serial_number == serial_number,
            InstanceInventoryItem.id != item.id,
        ).first():
            return False, f"Serial number '{serial_number}' is already in use."
        item.serial_number = serial_number
    if status is not None:
        item.status = status
    if custom_fields is not None:
        item.custom_fields = json.dumps(custom_fields)
    if checked_out_by_name is not None:
        item.checked_out_by_name = checked_out_by_name.strip() or None
    if current_project is not None:
        item.current_project = current_project.strip() or None
    db.session.commit()
    return True, f"'{item.name}' updated."


def delete_item(instance, item_id: int) -> tuple:
    item = InstanceInventoryItem.query.filter_by(instance_id=instance.id, id=item_id, deleted_at=None).first()
    if item is None:
        return False, "Unknown item."
    item.deleted_at = datetime.utcnow()
    db.session.commit()
    return True, f"'{item.name}' deleted."


def change_measurement(instance, item_id: int, new_unit: str) -> tuple:
    item = InstanceInventoryItem.query.filter_by(instance_id=instance.id, id=item_id, deleted_at=None).first()
    if item is None:
        return False, "Unknown item."
    old_unit = item.quantity_unit
    if item.quantity_value is not None and old_unit:
        converted = measurement.convert(item.quantity_value, old_unit, new_unit)
        if converted is not None:
            item.quantity_value = converted
            item.quantity_unit = new_unit
            db.session.commit()
            return True, f"Converted from {old_unit} to {new_unit}."
    item.quantity_unit = new_unit
    db.session.commit()
    return True, f"Unit changed to {new_unit} — existing quantity value kept as-is (different measurement kind)."


def change_type(instance, item_id: int, new_type_key: str) -> tuple:
    item = InstanceInventoryItem.query.filter_by(instance_id=instance.id, id=item_id, deleted_at=None).first()
    if item is None:
        return False, "Unknown item."
    new_type = InstanceItemType.query.filter_by(instance_id=instance.id, key=new_type_key).first()
    if new_type is None:
        return False, "Unknown target type."
    item.item_type_key = new_type_key
    db.session.commit()
    return True, f"'{item.name}' is now a '{new_type.name}'."


def generate_sku(instance, item_id: int) -> tuple:
    item = InstanceInventoryItem.query.filter_by(instance_id=instance.id, id=item_id, deleted_at=None).first()
    if item is None:
        return False, "Unknown item."
    sku = "SKU" + secrets.token_hex(4).upper()
    while InstanceInventoryItem.query.filter_by(instance_id=instance.id, sku=sku).first() is not None:
        sku = "SKU" + secrets.token_hex(4).upper()
    item.sku = sku
    db.session.commit()
    return True, f"New SKU: {sku}"


def generate_serial_number(instance, item_id: int) -> tuple:
    item = InstanceInventoryItem.query.filter_by(instance_id=instance.id, id=item_id, deleted_at=None).first()
    if item is None:
        return False, "Unknown item."
    serial = "SN" + secrets.token_hex(5).upper()
    while InstanceInventoryItem.query.filter_by(instance_id=instance.id, serial_number=serial).first() is not None:
        serial = "SN" + secrets.token_hex(5).upper()
    item.serial_number = serial
    db.session.commit()
    return True, f"New serial number: {serial}"


EVENT_TYPES = ("issue", "checkin", "scrap", "maintenance_start", "maintenance_end", "note")


def log_event(instance, actor_name: str, item_id: int, event_type: str, project: str = None, detail: str = None) -> tuple:
    item = InstanceInventoryItem.query.filter_by(instance_id=instance.id, id=item_id, deleted_at=None).first()
    if item is None:
        return False, "Unknown item."
    if event_type not in EVENT_TYPES:
        return False, f"Unsupported event type '{event_type}'."
    db.session.add(InstanceInventoryItemEvent(
        item_id=item.id, event_type=event_type, actor=actor_name, project=(project or "").strip() or None,
        detail=(detail or "").strip() or None,
    ))
    if event_type == "issue":
        item.current_project = (project or "").strip() or item.current_project
        item.checked_out_by_name = actor_name
    elif event_type in ("checkin", "scrap"):
        item.checked_out_by_name = None
        if event_type == "scrap":
            item.status = "scrapped"
    db.session.commit()
    return True, f"'{event_type}' logged for '{item.name}'."


def bulk_update(instance, item_ids: list, status: str = None,
                 quantity_unit: str = None, item_type_key: str = None) -> tuple:
    items = InstanceInventoryItem.query.filter(
        InstanceInventoryItem.instance_id == instance.id,
        InstanceInventoryItem.id.in_(item_ids), InstanceInventoryItem.deleted_at.is_(None),
    ).all()
    if not items:
        return False, "No matching items.", 0
    if item_type_key and InstanceItemType.query.filter_by(instance_id=instance.id, key=item_type_key).first() is None:
        return False, "Unknown target type.", 0
    count = 0
    for item in items:
        if status:
            item.status = status
        if quantity_unit:
            converted = measurement.convert(item.quantity_value, item.quantity_unit, quantity_unit) \
                if item.quantity_value is not None and item.quantity_unit else None
            item.quantity_value = converted if converted is not None else item.quantity_value
            item.quantity_unit = quantity_unit
        if item_type_key:
            item.item_type_key = item_type_key
        count += 1
    db.session.commit()
    return True, f"{count} item(s) updated.", count


def bulk_delete(instance, item_ids: list) -> tuple:
    items = InstanceInventoryItem.query.filter(
        InstanceInventoryItem.instance_id == instance.id,
        InstanceInventoryItem.id.in_(item_ids), InstanceInventoryItem.deleted_at.is_(None),
    ).all()
    if not items:
        return False, "No matching items.", 0
    now = datetime.utcnow()
    for item in items:
        item.deleted_at = now
    db.session.commit()
    return True, f"{len(items)} item(s) deleted.", len(items)
