"""ItemType/ItemTypeField CRUD business logic — the "type manager" half of
the generic inventory system (adapted from kiosk_app/app/item_type_admin.py).
No NavEntry side effects here: the sidebar builds its per-type links
directly from ItemType at render time (see app/__init__.py's context
processor), so there's no separate ordering table to keep in sync.

Every function returns (ok: bool, message: str).
"""
import re

from app.extensions import db
from app.models import ItemType, ItemTypeField, InventoryItem, AuditLogEntry


def _audit(actor: str, action: str, target: str = None, detail: str = None):
    db.session.add(AuditLogEntry(actor=actor, action=action, target=target, detail=detail))


def _slugify(name: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "_", (name or "").strip().lower()).strip("_")
    return slug or "type"


def create_type(actor: str, name: str, description: str = None) -> tuple:
    name = (name or "").strip()
    if not name:
        return False, "Type name is required."
    key = _slugify(name)
    base_key = key
    n = 1
    while ItemType.query.get(key) is not None:
        n += 1
        key = f"{base_key}_{n}"
    db.session.add(ItemType(key=key, name=name, description=(description or "").strip() or None))
    _audit(actor, "item_type_create", target=key)
    db.session.commit()
    return True, f"Type '{name}' created."


def update_type(actor: str, key: str, name: str, description: str = None) -> tuple:
    item_type = ItemType.query.get(key)
    if item_type is None:
        return False, f"Unknown type '{key}'."
    name = (name or "").strip()
    if not name:
        return False, "Type name is required."
    item_type.name = name
    item_type.description = (description or "").strip() or None
    _audit(actor, "item_type_update", target=key)
    db.session.commit()
    return True, f"Type '{name}' updated."


def delete_type(actor: str, key: str) -> tuple:
    from datetime import datetime
    item_type = ItemType.query.get(key)
    if item_type is None:
        return False, f"Unknown type '{key}'."
    if item_type.is_builtin:
        return False, f"'{item_type.name}' is a built-in type and can't be deleted."
    in_use = InventoryItem.query.filter_by(item_type_key=key, deleted_at=None).count()
    if in_use > 0:
        return False, f"'{item_type.name}' still has {in_use} item(s) — reassign or remove them first."
    item_type.deleted_at = datetime.utcnow()  # tombstone, not a hard delete
    _audit(actor, "item_type_delete", target=key)
    db.session.commit()
    return True, f"Type '{item_type.name}' deleted."


FIELD_TYPES = (
    "text", "number", "boolean", "date", "select",
    "measurement", "serial_number", "sku", "custom_unit",
)


def add_field(actor: str, type_key: str, label: str, field_type: str,
              options: list = None, required: bool = False) -> tuple:
    item_type = ItemType.query.get(type_key)
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
    while ItemTypeField.query.filter_by(item_type_key=type_key, key=key).first() is not None:
        n += 1
        key = f"{base_key}_{n}"
    import json
    next_order = (
        db.session.query(db.func.max(ItemTypeField.sort_order))
        .filter_by(item_type_key=type_key).scalar() or -1
    ) + 1
    db.session.add(ItemTypeField(
        item_type_key=type_key, key=key, label=label, field_type=field_type,
        options_json=json.dumps(options or []), required=bool(required), sort_order=next_order,
    ))
    _audit(actor, "item_type_field_add", target=type_key, detail=key)
    db.session.commit()
    return True, f"Field '{label}' added to '{item_type.name}'."


def update_field(actor: str, field_id: int, label: str, field_type: str,
                  options: list = None, required: bool = False) -> tuple:
    field = ItemTypeField.query.get(field_id)
    if field is None:
        return False, "Unknown field."
    label = (label or "").strip()
    if not label:
        return False, "Field label is required."
    if field_type not in FIELD_TYPES:
        return False, f"Unsupported field type '{field_type}'."
    import json
    field.label = label
    field.field_type = field_type
    field.options_json = json.dumps(options or [])
    field.required = bool(required)
    _audit(actor, "item_type_field_update", target=field.item_type_key, detail=field.key)
    db.session.commit()
    return True, f"Field '{label}' updated."


def delete_field(actor: str, field_id: int) -> tuple:
    field = ItemTypeField.query.get(field_id)
    if field is None:
        return False, "Unknown field."
    type_key, field_key = field.item_type_key, field.key
    db.session.delete(field)
    _audit(actor, "item_type_field_delete", target=type_key, detail=field_key)
    db.session.commit()
    return True, f"Field '{field_key}' removed."


def type_state(key: str) -> dict:
    item_type = ItemType.query.get(key)
    if item_type is None:
        return None
    return {
        "key": item_type.key, "name": item_type.name, "description": item_type.description,
        "is_builtin": item_type.is_builtin,
        "item_count": InventoryItem.query.filter_by(item_type_key=key, deleted_at=None).count(),
        "fields": [
            {"id": f.id, "key": f.key, "label": f.label, "field_type": f.field_type,
             "options": f.options(), "required": f.required, "sort_order": f.sort_order}
            for f in item_type.fields
        ],
    }


def all_types_state() -> list:
    return [
        type_state(t.key)
        for t in ItemType.query.filter_by(deleted_at=None).order_by(ItemType.name).all()
    ]
