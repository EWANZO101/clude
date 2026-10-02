"""InventoryItem CRUD + bulk-operation + measurement-conversion business
logic (adapted from kiosk_app/app/inventory_admin.py). Shared by
blueprints/inventory.py's human-facing routes.

Every function returns (ok: bool, message: str) unless noted otherwise.
"""
import json

from app.extensions import db
from app.models import (
    ItemType, InventoryItem, InventoryItemEvent, AuditLogEntry,
    gen_inventory_barcode, unique_sku, unique_serial_number,
)
from app import measurement


def _audit(actor: str, action: str, target: str = None, detail: str = None):
    db.session.add(AuditLogEntry(actor=actor, action=action, target=target, detail=detail))


def _new_barcode() -> str:
    code = gen_inventory_barcode()
    while InventoryItem.query.filter_by(barcode_code=code).first() is not None:
        code = gen_inventory_barcode()
    return code


def create_item(actor: str, item_type_key: str, name: str, sku: str = None,
                 serial_number: str = None, quantity_value: float = None,
                 quantity_unit: str = None, custom_fields: dict = None,
                 status: str = "active") -> tuple:
    item_type = ItemType.query.get(item_type_key)
    if item_type is None:
        return False, "Unknown item type.", None
    name = (name or "").strip()
    if not name:
        return False, "Name is required.", None

    sku = (sku or "").strip() or None
    serial_number = (serial_number or "").strip() or None
    if sku and InventoryItem.query.filter_by(sku=sku).first() is not None:
        return False, f"SKU '{sku}' is already in use.", None
    if serial_number and InventoryItem.query.filter_by(serial_number=serial_number).first() is not None:
        return False, f"Serial number '{serial_number}' is already in use.", None

    item = InventoryItem(
        item_type_key=item_type_key, name=name, sku=sku, serial_number=serial_number,
        status=status or "active", quantity_value=quantity_value, quantity_unit=quantity_unit,
        custom_fields=json.dumps(custom_fields or {}), barcode_code=_new_barcode(),
    )
    db.session.add(item)
    _audit(actor, "inventory_item_create", target=name, detail=item_type_key)
    db.session.commit()
    return True, f"'{name}' created.", item


