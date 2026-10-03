"""
API for the new Admin Panel (app/templates/admin_panel.html), served at
/ui/admin (see app/ui.py). Every route here matches an exact fetch()
call in that template -- see its <script> block for the client side of
each of these.

Auth: same LocalUser accounts / same Bearer-token session mechanism as
the kiosk screen (app.auth), gated further by app.admin_auth so only
roles with actual Admin Panel permissions can use it. See that module's
docstring for why super_admin is a hardcoded bypass.
"""
from flask import Blueprint, request, jsonify, g, render_template

from app.models import db, LocalUser, RolePermission, Item, Tool, Project, Barcode
from app.auth import create_session
from app.admin_auth import admin_login_required, require_permission, role_has_panel_access
from app.admin_models import (
    AdminRole, AdminPage, AdminPageComponent, CustomFieldDef, KioskPairingToken,
    AdminAuditLogEntry, WeldingWireBatch, PERMISSIONS, COMPONENT_TYPES, ENTITY_MODELS, ENTITY_COLUMNS,
)
from app.codes import unique_prefixed_code
from app.barcode_render import generate_barcode_svg

admin_panel_bp = Blueprint("admin_panel", __name__, url_prefix="/api/admin-panel")


# ── Login / session ──────────────────────────────────────────────────

@admin_panel_bp.route("/login", methods=["POST"])
def login():
    """Same lookup as /api/auth/login (badge code, then username; same
    is_active / RolePermission.login_enabled gates) plus one more check:
    the account's role has to actually have Admin Panel access, or this
    is just the ordinary kiosk login screen with extra steps."""
    data = request.get_json(silent=True) or {}
    raw = (data.get("badge_code") or "").strip()
    if not raw:
        return jsonify({"error": "Scan or enter a badge code, or type a username."}), 400

    user = LocalUser.query.filter_by(badge_code=raw.upper()).first()
    if not user:
        user = LocalUser.query.filter_by(username=raw).first()

    if not user or not user.is_active:
        return jsonify({"error": "Not recognised."}), 401
    if not RolePermission.is_login_enabled(user.role):
        return jsonify({"error": "Logins are currently disabled for your role. Ask an admin."}), 403
    if not role_has_panel_access(user.role):
        return jsonify({"error": "Your role doesn't have Admin Panel access."}), 403

    token = create_session(user)
    AdminAuditLogEntry.log(user.username, "login")
    db.session.commit()
    return jsonify({"token": token, "user": user.to_dict()}), 200


@admin_panel_bp.route("/me", methods=["GET"])
@admin_login_required
def me():
    return jsonify({
        "user_id": g.session["user_id"],
        "username": g.session["username"],
        "role": g.session["role"],
    }), 200


# ── Sidebar ───────────────────────────────────────────────────────────

@admin_panel_bp.route("/sidebar", methods=["GET"])
@admin_login_required
def sidebar():
    role = g.session["role"]
    pages = AdminPage.query.order_by(AdminPage.order.asc()).all()
    visible = [p.to_dict() for p in pages if p.visible_to(role)]
    return jsonify({"pages": visible}), 200


# ── Dashboard ─────────────────────────────────────────────────────────

@admin_panel_bp.route("/dashboard", methods=["GET"])
@admin_login_required
def dashboard():
    return jsonify({
        "item_count": Item.query.count(),
        "tool_count": Tool.query.count(),
        "project_count": Project.query.count(),
        "user_count": LocalUser.query.filter_by(is_active=True).count(),
        "role_count": AdminRole.query.count(),
        "pending_kiosk_tokens": sum(1 for t in KioskPairingToken.query.all() if t.is_valid),
    }), 200


# ── Permission catalog (read-only, used to render the Roles screen) ───

@admin_panel_bp.route("/permissions", methods=["GET"])
@admin_login_required
def permissions_catalog():
    return jsonify({"permissions": PERMISSIONS}), 200


# ── Roles ─────────────────────────────────────────────────────────────

