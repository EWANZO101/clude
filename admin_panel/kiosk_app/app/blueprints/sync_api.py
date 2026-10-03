"""Sync API: the local half of the Admin Panel <-> Kiosk App inventory
sync (see the Admin Panel's app/blueprints/agent_api.py equipment/local-
user sync endpoints, and the Instance Agent's agent/inventory_sync.py,
which is the only thing that ever calls this — never a browser, and
never the Admin Panel directly, which has no network path to a kiosk
machine at all).

Deliberately unauthenticated, same trust model as the /health route in
app/__init__.py: this process binds to 127.0.0.1 only (see run.py), so
only another process on this exact machine — in practice, only the
Agent — can ever reach it.

Conflict resolution is last-write-wins by `updated_at`, decided
independently for each incoming row — this endpoint never needs to know
what the Admin Panel's own side of the sync looks like, it just refuses
to let older incoming data overwrite something newer already on file.
Deletion is a tombstone (Item.deleted_at / Tool.deleted_at) for those two,
never a hard delete, so a removal can still reach the other side before
it's safe to actually forget; LocalUser has no delete concept in this app
at all (see admin.py) so an incoming tombstone just deactivates one here.
"""
import json
import os
import re
from datetime import datetime

from flask import Blueprint, request, jsonify

from app.extensions import db
from app.models import (
    Item, Tool, LocalUser, Barcode, gen_item_barcode, gen_tool_barcode,
    ItemType, ItemTypeField, InventoryItem, NavEntry, gen_inventory_barcode,
)
from app import role_admin, nav_admin, item_type_admin

bp = Blueprint("sync_api", __name__, url_prefix="/api/sync")

TOOL_STATUSES = ("available", "checked_out", "maintenance")


def _parse_dt(value):
    if not value:
        return None
    try:
        return datetime.fromisoformat(value)
    except (ValueError, TypeError):
        return None


def _is_incoming_newer(incoming_dt, existing_dt) -> bool:
    if incoming_dt is None:
        return False
    if existing_dt is None:
        return True
    return incoming_dt > existing_dt


@bp.route("/state", methods=["GET"])
def state():
    return jsonify({
        "items": [i.to_sync_dict() for i in Item.query.all()],
        "tools": [t.to_sync_dict() for t in Tool.query.all()],
        "local_users": [u.to_sync_dict() for u in LocalUser.query.all()],
        # Track 2 Phase B (generic inventory type system) — additive,
        # alongside items/tools above, not replacing them yet. See
        # /root/.claude/plans/sprightly-meandering-whisper.md.
        "item_types": [t.to_sync_dict() for t in ItemType.query.all()],
        "inventory_items": [i.to_sync_dict() for i in InventoryItem.query.all()],
    })


@bp.route("/apply", methods=["POST"])
def apply_sync():
    data = request.get_json(silent=True) or {}
    applied = {"items": 0, "tools": 0, "local_users": 0, "item_types": 0, "inventory_items": 0}

    for payload in (data.get("items") or []):
        if _apply_item(payload):
            applied["items"] += 1
    for payload in (data.get("tools") or []):
        if _apply_tool(payload):
            applied["tools"] += 1
    for payload in (data.get("local_users") or []):
        if _apply_local_user(payload):
            applied["local_users"] += 1
    # item_types must apply before inventory_items — an incoming item can
    # reference a type this side hasn't seen yet.
    for payload in (data.get("item_types") or []):
        if _apply_item_type(payload):
            applied["item_types"] += 1
    for payload in (data.get("inventory_items") or []):
        if _apply_inventory_item(payload):
            applied["inventory_items"] += 1

    db.session.commit()
    return jsonify({"ok": True, "applied": applied})


