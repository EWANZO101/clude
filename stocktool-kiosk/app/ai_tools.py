"""
Local Admin AI — controlled tools (Part 1).

Spec section 15: the AI never gets raw DB access. Every fact it can
pull in comes through one of these named, read-only functions, each of
which enforces spec section 9 (the AI inherits the calling user's
permissions -- a kiosk-role user asking about admin-only data gets a
refusal, not the data) itself, rather than trusting the caller to have
already checked.

Write actions (create_page, update_permission, etc. from spec section
15) are deliberately NOT here -- section 7 requires read-only by
default, and there is no Page Builder / Sidebar Builder in this kiosk
codebase to begin with (those are Admin Panel concepts; see
app/ai_knowledge.py's note on scope). Nothing below mutates the DB.
"""
from __future__ import annotations

from app.models import (
    db, Item, Tool, Project, LocalUser, RolePermission, SyncLog,
    ToolCheckoutEvent, WireCoil,
)

ADMIN_ONLY = {"admin"}


class ToolPermissionError(Exception):
    pass


def _require(role: str, allowed: set[str] | None):
    """allowed=None means "any logged-in role". Mirrors app/auth.py's
    permission_required so the AI never has a looser permission model
    than the REST API it's reading through."""
    if allowed is not None and role not in allowed:
        raise ToolPermissionError("You don't have permission to see that.")


def get_kiosk_status(role: str) -> dict:
    _require(role, None)
    return {
        "item_count": Item.query.count(),
        "tool_count": Tool.query.count(),
        "project_count": Project.query.count(),
        "user_count": LocalUser.query.filter_by(is_active=True).count(),
    }


def get_item(role: str, name_or_sku: str) -> dict | None:
    _require(role, None)
    item = (
        Item.query.filter(
            db.or_(Item.name.ilike(f"%{name_or_sku}%"), Item.sku == name_or_sku)
        ).first()
    )
    if not item:
        return None
    return {
        "name": item.name, "sku": item.sku, "quantity": item.quantity,
        "unit": item.unit, "category": item.category,
    }


def get_stock(role: str, low_stock_only: bool = False, limit: int = 20) -> list[dict]:
    _require(role, None)
    q = Item.query
    if low_stock_only:
        q = q.filter(Item.quantity <= 2)  # matches the kiosk's existing "Low Stock" view threshold
    items = q.order_by(Item.quantity.asc()).limit(limit).all()
    return [{"name": i.name, "sku": i.sku, "quantity": i.quantity, "unit": i.unit} for i in items]


def get_tool(role: str, name: str) -> dict | None:
    _require(role, None)
    tool = Tool.query.filter(Tool.name.ilike(f"%{name}%")).first()
    if not tool:
        return None
    last_checkout = (
        ToolCheckoutEvent.query.filter_by(tool_id=tool.id)
        .order_by(ToolCheckoutEvent.id.desc()).first()
    )
    return {
        "name": tool.name,
        "status": getattr(tool, "status", None),
        "last_checkout": last_checkout.to_dict() if last_checkout and hasattr(last_checkout, "to_dict") else None,
    }


def get_wire_coils(role: str, low_stock_only: bool = False, limit: int = 20) -> list[dict]:
    _require(role, None)
    q = WireCoil.query
    coils = q.limit(limit).all()
    out = []
    for c in coils:
        d = c.to_dict() if hasattr(c, "to_dict") else {"id": c.id}
        out.append(d)
    return out


def get_sync_logs(role: str, limit: int = 10) -> list[dict]:
    # Sync/backup status touches this machine's cloud pairing state --
    # kept admin-only rather than assuming it's harmless.
    _require(role, ADMIN_ONLY)
    logs = SyncLog.query.order_by(SyncLog.id.desc()).limit(limit).all()
    return [l.to_dict() if hasattr(l, "to_dict") else {"id": l.id} for l in logs]


def get_user_permissions(role: str, for_role: str | None = None) -> dict:
    _require(role, ADMIN_ONLY)
    roles = [for_role] if for_role else [r[0] for r in db.session.query(LocalUser.role).distinct()]
    return {r: RolePermission.is_login_enabled(r) for r in roles}


