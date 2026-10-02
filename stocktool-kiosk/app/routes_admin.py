"""
Local admin panel API — full CRUD for items/tools/projects, plus local
user management. Everything here is gated behind role=admin (see
app/auth.py's permission_required).

This intentionally goes further than the original design. app/auth.py
and app/models.py both used to say the kiosk has "no administrative
functionality by design" — full item/tool/project/user management was
meant to live in a future cloud admin app, syncing down to the kiosk.
That cloud app was never built (see README: nothing sets
app.config["SYNC_ENGINE"] yet), which left kiosk admins with no way at
all to add stock or users short of a CLI flag (--create-user) or
hand-editing the SQLite DB directly. This module closes that gap
locally instead of waiting on the cloud piece. Rows created/edited here
still carry the same dirty/server_id bookkeeping columns as everything
else, so a future sync engine can reconcile them like any other local
change -- nothing here is a dead end if that cloud app eventually does
get built.

NOTE: deliberately does NOT reuse main.run_create_user_inprocess for
user creation, even though it does equivalent upsert logic -- that
function calls print() for status messages, which is unsafe here
because these routes typically run inside the headless Windows service
(no console/stdout attached; see run_service()'s own comment in main.py
about exactly this). Everything below returns JSON and never prints.
"""
from flask import Blueprint, request, jsonify
from app.models import db, Item, Tool, Project, Barcode, LocalUser, RolePermission
from app.auth import permission_required
from app.codes import unique_barcode_code, unique_badge_code, unique_sku

admin_bp = Blueprint("admin", __name__, url_prefix="/api/admin")

# Required in the request body to bulk-delete every item and tool --
# a deliberate typed-code confirmation (not just a "are you sure?"
# click) since this has no undo. See purge_items_and_tools() below.
_PURGE_CONFIRM_CODE = "6532"

_VALID_ROLES = ("admin", "supervisor", "stock_user")


# ───────────────────────────── helpers ───────────────────────────────
def _str_or_none(v):
    if v is None:
        return None
    v = str(v).strip()
    return v or None


def _delete_barcodes_for(entity_type: str, entity_id: int):
    Barcode.query.filter_by(entity_type=entity_type, entity_id=entity_id).delete()


def _active_admin_count(exclude_id: int | None = None) -> int:
    q = LocalUser.query.filter_by(role="admin", is_active=True)
    if exclude_id is not None:
        q = q.filter(LocalUser.id != exclude_id)
    return q.count()


def _assign_barcode(entity_type: str, entity_id: int, requested_code):
    """For entity creation. requested_code is whatever the admin typed
    (already run through _str_or_none) -- if blank, auto-generates one.
    Returns (code, error); error is an end-user message, or None on
    success. Caller must have already flushed the entity so entity_id
    is populated, and must NOT commit until checking error is None."""
    code = requested_code
    if code:
        if Barcode.query.filter_by(code=code).first():
            return None, f"Barcode '{code}' is already registered."
    else:
        code = unique_barcode_code()
    db.session.add(Barcode(code=code, entity_type=entity_type, entity_id=entity_id))
    return code, None


def _reassign_barcode(entity_type: str, entity_id: int, current_code, requested_code):
    """For entity edits -- only call this when the admin's PATCH body
    actually included a barcode_code key. requested_code is whatever
    they sent (already _str_or_none'd; blank means "clear it").
    Returns (new_code_or_None, error)."""
    if requested_code == current_code:
        return current_code, None  # unchanged -- nothing to do
    if requested_code:
        existing = Barcode.query.filter_by(code=requested_code).first()
        if existing and not (existing.entity_type == entity_type and existing.entity_id == entity_id):
            return None, f"Barcode '{requested_code}' is already registered."
    Barcode.query.filter_by(entity_type=entity_type, entity_id=entity_id).delete()
    if requested_code:
        db.session.add(Barcode(code=requested_code, entity_type=entity_type, entity_id=entity_id))
    return requested_code, None