def _apply_item(payload: dict) -> bool:
    public_id = (payload.get("public_id") or "").strip()
    if not public_id:
        return False
    incoming_updated_at = _parse_dt(payload.get("updated_at"))
    incoming_deleted_at = _parse_dt(payload.get("deleted_at"))

    existing = Item.query.filter_by(public_id=public_id).first()
    if existing is None:
        if incoming_deleted_at is not None:
            return False  # already gone elsewhere — nothing to create
        name = (payload.get("name") or "").strip()
        if not name:
            return False
        barcode_code = gen_item_barcode()
        while Barcode.query.get(barcode_code) is not None:
            barcode_code = gen_item_barcode()
        existing = Item(public_id=public_id, name=name, barcode_code=barcode_code)
        db.session.add(existing)
        db.session.flush()  # need existing.id for the Barcode row below
        db.session.add(Barcode(code=barcode_code, entity_type="item", entity_id=existing.id))
    elif not _is_incoming_newer(incoming_updated_at, existing.updated_at):
        return False  # what we already have is at least as new

    existing.name = (payload.get("name") or existing.name or "").strip() or existing.name
    existing.description = payload.get("description")
    existing.sku = payload.get("sku")
    quantity = payload.get("quantity")
    if quantity is not None:
        try:
            existing.quantity = max(0, int(quantity))  # never negative, matches Item.adjust_stock's own rule
        except (TypeError, ValueError):
            pass
    existing.unit = payload.get("unit")
    existing.category = payload.get("category")
    existing.unit_cost = payload.get("unit_cost")
    # barcode_code is never set from an incoming payload — this app always
    # originates it (Item.barcode_code's own default), synced UP to the
    # Admin Panel for display, never down.
    existing.deleted_at = incoming_deleted_at
    if incoming_updated_at is not None:
        existing.updated_at = incoming_updated_at
    return True


def _apply_tool(payload: dict) -> bool:
    public_id = (payload.get("public_id") or "").strip()
    if not public_id:
        return False
    incoming_updated_at = _parse_dt(payload.get("updated_at"))
    incoming_deleted_at = _parse_dt(payload.get("deleted_at"))

    existing = Tool.query.filter_by(public_id=public_id).first()
    if existing is None:
        if incoming_deleted_at is not None:
            return False
        name = (payload.get("name") or "").strip()
        if not name:
            return False
        barcode_code = gen_tool_barcode()
        while Barcode.query.get(barcode_code) is not None:
            barcode_code = gen_tool_barcode()
        existing = Tool(public_id=public_id, name=name, barcode_code=barcode_code)
        db.session.add(existing)
        db.session.flush()  # need existing.id for the Barcode row below
        db.session.add(Barcode(code=barcode_code, entity_type="tool", entity_id=existing.id))
    elif not _is_incoming_newer(incoming_updated_at, existing.updated_at):
        return False

    existing.name = (payload.get("name") or existing.name or "").strip() or existing.name
    existing.description = payload.get("description")
    tool_status = payload.get("tool_status")
    if tool_status in TOOL_STATUSES:
        existing.status = tool_status
    existing.checked_out_by_name = payload.get("checked_out_by_name")
    existing.current_project = payload.get("current_project")
    existing.category = payload.get("category")
    existing.purchase_price = payload.get("purchase_price")
    existing.deleted_at = incoming_deleted_at
    if incoming_updated_at is not None:
        existing.updated_at = incoming_updated_at
    return True


# ---------------------------------------------------------------------------
# Track 2 Phase B — generic inventory type system sync (see
# /root/.claude/plans/sprightly-meandering-whisper.md). Unlike Item/Tool,
# type/field *definitions* can be created/edited from either side (the
# Admin Panel/Client Portal's type manager, or this terminal's own — both
# land in Phase C), so item_types is bidirectional last-write-wins, same
# as inventory_items itself. Not read by any route/template yet.
# ---------------------------------------------------------------------------