def update_item(actor: str, item_id: int, name: str = None, sku: str = None,
                 serial_number: str = None, status: str = None,
                 custom_fields: dict = None, checked_out_by_name: str = None,
                 current_project: str = None) -> tuple:
    item = InventoryItem.query.get(item_id)
    if item is None or item.deleted_at is not None:
        return False, "Unknown item."

    if name is not None:
        name = name.strip()
        if not name:
            return False, "Name is required."
        item.name = name
    if sku is not None:
        sku = sku.strip() or None
        if sku and InventoryItem.query.filter(InventoryItem.sku == sku, InventoryItem.id != item.id).first():
            return False, f"SKU '{sku}' is already in use."
        item.sku = sku
    if serial_number is not None:
        serial_number = serial_number.strip() or None
        if serial_number and InventoryItem.query.filter(
            InventoryItem.serial_number == serial_number, InventoryItem.id != item.id
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

    _audit(actor, "inventory_item_update", target=item.name)
    db.session.commit()
    return True, f"'{item.name}' updated."


def delete_item(actor: str, item_id: int) -> tuple:
    from datetime import datetime
    item = InventoryItem.query.get(item_id)
    if item is None or item.deleted_at is not None:
        return False, "Unknown item."
    item.deleted_at = datetime.utcnow()
    _audit(actor, "inventory_item_delete", target=item.name)
    db.session.commit()
    return True, f"'{item.name}' deleted."


def change_measurement(actor: str, item_id: int, new_unit: str) -> tuple:
    """Converts quantity_value into new_unit if it's the same measurement
    kind as the item's current unit; if new_unit is a different kind, the
    raw value is kept as-is rather than deleted/zeroed — changing units
    never silently destroys data, it just may stop being directly
    comparable until someone corrects it."""
    item = InventoryItem.query.get(item_id)
    if item is None or item.deleted_at is not None:
        return False, "Unknown item."
    old_unit = item.quantity_unit
    if item.quantity_value is not None and old_unit:
        converted = measurement.convert(item.quantity_value, old_unit, new_unit)
        if converted is not None:
            item.quantity_value = converted
            item.quantity_unit = new_unit
            _audit(actor, "inventory_item_measurement_change", target=item.name,
                   detail=f"{old_unit} -> {new_unit} (converted)")
            db.session.commit()
            return True, f"Converted from {old_unit} to {new_unit}."
    item.quantity_unit = new_unit
    _audit(actor, "inventory_item_measurement_change", target=item.name,
           detail=f"{old_unit} -> {new_unit} (kept raw value, different kind)")
    db.session.commit()
    return True, f"Unit changed to {new_unit} — existing quantity value kept as-is (different measurement kind)."


def change_type(actor: str, item_id: int, new_type_key: str) -> tuple:
    """Switches item_type_key without touching custom_fields — old values
    for fields the new type doesn't define just become inert (still
    stored, not shown), so switching types never loses data."""
    item = InventoryItem.query.get(item_id)
    if item is None or item.deleted_at is not None:
        return False, "Unknown item."
    new_type = ItemType.query.get(new_type_key)
    if new_type is None:
        return False, "Unknown target type."
    old_type_key = item.item_type_key
    item.item_type_key = new_type_key
    _audit(actor, "inventory_item_type_change", target=item.name, detail=f"{old_type_key} -> {new_type_key}")
    db.session.commit()
    return True, f"'{item.name}' is now a '{new_type.name}'."


def generate_sku(actor: str, item_id: int) -> tuple:
    item = InventoryItem.query.get(item_id)
    if item is None or item.deleted_at is not None:
        return False, "Unknown item."
    item.sku = unique_sku()
    _audit(actor, "inventory_item_sku_generated", target=item.name, detail=item.sku)
    db.session.commit()
    return True, f"New SKU: {item.sku}"


def generate_serial_number(actor: str, item_id: int) -> tuple:
    item = InventoryItem.query.get(item_id)
    if item is None or item.deleted_at is not None:
        return False, "Unknown item."
    item.serial_number = unique_serial_number()
    _audit(actor, "inventory_item_serial_generated", target=item.name, detail=item.serial_number)
    db.session.commit()
    return True, f"New serial number: {item.serial_number}"


EVENT_TYPES = ("issue", "checkin", "scrap", "maintenance_start", "maintenance_end", "note")


def log_event(actor: str, item_id: int, event_type: str, project: str = None, detail: str = None) -> tuple:
    from datetime import datetime
    item = InventoryItem.query.get(item_id)
    if item is None or item.deleted_at is not None:
        return False, "Unknown item."
    if event_type not in EVENT_TYPES:
        return False, f"Unsupported event type '{event_type}'."
    db.session.add(InventoryItemEvent(
        item_id=item.id, event_type=event_type, actor=actor, project=(project or "").strip() or None,
        detail=(detail or "").strip() or None, occurred_at=datetime.utcnow(),
    ))
    if event_type == "issue":
        item.current_project = (project or "").strip() or item.current_project
        item.checked_out_by_name = actor
    elif event_type in ("checkin", "scrap"):
        item.checked_out_by_name = None
        if event_type == "scrap":
            item.status = "scrapped"
    _audit(actor, "inventory_item_event", target=item.name, detail=event_type)
    db.session.commit()
    return True, f"'{event_type}' logged for '{item.name}'."


def bulk_update(actor: str, item_ids: list, status: str = None, quantity_unit: str = None,
                 item_type_key: str = None) -> tuple:
    """Applies the same field change(s) across a selection."""
    items = InventoryItem.query.filter(InventoryItem.id.in_(item_ids), InventoryItem.deleted_at.is_(None)).all()
    if not items:
        return False, "No matching items.", 0
    if item_type_key and ItemType.query.get(item_type_key) is None:
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
    _audit(actor, "inventory_item_bulk_update", detail=f"{count} item(s)")
    db.session.commit()
    return True, f"{count} item(s) updated.", count


def bulk_delete(actor: str, item_ids: list) -> tuple:
    from datetime import datetime
    items = InventoryItem.query.filter(InventoryItem.id.in_(item_ids), InventoryItem.deleted_at.is_(None)).all()
    if not items:
        return False, "No matching items.", 0
    now = datetime.utcnow()
    for item in items:
        item.deleted_at = now
    _audit(actor, "inventory_item_bulk_delete", detail=f"{len(items)} item(s)")
    db.session.commit()
    return True, f"{len(items)} item(s) deleted.", len(items)