# ───────────────────────────── Items ─────────────────────────────────
@admin_bp.route("/items", methods=["POST"])
@permission_required("admin")
def create_item():
    data = request.get_json(silent=True) or {}
    name = _str_or_none(data.get("name"))
    if not name:
        return jsonify({"error": "name is required."}), 400
    try:
        quantity = int(data.get("quantity", 0))
    except (TypeError, ValueError):
        return jsonify({"error": "quantity must be an integer."}), 400
    if quantity < 0:
        return jsonify({"error": "quantity cannot be negative."}), 400

    sku = _str_or_none(data.get("sku"))
    if sku:
        if Item.query.filter_by(sku=sku).first():
            return jsonify({"error": f"SKU '{sku}' is already in use."}), 409
    else:
        sku = unique_sku()

    item = Item(
        name=name,
        sku=sku,
        description=_str_or_none(data.get("description")),
        quantity=quantity,
        unit=_str_or_none(data.get("unit")),
    )
    db.session.add(item)
    db.session.flush()  # populate item.id for the Barcode row below

    code, error = _assign_barcode("item", item.id, _str_or_none(data.get("barcode_code")))
    if error:
        db.session.rollback()
        return jsonify({"error": error}), 409
    item.barcode_code = code

    db.session.commit()
    return jsonify(item.to_dict()), 201


@admin_bp.route("/items/<int:item_id>", methods=["PATCH"])
@permission_required("admin")
def update_item(item_id):
    item = db.session.get(Item, item_id)
    if not item:
        return jsonify({"error": "Item not found."}), 404
    data = request.get_json(silent=True) or {}

    if "name" in data:
        name = _str_or_none(data["name"])
        if not name:
            return jsonify({"error": "name cannot be blank."}), 400
        item.name = name
    if "sku" in data:
        new_sku = _str_or_none(data["sku"])
        if new_sku and new_sku != item.sku:
            existing = Item.query.filter_by(sku=new_sku).first()
            if existing and existing.id != item.id:
                return jsonify({"error": f"SKU '{new_sku}' is already in use."}), 409
        item.sku = new_sku
    if "description" in data:
        item.description = _str_or_none(data["description"])
    if "unit" in data:
        item.unit = _str_or_none(data["unit"])
    if "quantity" in data:
        try:
            quantity = int(data["quantity"])
        except (TypeError, ValueError):
            return jsonify({"error": "quantity must be an integer."}), 400
        if quantity < 0:
            return jsonify({"error": "quantity cannot be negative."}), 400
        item.quantity = quantity
    if "barcode_code" in data:
        new_code, error = _reassign_barcode("item", item.id, item.barcode_code, _str_or_none(data["barcode_code"]))
        if error:
            return jsonify({"error": error}), 409
        item.barcode_code = new_code

    item.dirty = True
    db.session.commit()
    return jsonify(item.to_dict()), 200


@admin_bp.route("/items/<int:item_id>", methods=["DELETE"])
@permission_required("admin")
def delete_item(item_id):
    item = db.session.get(Item, item_id)
    if not item:
        return jsonify({"error": "Item not found."}), 404
    _delete_barcodes_for("item", item_id)
    db.session.delete(item)
    db.session.commit()
    return jsonify({"deleted": True}), 200


# ───────────────────────────── Tools ─────────────────────────────────
@admin_bp.route("/tools", methods=["POST"])
@permission_required("admin")
def create_tool():
    data = request.get_json(silent=True) or {}
    name = _str_or_none(data.get("name"))
    if not name:
        return jsonify({"error": "name is required."}), 400
    status = data.get("status", Tool.STATUS_AVAILABLE)
    if status not in (Tool.STATUS_AVAILABLE, Tool.STATUS_CHECKED_OUT, Tool.STATUS_MAINTENANCE):
        return jsonify({"error": "status must be one of: available, checked_out, maintenance."}), 400

    tool = Tool(
        name=name,
        description=_str_or_none(data.get("description")),
        status=status,
    )
    db.session.add(tool)
    db.session.flush()  # populate tool.id for the Barcode row below

    code, error = _assign_barcode("tool", tool.id, _str_or_none(data.get("barcode_code")))
    if error:
        db.session.rollback()
        return jsonify({"error": error}), 409
    tool.barcode_code = code

    db.session.commit()
    return jsonify(tool.to_dict()), 201