def _apply_item_type(payload: dict) -> bool:
    key = (payload.get("key") or "").strip()
    if not key:
        return False
    incoming_updated_at = _parse_dt(payload.get("updated_at"))
    incoming_deleted_at = _parse_dt(payload.get("deleted_at"))

    existing = ItemType.query.get(key)
    is_new = existing is None
    if existing is None:
        if incoming_deleted_at is not None:
            return False
        name = (payload.get("name") or "").strip()
        if not name:
            return False
        existing = ItemType(key=key, name=name)
        db.session.add(existing)
        db.session.flush()
    elif not _is_incoming_newer(incoming_updated_at, existing.updated_at):
        return False
    elif existing.is_builtin:
        return False  # built-in types can't be renamed/deleted by an incoming sync either

    existing.name = (payload.get("name") or existing.name or "").strip() or existing.name
    existing.description = payload.get("description")
    existing.deleted_at = incoming_deleted_at
    if incoming_updated_at is not None:
        existing.updated_at = incoming_updated_at

    # Sidebar builder: a type created remotely (Admin Panel/Client Portal)
    # gets the exact same auto NavEntry a locally-created one does — see
    # item_type_admin.ensure_nav_entry_for_type.
    if incoming_deleted_at is None:
        if is_new:
            item_type_admin.ensure_nav_entry_for_type(existing)
        else:
            nav_row = NavEntry.query.get(f"type:{key}")
            if nav_row is not None:
                nav_row.label = existing.name
                nav_row.section = existing.name
    else:
        nav_row = NavEntry.query.get(f"type:{key}")
        if nav_row is not None:
            db.session.delete(nav_row)

    # Fields are replaced wholesale from the incoming list — simpler than
    # per-field merge logic, and safe because this row just won the
    # last-write-wins check above for the type as a whole.
    if incoming_deleted_at is None:
        ItemTypeField.query.filter_by(item_type_key=key).delete()
        for f in (payload.get("fields") or []):
            f_key = (f.get("key") or "").strip()
            if not f_key:
                continue
            db.session.add(ItemTypeField(
                item_type_key=key, key=f_key, label=f.get("label") or f_key,
                field_type=f.get("field_type") or "text",
                options_json=json.dumps(f.get("options") or []),
                required=bool(f.get("required")), sort_order=int(f.get("sort_order") or 0),
            ))
    return True


def _apply_inventory_item(payload: dict) -> bool:
    public_id = (payload.get("public_id") or "").strip()
    if not public_id:
        return False
    incoming_updated_at = _parse_dt(payload.get("updated_at"))
    incoming_deleted_at = _parse_dt(payload.get("deleted_at"))

    existing = InventoryItem.query.filter_by(public_id=public_id).first()
    if existing is None:
        if incoming_deleted_at is not None:
            return False
        name = (payload.get("name") or "").strip()
        item_type_key = (payload.get("item_type_key") or "").strip()
        if not name or not item_type_key or ItemType.query.get(item_type_key) is None:
            return False
        barcode_code = gen_inventory_barcode()
        while Barcode.query.get(barcode_code) is not None:
            barcode_code = gen_inventory_barcode()
        existing = InventoryItem(public_id=public_id, name=name, item_type_key=item_type_key, barcode_code=barcode_code)
        db.session.add(existing)
        db.session.flush()
        db.session.add(Barcode(code=barcode_code, entity_type="inventory_item", entity_id=existing.id))
    elif not _is_incoming_newer(incoming_updated_at, existing.updated_at):
        return False

    existing.name = (payload.get("name") or existing.name or "").strip() or existing.name
    if payload.get("item_type_key"):
        existing.item_type_key = payload["item_type_key"]
    existing.sku = payload.get("sku")
    existing.serial_number = payload.get("serial_number")
    status = payload.get("status")
    if status:
        existing.status = status
    existing.quantity_value = payload.get("quantity_value")
    existing.quantity_unit = payload.get("quantity_unit")
    existing.custom_fields = json.dumps(payload.get("custom_fields") or {})
    existing.checked_out_by_name = payload.get("checked_out_by_name")
    existing.current_project = payload.get("current_project")
    existing.deleted_at = incoming_deleted_at
    if incoming_updated_at is not None:
        existing.updated_at = incoming_updated_at
    return True