@admin_panel_bp.route("/roles", methods=["GET"])
@admin_login_required
def list_roles():
    roles = AdminRole.query.order_by(AdminRole.id.asc()).all()
    return jsonify({"roles": [r.to_dict() for r in roles]}), 200


@admin_panel_bp.route("/roles", methods=["POST"])
@require_permission("manage_roles")
def create_role():
    data = request.get_json(silent=True) or {}
    name = (data.get("name") or "").strip()
    display_name = (data.get("display_name") or "").strip()
    if not name or not display_name:
        return jsonify({"error": "name and display_name are required."}), 400
    if AdminRole.query.filter_by(name=name).first():
        return jsonify({"error": f"A role named '{name}' already exists."}), 409

    role = AdminRole(name=name, display_name=display_name, is_system=False)
    role.permissions = data.get("permissions") or []
    db.session.add(role)
    AdminAuditLogEntry.log(g.session["username"], "role_create", detail=name)
    db.session.commit()
    return jsonify(role.to_dict()), 201


@admin_panel_bp.route("/roles/<int:role_id>", methods=["PUT"])
@require_permission("manage_roles")
def update_role(role_id):
    role = db.session.get(AdminRole, role_id)
    if not role:
        return jsonify({"error": "Role not found."}), 404
    data = request.get_json(silent=True) or {}
    if "display_name" in data and data["display_name"]:
        role.display_name = data["display_name"]
    if "permissions" in data:
        role.permissions = data["permissions"] or []
    AdminAuditLogEntry.log(g.session["username"], "role_update", detail=role.name)
    db.session.commit()
    return jsonify(role.to_dict()), 200


@admin_panel_bp.route("/roles/<int:role_id>", methods=["DELETE"])
@require_permission("manage_roles")
def delete_role(role_id):
    role = db.session.get(AdminRole, role_id)
    if not role:
        return jsonify({"error": "Role not found."}), 404
    if role.is_system:
        return jsonify({"error": "Default roles can't be deleted."}), 400
    if LocalUser.query.filter_by(role=role.name).count() > 0:
        return jsonify({"error": "Reassign every user off this role before deleting it."}), 400

    name = role.name
    db.session.delete(role)
    AdminAuditLogEntry.log(g.session["username"], "role_delete", detail=name)
    db.session.commit()
    return jsonify({"deleted": True}), 200


# ── Users (role assignment only -- creation/deactivation still lives in
#    the old /api/admin/users, see app/routes_admin.py) ────────────────

@admin_panel_bp.route("/users", methods=["GET"])
@admin_login_required
def list_users():
    users = LocalUser.query.order_by(LocalUser.username.asc()).all()
    return jsonify({"users": [u.to_dict() for u in users]}), 200


@admin_panel_bp.route("/users/<int:user_id>/role", methods=["PUT"])
@require_permission("manage_users")
def update_user_role(user_id):
    user = db.session.get(LocalUser, user_id)
    if not user:
        return jsonify({"error": "User not found."}), 404
    data = request.get_json(silent=True) or {}
    new_role = (data.get("role") or "").strip()
    if not AdminRole.query.filter_by(name=new_role).first():
        return jsonify({"error": f"'{new_role}' isn't a known role."}), 400

    if user.role == "super_admin" and new_role != "super_admin":
        remaining = LocalUser.query.filter(
            LocalUser.role == "super_admin", LocalUser.is_active.is_(True), LocalUser.id != user.id,
        ).count()
        if remaining == 0:
            return jsonify({"error": "Can't demote the last active super_admin."}), 400

    old_role = user.role
    user.role = new_role
    AdminAuditLogEntry.log(g.session["username"], "user_role_change",
                            detail=f"{user.username}: {old_role} -> {new_role}")
    db.session.commit()
    return jsonify(user.to_dict()), 200


# ── Sidebar Builder (pages) ────────────────────────────────────────────

@admin_panel_bp.route("/pages", methods=["GET"])
@admin_login_required
def list_pages():
    pages = AdminPage.query.order_by(AdminPage.order.asc()).all()
    return jsonify({"pages": [p.to_dict() for p in pages]}), 200