# Registry the chat endpoint (routes_ai.py) is allowed to invoke by
# name. Deliberately explicit/closed rather than reflection-based --
# adding a new tool means adding it here on purpose.
# Registry the chat endpoint (routes_ai.py) is allowed to invoke by
# name. Deliberately explicit/closed rather than reflection-based --
# adding a new tool means adding it here on purpose.
TOOLS = {
    "get_kiosk_status": get_kiosk_status,
    "get_item": get_item,
    "get_stock": get_stock,
    "get_tool": get_tool,
    "get_wire_coils": get_wire_coils,
    "get_sync_logs": get_sync_logs,
    "get_user_permissions": get_user_permissions,
}


# ── Write tools (Part 2 — spec section 8, "Optional AI Actions") ──────
#
# Never called directly from chat(). Reached only via an AIProposal
# that an admin has explicitly approved (see routes_ai.py's
# /proposals/<id>/approve) -- section 8's "never silently make
# significant system changes". Each one is intentionally narrow and
# returns a plain dict describing what it did, for AIProposal.result_json.

class ToolWriteError(Exception):
    pass


def adjust_item_stock(role: str, name_or_sku: str, delta: int, reason: str | None = None) -> dict:
    _require(role, ADMIN_ONLY)
    item = Item.query.filter(
        db.or_(Item.name.ilike(f"%{name_or_sku}%"), Item.sku == name_or_sku)
    ).first()
    if not item:
        raise ToolWriteError(f"No item matching '{name_or_sku}'.")
    before = item.quantity
    item.adjust_stock(delta, adjusted_by="Admin AI")
    db.session.commit()
    return {"item": item.name, "quantity_before": before, "quantity_after": item.quantity, "reason": reason}


def set_tool_maintenance(role: str, name: str, maintenance_level: int | None = None) -> dict:
    _require(role, ADMIN_ONLY)
    tool = Tool.query.filter(Tool.name.ilike(f"%{name}%")).first()
    if not tool:
        raise ToolWriteError(f"No tool matching '{name}'.")
    if tool.status == Tool.STATUS_CHECKED_OUT:
        raise ToolWriteError(f"'{tool.name}' is currently checked out -- check it in before flagging maintenance.")
    before = tool.status
    tool.status = Tool.STATUS_MAINTENANCE
    tool.maintenance_level = maintenance_level
    db.session.commit()
    return {"tool": tool.name, "status_before": before, "status_after": tool.status}


def set_role_login_enabled(role: str, target_role: str, enabled: bool) -> dict:
    _require(role, ADMIN_ONLY)
    row = RolePermission.set_login_enabled(target_role, enabled)
    db.session.commit()
    return row.to_dict()


WRITE_TOOLS = {
    "adjust_item_stock": adjust_item_stock,
    "set_tool_maintenance": set_tool_maintenance,
    "set_role_login_enabled": set_role_login_enabled,
}


# ── db_access_level enforcement (Part 5 — closes a gap left since Part 1:
# AISettings.db_access_level was stored but never actually checked) ────
#
# "none"    -- no read tool may run at all.
# "summary" -- only aggregate/count-level tools (no individual item/
#              tool/user rows).
# "detail"  -- everything, same as no restriction (the original Part 1
#              behaviour).
TOOL_DETAIL_LEVEL = {
    "get_kiosk_status": "summary",
    "get_item": "detail",
    "get_stock": "detail",
    "get_tool": "detail",
    "get_wire_coils": "detail",
    "get_sync_logs": "detail",
    "get_user_permissions": "detail",
}

_LEVEL_RANK = {"none": 0, "summary": 1, "detail": 2}


def check_db_access_level(tool_name: str, db_access_level: str) -> None:
    """Raises ToolPermissionError if the configured AISettings.db_access_level
    is too restrictive for this tool. Called by routes_ai.py before
    invoking any read tool, whether from /tool/<name> or from inside chat()."""
    required = TOOL_DETAIL_LEVEL.get(tool_name, "detail")
    if _LEVEL_RANK.get(db_access_level, 0) < _LEVEL_RANK.get(required, 2):
        raise ToolPermissionError(
            f"AI Settings' database access level ('{db_access_level}') doesn't allow "
            f"'{tool_name}' (requires '{required}')."
        )