def _derive_username(name: str) -> str:
    base = re.sub(r"[^a-z0-9]+", "", (name or "user").lower()) or "user"
    username = base
    n = 1
    while LocalUser.query.filter_by(username=username).first() is not None:
        n += 1
        username = f"{base}{n}"
    return username


def _apply_local_user(payload: dict) -> bool:
    public_id = (payload.get("public_id") or "").strip()
    if not public_id:
        return False
    incoming_updated_at = _parse_dt(payload.get("updated_at"))
    incoming_deleted_at = _parse_dt(payload.get("deleted_at"))  # only ever comes from the Admin Panel side

    existing = LocalUser.query.filter_by(public_id=public_id).first()
    if existing is None:
        if incoming_deleted_at is not None:
            return False  # already removed elsewhere — never create just to immediately deactivate
        username = (payload.get("username") or "").strip()
        if username:
            if LocalUser.query.filter_by(username=username).first() is not None:
                return False  # collides with an existing local account — skip rather than clobber it
        else:
            username = _derive_username(payload.get("name"))
        existing = LocalUser(public_id=public_id, username=username)
        db.session.add(existing)
    elif not _is_incoming_newer(incoming_updated_at, existing.updated_at):
        return False
    # username/badge_code are never changed by an incoming payload once a
    # row exists — this app is authoritative for both after creation, same
    # reasoning as Item/Tool.barcode_code above.

    # Permissive accept, not a fixed-list check: roles are user-defined now
    # (see app/role_admin.py) and this side can't validate against the
    # Admin Panel's own live role list without a round trip — same
    # reasoning Item/Tool.category already uses. An incoming role that
    # doesn't exist here yet just sits on the row as a string; the local
    # user list page falls back to showing it plainly rather than crashing
    # on an unrecognized value.
    role = (payload.get("role") or "").strip()
    if role:
        existing.role = role
    status = payload.get("status")
    if status is not None:
        existing.is_active = (status == "active")
    if incoming_deleted_at is not None:
        existing.is_active = False  # this app's own stand-in for "removed" — see LocalUser's own note
    pin_hash = payload.get("pin_hash")
    if pin_hash:
        existing.password_hash = pin_hash
    if incoming_updated_at is not None:
        existing.updated_at = incoming_updated_at
    return True


# ---------------------------------------------------------------------------
# Roles — remote control surface for kiosk_app/app/role_admin.py, so a role
# can be created/edited/deleted from the Client Portal or Admin Panel, not
# only by physically logging into this kiosk's own /admin panel. Called by
# the Instance Agent's agent/commands.py on a "role_*" InstanceCommand, not
# by the continuous inventory_sync.py loop — roles change rarely and are an
# administrative action, so a request/ack model fits better than teaching
# the last-write-wins sync loop to merge role definitions. `actor` in every
# payload is the requesting staff/client email, threaded through purely for
# the audit log entry role_admin.py writes — this endpoint has no session
# of its own to attribute it to otherwise.
# ---------------------------------------------------------------------------

@bp.route("/roles", methods=["GET"])
def list_roles():
    return jsonify({"roles": role_admin.all_roles_state()})


@bp.route("/roles/create", methods=["POST"])
def create_role():
    data = request.get_json(silent=True) or {}
    ok, message = role_admin.create_role(
        data.get("actor") or "remote", data.get("name") or "", data.get("description"),
    )
    return jsonify({"ok": ok, "message": message}), (200 if ok else 400)


@bp.route("/roles/<role_name>/delete", methods=["POST"])
def delete_role(role_name):
    data = request.get_json(silent=True) or {}
    ok, message = role_admin.delete_role(data.get("actor") or "remote", role_name)
    return jsonify({"ok": ok, "message": message}), (200 if ok else 400)