@admin_panel_bp.route("/pages", methods=["POST"])
@require_permission("manage_sidebar")
def create_page():
    data = request.get_json(silent=True) or {}
    key = (data.get("key") or "").strip()
    title = (data.get("title") or "").strip()
    if not key or not title:
        return jsonify({"error": "key and title are required."}), 400
    if AdminPage.query.filter_by(key=key).first():
        return jsonify({"error": f"A page with key '{key}' already exists."}), 409

    page = AdminPage(
        key=key, title=title, route=data.get("route"),
        order=data.get("order", 999), is_system=False,
    )
    page.allowed_roles = data.get("allowed_roles")
    db.session.add(page)
    AdminAuditLogEntry.log(g.session["username"], "page_create", detail=key)
    db.session.commit()
    return jsonify(page.to_dict()), 201


@admin_panel_bp.route("/pages/<int:page_id>", methods=["PUT"])
@require_permission("manage_sidebar")
def update_page(page_id):
    page = db.session.get(AdminPage, page_id)
    if not page:
        return jsonify({"error": "Page not found."}), 404
    data = request.get_json(silent=True) or {}
    for field in ("title", "route", "order"):
        if field in data:
            setattr(page, field, data[field])
    if "is_enabled" in data:
        page.is_enabled = bool(data["is_enabled"])
    if "allowed_roles" in data:
        page.allowed_roles = data["allowed_roles"]
    AdminAuditLogEntry.log(g.session["username"], "page_update", detail=page.key)
    db.session.commit()
    return jsonify(page.to_dict()), 200


@admin_panel_bp.route("/pages/<int:page_id>", methods=["DELETE"])
@require_permission("manage_sidebar")
def delete_page(page_id):
    page = db.session.get(AdminPage, page_id)
    if not page:
        return jsonify({"error": "Page not found."}), 404
    if page.is_system:
        return jsonify({"error": "Default pages can't be deleted -- disable them instead."}), 400

    key = page.key
    db.session.delete(page)
    AdminAuditLogEntry.log(g.session["username"], "page_delete", detail=key)
    db.session.commit()
    return jsonify({"deleted": True}), 200


# ── Page Builder (drag-and-drop components on a custom page) ──────────

def _validate_component_config(component_type: str, config: dict) -> str | None:
    """Returns an error string, or None if config is acceptable.
    Whitelists entity_type/columns against ENTITY_MODELS/ENTITY_COLUMNS
    (see admin_models.py) so a data_table/stat_card can never query an
    unlisted column."""
    if component_type not in COMPONENT_TYPES:
        return f"component_type must be one of {COMPONENT_TYPES}."

    if component_type in ("heading", "text"):
        if not (config.get("text") or "").strip():
            return "text is required."

    elif component_type == "stat_card":
        if not (config.get("label") or "").strip():
            return "label is required."
        entity_type = config.get("entity_type")
        if entity_type not in ENTITY_MODELS:
            return f"entity_type must be one of {list(ENTITY_MODELS)}."
        ff = config.get("filter_field")
        if ff and ff not in ENTITY_COLUMNS[entity_type]:
            return f"filter_field must be one of {ENTITY_COLUMNS[entity_type]}."

    elif component_type == "data_table":
        entity_type = config.get("entity_type")
        if entity_type not in ENTITY_MODELS:
            return f"entity_type must be one of {list(ENTITY_MODELS)}."
        cols = config.get("columns") or []
        bad = [c for c in cols if c not in ENTITY_COLUMNS[entity_type]]
        if bad:
            return f"Unknown column(s) for {entity_type}: {bad}. Allowed: {ENTITY_COLUMNS[entity_type]}."

    # divider needs nothing
    return None