@admin_bp.route("/tools/<int:tool_id>", methods=["PATCH"])
@permission_required("admin")
def update_tool(tool_id):
    tool = db.session.get(Tool, tool_id)
    if not tool:
        return jsonify({"error": "Tool not found."}), 404
    data = request.get_json(silent=True) or {}

    if "name" in data:
        name = _str_or_none(data["name"])
        if not name:
            return jsonify({"error": "name cannot be blank."}), 400
        tool.name = name
    if "description" in data:
        tool.description = _str_or_none(data["description"])
    if "status" in data:
        status = data["status"]
        if status not in (Tool.STATUS_AVAILABLE, Tool.STATUS_CHECKED_OUT, Tool.STATUS_MAINTENANCE):
            return jsonify({"error": "status must be one of: available, checked_out, maintenance."}), 400
        tool.status = status
        if status != Tool.STATUS_CHECKED_OUT:
            tool.checked_out_by_name = None
    if "barcode_code" in data:
        new_code, error = _reassign_barcode("tool", tool.id, tool.barcode_code, _str_or_none(data["barcode_code"]))
        if error:
            return jsonify({"error": error}), 409
        tool.barcode_code = new_code

    tool.dirty = True
    db.session.commit()
    return jsonify(tool.to_dict()), 200


@admin_bp.route("/tools/<int:tool_id>", methods=["DELETE"])
@permission_required("admin")
def delete_tool(tool_id):
    tool = db.session.get(Tool, tool_id)
    if not tool:
        return jsonify({"error": "Tool not found."}), 404
    _delete_barcodes_for("tool", tool_id)
    db.session.delete(tool)
    db.session.commit()
    return jsonify({"deleted": True}), 200


@admin_bp.route("/purge-all-page", methods=["GET"])
@permission_required("admin")
def purge_all_page():
    """Small self-contained admin page (no template dependency) for
    triggering purge_items_and_tools() above. Reachable at
    /api/admin/purge-all-page while logged in as admin."""
    from flask import Response
    html = """<!doctype html>
<html><head><meta charset="utf-8"><title>Delete all items & tools</title>
<style>
body{font-family:system-ui,sans-serif;background:#0f1115;color:#e6e8ec;max-width:480px;margin:60px auto;padding:0 20px;}
h1{font-size:20px;color:#ff6767;}
p{color:#9aa1ac;line-height:1.6;}
input{width:100%;padding:10px 12px;margin:12px 0;border-radius:6px;border:1px solid #2a2e38;background:#0d0f13;color:#e6e8ec;font-size:16px;box-sizing:border-box;}
button{width:100%;padding:10px 18px;border-radius:6px;border:1px solid #ff6767;background:rgba(255,103,103,0.1);color:#ff6767;font-weight:700;font-size:14px;cursor:pointer;}
button:hover{background:#ff6767;color:#fff;}
#result{margin-top:16px;font-size:14px;white-space:pre-wrap;}
</style></head>
<body>
<h1>Delete ALL items and tools</h1>
<p>This permanently deletes every item and every tool (and their barcodes).
Projects and users are not touched. <strong>There is no undo.</strong>
Enter the confirmation code to proceed.</p>
<input type="text" id="code" placeholder="Confirmation code" autocomplete="off">
<button onclick="doPurge()">Delete everything</button>
<div id="result"></div>
<script>
async function doPurge() {
  const code = document.getElementById('code').value.trim();
  const result = document.getElementById('result');
  if (!code) { result.textContent = 'Enter the code first.'; return; }
  result.textContent = 'Working...';
  try {
    const resp = await fetch('/api/admin/items-tools/purge-all', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      credentials: 'same-origin',
      body: JSON.stringify({confirm_code: code})
    });
    const data = await resp.json();
    if (!resp.ok) { result.textContent = 'Error: ' + (data.error || resp.status); return; }
    result.textContent = 'Deleted ' + data.items_deleted + ' item(s) and ' + data.tools_deleted + ' tool(s).';
  } catch (e) {
    result.textContent = 'Request failed: ' + e;
  }
}
</script>
</body></html>"""
    return Response(html, mimetype="text/html")


