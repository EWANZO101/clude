from datetime import datetime, timezone
from flask import Blueprint, request, jsonify, g
from app.extensions import db
from app.models import Item, Tool, Project, Barcode, User
from app.utils.audit import log_action
from app.models.audit_log import AuditAction
from app.utils.install_auth import install_token_required

api_sync_bp = Blueprint("api_sync", __name__, url_prefix="/api/sync")

_PULLABLE = {"items": Item, "tools": Tool, "projects": Project}


def _parse_since(raw):
    if not raw:
        return None
    try:
        dt = datetime.fromisoformat(raw.replace("Z", "+00:00"))
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt
    except ValueError:
        return None


@api_sync_bp.route("/pull", methods=["GET"])
@install_token_required
def pull():
    """
    Incremental pull: returns rows changed since `since` (ISO-8601,
    omit or leave blank for a full first sync) for each requested type.
    Always returns `server_time` — the client should store that as the
    `since` value for its NEXT pull rather than its own clock, so pull
    windows are correct even if the client's clock is off.
    """
    since = _parse_since(request.args.get("since"))
    requested_types = [t.strip() for t in request.args.get("types", "").split(",") if t.strip()] \
        or list(_PULLABLE.keys()) + ["barcodes", "users"]

    result = {}

    for type_name in requested_types:
        if type_name in _PULLABLE:
            model = _PULLABLE[type_name]
            query = model.query
            if since:
                query = query.filter(model.updated_at > since)
            rows = query.order_by(model.updated_at.asc()).limit(500).all()
            result[type_name] = [r.to_dict() for r in rows]

        elif type_name == "barcodes":
            # Barcode rows have no updated_at (they're immutable once
            # created) — a full pull each time is fine given the small,
            # slow-growing size of this table relative to items/tools.
            result["barcodes"] = [b.to_dict() for b in Barcode.query.all()]

        elif type_name == "users":
            # Read-mostly mirror for kiosk badge-login — id, username,
            # role, badge code, active flag only. No password hash, ever.
            users = User.query.filter_by(is_active=True).all()
            result["users"] = [{
                "id": u.id, "username": u.username, "role": u.role,
                "badge_code": u.barcode.code if u.barcode else None,
                "is_active": u.is_active,
            } for u in users]

    g.installation.last_sync_at = datetime.now(timezone.utc)
    db.session.commit()

    return jsonify({
        "server_time": datetime.now(timezone.utc).isoformat(),
        "data": result,
    }), 200


@api_sync_bp.route("/push", methods=["POST"])
@install_token_required
def push():
    """
    Upload offline changes. Each entry needs `server_id` (the cloud row's
    id, learned from a prior pull) and `local_updated_at` (when the
    change was made on the device). Conflict rule: last-write-wins,
    server-side clock is authoritative — if the server row's own
    updated_at is NEWER than the client's local_updated_at, that means
    something else changed it more recently than this offline edit, so
    it's rejected as a conflict rather than silently overwritten.
    """
    data = request.get_json(silent=True) or {}
    results = {"items": [], "tools": [], "barcodes": []}

    for entry in data.get("items", []):
        results["items"].append(_push_item(entry))

    for entry in data.get("tools", []):
        results["tools"].append(_push_tool(entry))

    for entry in data.get("barcodes", []):
        results["barcodes"].append(_push_barcode(entry))

    g.installation.last_sync_at = datetime.now(timezone.utc)
    db.session.commit()

    return jsonify({"server_time": datetime.now(timezone.utc).isoformat(), "results": results}), 200


def _conflict_check(row, local_updated_at_raw):
    local_dt = _parse_since(local_updated_at_raw)
    row_dt = row.updated_at
    if row_dt and row_dt.tzinfo is None:
        row_dt = row_dt.replace(tzinfo=timezone.utc)  # SQLite round-trips naive; app always writes UTC
    if local_dt and row_dt and row_dt > local_dt:
        return True
    return False


def _push_item(entry):
    server_id = entry.get("server_id")
    delta = entry.get("delta")
    item = db.session.get(Item, server_id) if server_id else None
    if not item:
        return {"server_id": server_id, "status": "not_found"}
    if not isinstance(delta, int) or delta == 0:
        return {"server_id": server_id, "status": "error", "message": "delta must be a non-zero integer."}

    if _conflict_check(item, entry.get("local_updated_at")):
        return {"server_id": server_id, "status": "conflict", "current": item.to_dict()}

    item.adjust_stock(delta)
    log_action(AuditAction.ITEM_STOCK_ADJUSTED, "item", item.id, item.name,
               f"Kiosk sync: {delta:+d} ({item.quantity - delta} → {item.quantity})",
               quantity_delta=delta, device="kiosk-sync")
    return {"server_id": server_id, "status": "applied", "current": item.to_dict()}


def _push_tool(entry):
    server_id = entry.get("server_id")
    action = entry.get("action")
    tool = db.session.get(Tool, server_id) if server_id else None
    if not tool:
        return {"server_id": server_id, "status": "not_found"}
    if action not in ("checkout", "checkin"):
        return {"server_id": server_id, "status": "error", "message": "action must be 'checkout' or 'checkin'."}

    if _conflict_check(tool, entry.get("local_updated_at")):
        return {"server_id": server_id, "status": "conflict", "current": tool.to_dict()}

    from app.models import ToolStatus
    if action == "checkout":
        if tool.status == ToolStatus.CHECKED_OUT:
            return {"server_id": server_id, "status": "conflict", "current": tool.to_dict(),
                    "message": "Already checked out server-side."}
        tool.status = ToolStatus.CHECKED_OUT
        tool.checked_out_at = datetime.now(timezone.utc)
    else:
        tool.status = ToolStatus.AVAILABLE
        tool.checked_out_by_id = None
        tool.checked_out_at = None
    tool.updated_at = datetime.now(timezone.utc)

    return {"server_id": server_id, "status": "applied", "current": tool.to_dict()}


def _push_barcode(entry):
    code = (entry.get("code") or "").strip().upper()
    entity_type = entry.get("entity_type")
    server_id = entry.get("server_id")
    if not code or entity_type not in ("item", "tool", "project") or not server_id:
        return {"code": code, "status": "error", "message": "code, entity_type, and server_id are required."}

    if Barcode.query.filter_by(code=code).first():
        return {"code": code, "status": "conflict", "message": "Code already registered."}

    model = {"item": Item, "tool": Tool, "project": Project}[entity_type]
    entity = db.session.get(model, server_id)
    if not entity:
        return {"code": code, "status": "not_found"}

    fk_field = f"{entity_type}_id"
    bc = Barcode(code=code, **{fk_field: entity.id})
    db.session.add(bc)
    return {"code": code, "status": "applied"}