def _render_component(comp: AdminPageComponent) -> dict:
    cfg = comp.config
    t = comp.component_type

    if t == "heading":
        return {"id": comp.id, "type": "heading", "text": cfg.get("text", "")}
    if t == "text":
        return {"id": comp.id, "type": "text", "text": cfg.get("text", "")}
    if t == "divider":
        return {"id": comp.id, "type": "divider"}

    if t == "stat_card":
        entity_type = cfg.get("entity_type")
        model = ENTITY_MODELS.get(entity_type)
        value = 0
        if model is not None:
            q = model.query
            ff, fv = cfg.get("filter_field"), cfg.get("filter_value")
            if ff and ff in ENTITY_COLUMNS.get(entity_type, []):
                q = q.filter(getattr(model, ff) == fv)
            value = q.count()
        return {"id": comp.id, "type": "stat_card", "label": cfg.get("label", entity_type), "value": value}

    if t == "data_table":
        entity_type = cfg.get("entity_type")
        model = ENTITY_MODELS.get(entity_type)
        allowed = ENTITY_COLUMNS.get(entity_type, [])
        cols = [c for c in (cfg.get("columns") or allowed) if c in allowed] or allowed
        limit = max(1, min(int(cfg.get("limit") or 25), 200))
        rows = []
        if model is not None:
            for rec in model.query.limit(limit).all():
                rows.append({c: getattr(rec, c) for c in cols})
        return {"id": comp.id, "type": "data_table", "columns": cols, "rows": rows}

    return {"id": comp.id, "type": "unknown"}


@admin_panel_bp.route("/pages/<int:page_id>/components", methods=["GET"])
@admin_login_required
def list_page_components(page_id):
    page = db.session.get(AdminPage, page_id)
    if not page:
        return jsonify({"error": "Page not found."}), 404
    comps = AdminPageComponent.query.filter_by(page_id=page_id).order_by(AdminPageComponent.order.asc()).all()
    return jsonify({"components": [c.to_dict() for c in comps]}), 200


@admin_panel_bp.route("/pages/<int:page_id>/components", methods=["POST"])
@require_permission("manage_sidebar")
def create_page_component(page_id):
    page = db.session.get(AdminPage, page_id)
    if not page:
        return jsonify({"error": "Page not found."}), 404

    data = request.get_json(silent=True) or {}
    component_type = (data.get("component_type") or "").strip()
    config = data.get("config") or {}
    err = _validate_component_config(component_type, config)
    if err:
        return jsonify({"error": err}), 400

    max_order = db.session.query(db.func.max(AdminPageComponent.order)) \
        .filter_by(page_id=page_id).scalar()
    comp = AdminPageComponent(
        page_id=page_id, component_type=component_type,
        order=(max_order + 1) if max_order is not None else 0,
    )
    comp.config = config
    db.session.add(comp)
    AdminAuditLogEntry.log(g.session["username"], "page_component_create", detail=f"{page.key}:{component_type}")
    db.session.commit()
    return jsonify(comp.to_dict()), 201


@admin_panel_bp.route("/pages/<int:page_id>/components/<int:component_id>", methods=["PUT"])
@require_permission("manage_sidebar")
def update_page_component(page_id, component_id):
    comp = AdminPageComponent.query.filter_by(id=component_id, page_id=page_id).first()
    if not comp:
        return jsonify({"error": "Component not found."}), 404

    data = request.get_json(silent=True) or {}
    new_config = data.get("config")
    if new_config is not None:
        err = _validate_component_config(comp.component_type, new_config)
        if err:
            return jsonify({"error": err}), 400
        comp.config = new_config

    AdminAuditLogEntry.log(g.session["username"], "page_component_update", detail=str(component_id))
    db.session.commit()
    return jsonify(comp.to_dict()), 200


@admin_panel_bp.route("/pages/<int:page_id>/components/<int:component_id>", methods=["DELETE"])
@require_permission("manage_sidebar")
def delete_page_component(page_id, component_id):
    comp = AdminPageComponent.query.filter_by(id=component_id, page_id=page_id).first()
    if not comp:
        return jsonify({"error": "Component not found."}), 404

    db.session.delete(comp)
    AdminAuditLogEntry.log(g.session["username"], "page_component_delete", detail=str(component_id))
    db.session.commit()
    return jsonify({"deleted": True}), 200