@admin_bp.route("/items-tools/purge-all", methods=["POST"])
@permission_required("admin")
def purge_items_and_tools():
    """Deletes EVERY item and EVERY tool (and their barcodes) --
    projects, users, and everything else are untouched. Requires the
    confirmation code (_PURGE_CONFIRM_CODE) in the request body, so
    this can never fire from a stray click. No undo -- there is no
    soft-delete/trash for this, only whatever backups exist."""
    data = request.get_json(silent=True) or {}
    code = _str_or_none(data.get("confirm_code"))
    if code != _PURGE_CONFIRM_CODE:
        return jsonify({"error": "Incorrect confirmation code."}), 403

    items_count = Item.query.count()
    tools_count = Tool.query.count()

    Barcode.query.filter_by(entity_type="item").delete()
    Barcode.query.filter_by(entity_type="tool").delete()
    Item.query.delete()
    Tool.query.delete()
    db.session.commit()

    return jsonify({
        "deleted": True,
        "items_deleted": items_count,
        "tools_deleted": tools_count,
    }), 200


# ─────────────────────────── Projects ────────────────────────────────
@admin_bp.route("/projects", methods=["POST"])
@permission_required("admin")
def create_project():
    data = request.get_json(silent=True) or {}
    name = _str_or_none(data.get("name"))
    if not name:
        return jsonify({"error": "name is required."}), 400

    project = Project(
        name=name,
        description=_str_or_none(data.get("description")),
        is_active=bool(data.get("is_active", True)),
    )
    db.session.add(project)
    db.session.flush()  # populate project.id for the Barcode row below

    code, error = _assign_barcode("project", project.id, _str_or_none(data.get("barcode_code")))
    if error:
        db.session.rollback()
        return jsonify({"error": error}), 409
    project.barcode_code = code

    db.session.commit()
    return jsonify(project.to_dict()), 201


@admin_bp.route("/projects/<int:project_id>", methods=["PATCH"])
@permission_required("admin")
def update_project(project_id):
    project = db.session.get(Project, project_id)
    if not project:
        return jsonify({"error": "Project not found."}), 404
    data = request.get_json(silent=True) or {}

    if "name" in data:
        name = _str_or_none(data["name"])
        if not name:
            return jsonify({"error": "name cannot be blank."}), 400
        project.name = name
    if "description" in data:
        project.description = _str_or_none(data["description"])
    if "is_active" in data:
        project.is_active = bool(data["is_active"])
    if "barcode_code" in data:
        new_code, error = _reassign_barcode("project", project.id, project.barcode_code, _str_or_none(data["barcode_code"]))
        if error:
            return jsonify({"error": error}), 409
        project.barcode_code = new_code

    project.dirty = True
    db.session.commit()
    return jsonify(project.to_dict()), 200


@admin_bp.route("/projects/<int:project_id>", methods=["DELETE"])
@permission_required("admin")
def delete_project(project_id):
    project = db.session.get(Project, project_id)
    if not project:
        return jsonify({"error": "Project not found."}), 404
    _delete_barcodes_for("project", project_id)
    db.session.delete(project)
    db.session.commit()
    return jsonify({"deleted": True}), 200


# ───────────────────────────── Users ─────────────────────────────────
@admin_bp.route("/users", methods=["GET"])
@permission_required("admin")
def list_users():
    users = LocalUser.query.order_by(LocalUser.username.asc()).all()
    return jsonify([u.to_dict() for u in users]), 200


@admin_bp.route("/users", methods=["POST"])
@permission_required("admin")
def create_user():
    data = request.get_json(silent=True) or {}
    username = _str_or_none(data.get("username"))
    badge_code = _str_or_none(data.get("badge_code"))
    # Normalized to uppercase to match how the Scan Barcode lookup
    # normalizes scanned/typed codes (app/routes_barcode.py) -- without
    # this, a manually-typed lowercase badge code would be stored as
    # typed and then never match a scan, since SQLite string comparison
    # is case-sensitive. Auto-generated codes (unique_badge_code()) are
    # already always uppercase, so this only affects manual entry.
    if badge_code:
        badge_code = badge_code.upper()
    role = data.get("role", "stock_user")

    if not username:
        return jsonify({"error": "username is required."}), 400
    if role not in _VALID_ROLES:
        return jsonify({"error": f"role must be one of: {', '.join(_VALID_ROLES)}."}), 400
    if LocalUser.query.filter_by(username=username).first():
        return jsonify({"error": f"Username '{username}' is already in use."}), 409
    if badge_code:
        if LocalUser.query.filter_by(badge_code=badge_code).first():
            return jsonify({"error": f"Badge code '{badge_code}' is already in use."}), 409
    else:
        badge_code = unique_badge_code()

    user = LocalUser(username=username, badge_code=badge_code, role=role, is_active=True)
    db.session.add(user)
    db.session.commit()
    return jsonify(user.to_dict()), 201