@bp.route("/roles/<role_name>/login", methods=["POST"])
def set_role_login(role_name):
    data = request.get_json(silent=True) or {}
    ok, message = role_admin.set_role_login(data.get("actor") or "remote", role_name, bool(data.get("enabled")))
    return jsonify({"ok": ok, "message": message}), (200 if ok else 400)


@bp.route("/roles/<role_name>/sidebar", methods=["POST"])
def set_role_sidebar(role_name):
    data = request.get_json(silent=True) or {}
    ok, message = role_admin.set_role_sidebar(data.get("actor") or "remote", role_name, data.get("visibility") or {})
    return jsonify({"ok": ok, "message": message}), (200 if ok else 400)


# ---------------------------------------------------------------------------
# Sidebar builder (Track 2's "auto nav entry per custom type + drag-drop
# reorder" — see the plan). NavEntry.sort_order is instance-wide, not
# per-role (per-role *visibility* stays RoleSidebarPermission, unchanged);
# /sidebar is a read-only-cache source for the Admin Panel/Client Portal
# (same pattern as /roles above), /sidebar/reorder is the write path,
# reached either by dragging the list on this terminal's own /admin page
# or relayed here by agent/commands.py's sidebar_reorder command.
# ---------------------------------------------------------------------------

@bp.route("/sidebar", methods=["GET"])
def get_sidebar():
    return jsonify({"nav_entries": nav_admin.get_state()})


@bp.route("/sidebar/reorder", methods=["POST"])
def reorder_sidebar():
    """Body: {"order": ["items", "items_low_stock", "type:consumable", ...]}
    — see nav_admin.reorder() for the exact semantics."""
    data = request.get_json(silent=True) or {}
    order = data.get("order") or []
    if not isinstance(order, list):
        return jsonify({"ok": False, "message": "order must be a list of keys."}), 400
    ok, message = nav_admin.reorder(data.get("actor") or "remote", order)
    return jsonify({"ok": ok, "message": message}), (200 if ok else 400)


# ---------------------------------------------------------------------------
# Backups (see app/backup.py) — only ever called by the Agent's own
# agent/backup_sync.py, when it's handling a 'backup_now' InstanceCommand
# and needs a fresh file to upload to the Admin Panel. The scheduled LOCAL
# daily backup (run.py's background thread) never hits this endpoint at
# all — it calls create_backup_file() directly in-process.
# ---------------------------------------------------------------------------

@bp.route("/backup", methods=["POST"])
def create_backup():
    from flask import send_file
    from app.backup import create_backup_file, prune_local_backups

    try:
        path = create_backup_file()
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)}), 500
    prune_local_backups()
    return send_file(path, as_attachment=True, download_name=os.path.basename(path))


# ---------------------------------------------------------------------------
# Full database reset — only ever called by the Agent's own
# agent/backup_sync.py::run_db_reset, when it's handling a 'db_reset'
# InstanceCommand (see the Admin Panel's
# app/blueprints/instances.py::kiosk_reset_db). Wipes every row out of
# every table (items, tools, local users, projects, wire, audits, ...) but
# leaves the schema itself alone, so no restart of this process is needed
# afterward.
#
# Deliberately does NOT take its own backup here — run_db_reset already
# does that first, over the SAME /backup route above, and uploads it to
# the Admin Panel (so it shows up in the instance's normal backup history
# and is restorable from there) before ever calling this route. A second,
# local-only backup here would just be an untracked duplicate.
# ---------------------------------------------------------------------------

@bp.route("/reset", methods=["POST"])
def reset_db():
    try:
        # db.metadata.sorted_tables is dependency-ordered (parents before
        # children); deleting in reverse avoids foreign-key violations
        # without needing a hand-maintained table list that would silently
        # go stale as new models are added.
        for table in reversed(db.metadata.sorted_tables):
            db.session.execute(table.delete())
        db.session.commit()
    except Exception as e:
        db.session.rollback()
        return jsonify({"ok": False, "error": str(e)}), 500

    return jsonify({"ok": True})