@admin_panel_bp.route("/pages/<int:page_id>/components/reorder", methods=["PUT"])
@require_permission("manage_sidebar")
def reorder_page_components(page_id):
    """Body: {"order": [component_id, component_id, ...]} in the new
    top-to-bottom order -- this is what the drag-and-drop canvas sends
    after a drop."""
    data = request.get_json(silent=True) or {}
    ordered_ids = data.get("order") or []
    comps = {c.id: c for c in AdminPageComponent.query.filter_by(page_id=page_id).all()}

    if set(ordered_ids) != set(comps.keys()):
        return jsonify({"error": "order must list every component on this page exactly once."}), 400

    for index, comp_id in enumerate(ordered_ids):
        comps[comp_id].order = index

    db.session.commit()
    return jsonify({"reordered": True}), 200


@admin_panel_bp.route("/pages/<int:page_id>/render", methods=["GET"])
@admin_login_required
def render_page(page_id):
    page = db.session.get(AdminPage, page_id)
    if not page:
        return jsonify({"error": "Page not found."}), 404
    comps = AdminPageComponent.query.filter_by(page_id=page_id).order_by(AdminPageComponent.order.asc()).all()
    return jsonify({"page": page.to_dict(), "components": [_render_component(c) for c in comps]}), 200


@admin_panel_bp.route("/page-builder/entity-schema", methods=["GET"])
@admin_login_required
def page_builder_entity_schema():
    """What entity types/columns a data_table or stat_card can be
    pointed at -- lets the builder UI populate its dropdowns from the
    same allowlist the backend enforces, instead of hardcoding it twice."""
    return jsonify({"entities": {k: v for k, v in ENTITY_COLUMNS.items()}}), 200


# ── Custom fields (schema only -- see CustomFieldDef docstring) ───────

@admin_panel_bp.route("/custom-fields", methods=["GET"])
@admin_login_required
def list_custom_fields():
    fields = CustomFieldDef.query.order_by(CustomFieldDef.entity_type.asc(), CustomFieldDef.name.asc()).all()
    return jsonify({"fields": [f.to_dict() for f in fields]}), 200


@admin_panel_bp.route("/custom-fields", methods=["POST"])
@require_permission("manage_custom_fields")
def create_custom_field():
    data = request.get_json(silent=True) or {}
    entity_type = (data.get("entity_type") or "").strip().lower()
    name = (data.get("name") or "").strip()
    label = (data.get("label") or "").strip()
    field_type = (data.get("field_type") or "text").strip().lower()

    if entity_type not in CustomFieldDef.VALID_ENTITY_TYPES:
        return jsonify({"error": f"entity_type must be one of {CustomFieldDef.VALID_ENTITY_TYPES}."}), 400
    if field_type not in CustomFieldDef.VALID_FIELD_TYPES:
        return jsonify({"error": f"field_type must be one of {CustomFieldDef.VALID_FIELD_TYPES}."}), 400
    if not name or not label:
        return jsonify({"error": "name and label are required."}), 400
    if CustomFieldDef.query.filter_by(entity_type=entity_type, name=name).first():
        return jsonify({"error": f"A '{name}' field already exists on {entity_type}."}), 409

    field = CustomFieldDef(
        entity_type=entity_type, name=name, label=label, field_type=field_type,
        required=bool(data.get("required", False)),
    )
    db.session.add(field)
    AdminAuditLogEntry.log(g.session["username"], "custom_field_create", detail=f"{entity_type}.{name}")
    db.session.commit()
    return jsonify(field.to_dict()), 201


@admin_panel_bp.route("/custom-fields/<int:field_id>", methods=["DELETE"])
@require_permission("manage_custom_fields")
def delete_custom_field(field_id):
    field = db.session.get(CustomFieldDef, field_id)
    if not field:
        return jsonify({"error": "Field not found."}), 404

    detail = f"{field.entity_type}.{field.name}"
    db.session.delete(field)
    AdminAuditLogEntry.log(g.session["username"], "custom_field_delete", detail=detail)
    db.session.commit()
    return jsonify({"deleted": True}), 200