@admin_bp.route("/users/<int:user_id>", methods=["PATCH"])
@permission_required("admin")
def update_user(user_id):
    user = db.session.get(LocalUser, user_id)
    if not user:
        return jsonify({"error": "User not found."}), 404
    data = request.get_json(silent=True) or {}

    was_active_admin = (user.role == "admin" and user.is_active)
    demoting = "role" in data and data["role"] != "admin"
    deactivating = "is_active" in data and not bool(data["is_active"])
    if was_active_admin and (demoting or deactivating) and _active_admin_count(exclude_id=user.id) == 0:
        return jsonify({"error": "Can't remove the last active admin account."}), 400

    if "username" in data:
        username = _str_or_none(data["username"])
        if not username:
            return jsonify({"error": "username cannot be blank."}), 400
        existing = LocalUser.query.filter_by(username=username).first()
        if existing and existing.id != user.id:
            return jsonify({"error": f"Username '{username}' is already in use."}), 409
        user.username = username
    if "badge_code" in data:
        badge_code = _str_or_none(data["badge_code"])
        if badge_code:
            badge_code = badge_code.upper()  # see create_user()'s comment above
            existing = LocalUser.query.filter_by(badge_code=badge_code).first()
            if existing and existing.id != user.id:
                return jsonify({"error": f"Badge code '{badge_code}' is already in use."}), 409
        user.badge_code = badge_code
    if "role" in data:
        if data["role"] not in _VALID_ROLES:
            return jsonify({"error": f"role must be one of: {', '.join(_VALID_ROLES)}."}), 400
        user.role = data["role"]
    if "is_active" in data:
        user.is_active = bool(data["is_active"])

    db.session.commit()
    return jsonify(user.to_dict()), 200


@admin_bp.route("/users/<int:user_id>", methods=["DELETE"])
@permission_required("admin")
def delete_user(user_id):
    """Hard delete -- deactivating (PATCH is_active=false) is the safer
    everyday choice for offboarding someone; this is for cleaning up a
    genuine duplicate/mistaken entry."""
    user = db.session.get(LocalUser, user_id)
    if not user:
        return jsonify({"error": "User not found."}), 404
    if user.role == "admin" and user.is_active and _active_admin_count(exclude_id=user.id) == 0:
        return jsonify({"error": "Can't remove the last active admin account."}), 400
    db.session.delete(user)
    db.session.commit()
    return jsonify({"deleted": True}), 200


# ─────────────────────── Role permissions (login toggle) ────────────
_ROLES = ("admin", "supervisor", "stock_user")


@admin_bp.route("/role-permissions", methods=["GET"])
@permission_required("admin")
def list_role_permissions():
    return jsonify([
        {"role": role, "login_enabled": RolePermission.is_login_enabled(role)}
        for role in _ROLES
    ]), 200


@admin_bp.route("/role-permissions/<role>", methods=["PATCH"])
@permission_required("admin")
def set_role_permission(role):
    """Per-ROLE login switch (see app/models.py's RolePermission) --
    distinct from a single user's is_active. Refuses to disable the
    admin role outright: unlike disabling stock_user/supervisor (an
    admin can always re-enable those, since admin logins still work),
    disabling admin logins would be a genuine, unrecoverable lockout
    with no other way back in."""
    if role not in _ROLES:
        return jsonify({"error": f"role must be one of: {', '.join(_ROLES)}."}), 400

    data = request.get_json(silent=True) or {}
    if "login_enabled" not in data:
        return jsonify({"error": "login_enabled is required."}), 400
    enabled = bool(data["login_enabled"])

    if role == "admin" and not enabled:
        return jsonify({"error": "Can't disable logins for the admin role -- that would lock everyone out permanently."}), 400

    row = RolePermission.set_login_enabled(role, enabled)
    db.session.commit()
    return jsonify(row.to_dict()), 200