# ── Welding Wire (batch barcode generator) ─────────────────────────────
#
# "Add Welding Wire": name + size + wire_code + quantity in, `quantity`
# unique barcodes out, each starting with wire_code. See
# app.admin_models.WeldingWireBatch's docstring for how this differs
# from the existing per-coil weight-tracking system (app.models.WireCoil,
# app/routes_wire.py) -- that one is unaffected by any of this.

_MAX_WIRE_BATCH_QUANTITY = 1000  # sanity ceiling, not a real business limit -- guards against a fat-fingered quantity looping thousands of inserts


@admin_panel_bp.route("/wire-batches", methods=["GET"])
@admin_login_required
def list_wire_batches():
    batches = WeldingWireBatch.query.order_by(WeldingWireBatch.created_at.desc()).all()
    return jsonify({"batches": [b.to_dict() for b in batches]}), 200


@admin_panel_bp.route("/wire-batches/<int:batch_id>", methods=["GET"])
@admin_login_required
def get_wire_batch(batch_id):
    batch = db.session.get(WeldingWireBatch, batch_id)
    if not batch:
        return jsonify({"error": "Batch not found."}), 404
    return jsonify(batch.to_dict(include_barcodes=True)), 200


@admin_panel_bp.route("/wire-batches", methods=["POST"])
@require_permission("manage_welding_wire")
def create_wire_batch():
    data = request.get_json(silent=True) or {}

    unique_name = (data.get("unique_name") or "").strip()
    size = (data.get("size") or "").strip()
    wire_code = (data.get("wire_code") or "").strip().upper()
    quantity_raw = data.get("quantity")

    if not unique_name:
        return jsonify({"error": "unique_name is required."}), 400
    if not size:
        return jsonify({"error": "size is required."}), 400
    if not wire_code:
        return jsonify({"error": "wire_code is required."}), 400
    if len(wire_code) > 16:
        return jsonify({"error": "wire_code must be 16 characters or fewer (it's used as a barcode prefix)."}), 400
    if not all(c.isalnum() or c in "-_" for c in wire_code):
        return jsonify({"error": "wire_code can only contain letters, numbers, - and _."}), 400

    try:
        quantity = int(quantity_raw)
    except (TypeError, ValueError):
        return jsonify({"error": "quantity must be a whole number."}), 400
    if quantity < 1:
        return jsonify({"error": "quantity must be at least 1."}), 400
    if quantity > _MAX_WIRE_BATCH_QUANTITY:
        return jsonify({"error": f"quantity can't exceed {_MAX_WIRE_BATCH_QUANTITY} in one batch."}), 400

    if WeldingWireBatch.query.filter_by(unique_name=unique_name).first():
        return jsonify({"error": f"'{unique_name}' is already in use -- unique_name has to be unique."}), 409

    batch = WeldingWireBatch(
        unique_name=unique_name, size=size, wire_code=wire_code,
        quantity=quantity, created_by=g.session["username"],
    )
    db.session.add(batch)
    db.session.flush()  # populate batch.id for the Barcode rows below

    for _ in range(quantity):
        code = unique_prefixed_code(wire_code)
        db.session.add(Barcode(code=code, entity_type="welding_wire_batch", entity_id=batch.id))

    AdminAuditLogEntry.log(
        g.session["username"], "wire_batch_create",
        detail=f"{unique_name} ({size}, {wire_code}) x{quantity}",
    )
    db.session.commit()
    return jsonify(batch.to_dict(include_barcodes=True)), 201


@admin_panel_bp.route("/wire-batches/<int:batch_id>", methods=["DELETE"])
@require_permission("manage_welding_wire")
def delete_wire_batch(batch_id):
    batch = db.session.get(WeldingWireBatch, batch_id)
    if not batch:
        return jsonify({"error": "Batch not found."}), 404

    Barcode.query.filter_by(entity_type="welding_wire_batch", entity_id=batch.id).delete()
    detail = f"{batch.unique_name} ({batch.wire_code})"
    db.session.delete(batch)
    AdminAuditLogEntry.log(g.session["username"], "wire_batch_delete", detail=detail)
    db.session.commit()
    return jsonify({"deleted": True}), 200


@admin_panel_bp.route("/wire-batches/<int:batch_id>/print", methods=["GET"])
@admin_login_required
def print_wire_batch(batch_id):
    """One printable page with every generated label for this batch --
    distinct from app/routes_barcode_view.py's print_barcode(), which
    only ever renders ONE entity's ONE barcode_code; a wire batch has
    `quantity` of them, so that route doesn't fit here."""
    batch = db.session.get(WeldingWireBatch, batch_id)
    if not batch:
        return jsonify({"error": "Batch not found."}), 404

    codes = (
        Barcode.query
        .filter_by(entity_type="welding_wire_batch", entity_id=batch.id)
        .order_by(Barcode.id.asc())
        .all()
    )
    labels = [{"code": b.code, "svg": generate_barcode_svg(b.code)} for b in codes]
    return render_template(
        "welding_wire_print.html",
        batch=batch.to_dict(),
        labels=labels,
    )


# ── Kiosk pairing tokens ────────────────────────────────────────────────

@admin_panel_bp.route("/kiosk-token/list", methods=["GET"])
@admin_login_required
def list_kiosk_tokens():
    tokens = KioskPairingToken.query.order_by(KioskPairingToken.created_at.desc()).all()
    return jsonify({"tokens": [t.to_dict() for t in tokens]}), 200


@admin_panel_bp.route("/kiosk-token/issue", methods=["POST"])
@require_permission("manage_kiosk_tokens")
def issue_kiosk_token():
    user = db.session.get(LocalUser, g.session["user_id"])
    tok = KioskPairingToken.issue(user)
    AdminAuditLogEntry.log(g.session["username"], "kiosk_token_issue")
    db.session.commit()
    return jsonify(tok.to_dict()), 201


@admin_panel_bp.route("/kiosk-token/<int:token_id>/revoke", methods=["POST"])
@require_permission("manage_kiosk_tokens")
def revoke_kiosk_token(token_id):
    tok = db.session.get(KioskPairingToken, token_id)
    if not tok:
        return jsonify({"error": "Token not found."}), 404
    tok.revoked = True
    AdminAuditLogEntry.log(g.session["username"], "kiosk_token_revoke", detail=str(token_id))
    db.session.commit()
    return jsonify(tok.to_dict()), 200


@admin_panel_bp.route("/kiosk-token/redeem", methods=["POST"])
def redeem_kiosk_token():
    """Not called by admin_panel.html itself (that's a direct badge
    login) -- this is for a future 'Open Admin Panel' link from the main
    kiosk screen that hands off an already-authenticated session without
    asking the user to re-scan their badge. Single-use: redeeming
    revokes the pairing token immediately."""
    data = request.get_json(silent=True) or {}
    raw = (data.get("token") or "").strip()
    if not raw:
        return jsonify({"error": "token is required."}), 400

    tok = KioskPairingToken.query.filter_by(token=raw).first()
    if not tok or not tok.is_valid:
        return jsonify({"error": "That pairing link has expired or was already used."}), 401

    user = db.session.get(LocalUser, tok.issued_by_user_id)
    if not user or not user.is_active or not role_has_panel_access(user.role):
        return jsonify({"error": "That account no longer has Admin Panel access."}), 403

    tok.revoked = True  # single-use
    session_token = create_session(user)
    AdminAuditLogEntry.log(user.username, "kiosk_token_redeem")
    db.session.commit()
    return jsonify({"token": session_token, "user": user.to_dict()}), 200


# ── Audit log ────────────────────────────────────────────────────────

@admin_panel_bp.route("/audit-log", methods=["GET"])
@require_permission("view_audit_log")
def audit_log():
    limit = min(int(request.args.get("limit", 200)), 1000)
    entries = AdminAuditLogEntry.query.order_by(AdminAuditLogEntry.created_at.desc()).limit(limit).all()
    return jsonify({"entries": [e.to_dict() for e in entries]}), 200
