#!/usr/bin/env bash
#
# deploy_welding_wire_feature.sh -- installs the new "Welding Wire"
# Admin Panel feature (side-menu entry + batch barcode generator) into
# an existing stocktool-kiosk checkout.
#
# What this adds:
#   - Admin Panel sidebar entry "Welding Wire" (between Custom Fields
#     and Kiosk Tokens)
#   - A form: Unique Name, Size, Wire Code, Quantity -> generates that
#     many unique barcodes, each starting with Wire Code
#   - A printable label sheet per batch (all N barcodes on one page)
#   - New DB table welding_wire_batches (auto-created on next startup,
#     no manual migration needed)
#   - New permission "manage_welding_wire", already granted to the
#     admin role for FRESH installs. On an EXISTING install, the admin
#     role row already exists in the DB so the new permission is NOT
#     auto-granted -- after deploying, go to Roles & Permissions in
#     the Admin Panel and tick "Add welding wire & generate barcodes"
#     for whichever role(s) should have it (super_admin always has
#     every permission automatically).
#
# Usage (run from inside ~/stocktool-kiosk, or pass the path):
#   ./deploy_welding_wire_feature.sh
#   ./deploy_welding_wire_feature.sh /root/stocktool-kiosk

set -euo pipefail

TARGET_DIR="${1:-$(pwd)}"

for rel in app/admin_models.py app/routes_admin_panel.py app/codes.py app/templates/admin_panel.html; do
  if [[ ! -f "$TARGET_DIR/$rel" ]]; then
    echo "Couldn't find $rel in $TARGET_DIR" >&2
    echo "Run this from your stocktool-kiosk directory, or pass its path as an argument." >&2
    exit 1
  fi
done

TS="$(date +%Y%m%d%H%M%S)"
BACKUP_DIR="$TARGET_DIR/.welding_wire_deploy_backup_$TS"
mkdir -p "$BACKUP_DIR/app/templates"

for rel in app/admin_models.py app/routes_admin_panel.py app/codes.py app/templates/admin_panel.html; do
  cp "$TARGET_DIR/$rel" "$BACKUP_DIR/$rel"
done
echo "Backed up existing files -> $BACKUP_DIR"

mkdir -p "$(dirname "$TARGET_DIR/app/admin_models.py")"
cat > "$TARGET_DIR/app/admin_models.py" <<'AWW_ADMIN_MODELS'
"""
Admin Panel (Part 1) database models.

Distinct from the pre-existing app/routes_admin.py ("admin" blueprint,
role == "admin" gate) -- these back the NEW /ui/admin single-page app
and its /api/admin-panel/* endpoints. Roles are now first-class,
user-editable rows (AdminRole) instead of the old fixed three-tuple, so
LocalUser.role can hold any name that exists in admin_roles, not just
admin/supervisor/stock_user.

super_admin is a hardcoded bypass (see app/admin_auth.py) rather than a
permissions row that could theoretically be edited down to nothing and
lock every admin out of the panel -- it always has full access
regardless of what's stored in its AdminRole.permissions_json.
"""
import json
import secrets
from datetime import datetime, timedelta, timezone

from app.models import db, LocalUser, Item, Tool, Project, Barcode


def _now():
    return datetime.now(timezone.utc)


# Permission catalog -- key -> human description, shown as checkboxes in
# the Roles & Permissions screen. New permissions gate new admin-panel
# features as they're built (Part 2+); anything not listed here can't be
# granted or checked, so add to this dict alongside any new endpoint that
# needs its own gate.
PERMISSIONS: dict[str, str] = {
    "manage_roles": "Manage roles & permissions",
    "manage_users": "Manage users (role assignment)",
    "manage_sidebar": "Manage sidebar / pages (Sidebar Builder)",
    "manage_custom_fields": "Manage custom field schema",
    "manage_kiosk_tokens": "Issue / revoke kiosk pairing tokens",
    "view_audit_log": "View the audit log",
    "manage_welding_wire": "Add welding wire & generate barcodes",
}

# Seeded once, on first startup after this file is added (see
# app/admin_app.py). Matches the roles named in README_ADMIN_PANEL_PART1.txt.
_DEFAULT_ROLES = [
    # (name, display_name, permissions, is_system)
    ("super_admin", "Super Admin", list(PERMISSIONS.keys()), True),
    ("admin", "Admin", [
        "manage_users", "manage_sidebar", "manage_custom_fields",
        "manage_kiosk_tokens", "view_audit_log", "manage_welding_wire",
    ], True),
    ("supervisor", "Supervisor", ["view_audit_log"], True),
    ("stock_user", "Stock User", [], True),  # no Admin Panel access at all
]

# Seeded page list, matching the BUILT_VIEWS keys wired up in
# app/templates/admin_panel.html. allowed_roles=None means "visible to
# anyone whose role can get into the panel at all"; a non-empty list
# restricts it further on top of that.
_DEFAULT_PAGES = [
    # (key, title, route, order, allowed_roles)
    ("dashboard", "Dashboard", None, 0, None),
    ("roles", "Roles & Permissions", None, 10, None),
    ("users", "Users", None, 20, None),
    ("sidebar-builder", "Sidebar Builder", None, 30, None),
    ("custom-fields", "Custom Fields", None, 40, None),
    ("welding-wire", "Welding Wire", None, 45, None),
    ("kiosk-tokens", "Kiosk Tokens", None, 50, None),
    ("audit-log", "Audit Log", None, 60, None),
    # Page exists per spec item 34 but has no content yet -- hits the
    # frontend's generic placeholder view until a later part builds it.
    ("developer-settings", "Developer Settings", None, 70, ["super_admin"]),
]


class AdminRole(db.Model):
    __tablename__ = "admin_roles"

    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(32), nullable=False, unique=True, index=True)
    display_name = db.Column(db.String(64), nullable=False)
    permissions_json = db.Column(db.Text, nullable=False, default="[]")
    is_system = db.Column(db.Boolean, nullable=False, default=False)
    created_at = db.Column(db.DateTime, default=_now, nullable=False)

    @property
    def permissions(self) -> list[str]:
        try:
            return json.loads(self.permissions_json or "[]")
        except (TypeError, ValueError):
            return []

    @permissions.setter
    def permissions(self, value: list[str]) -> None:
        # Silently drop anything not in the known catalog rather than
        # erroring -- keeps a stale/renamed permission key from bricking
        # a save.
        clean = [p for p in (value or []) if p in PERMISSIONS]
        self.permissions_json = json.dumps(clean)

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "name": self.name,
            "display_name": self.display_name,
            "permissions": self.permissions,
            "is_system": self.is_system,
        }


class AdminPage(db.Model):
    __tablename__ = "admin_pages"

    id = db.Column(db.Integer, primary_key=True)
    key = db.Column(db.String(64), nullable=False, unique=True, index=True)
    title = db.Column(db.String(120), nullable=False)
    route = db.Column(db.String(200), nullable=True)
    order = db.Column(db.Integer, nullable=False, default=999)
    is_enabled = db.Column(db.Boolean, nullable=False, default=True)
    is_system = db.Column(db.Boolean, nullable=False, default=False)
    parent_id = db.Column(db.Integer, db.ForeignKey("admin_pages.id"), nullable=True)
    # JSON list of role names allowed to see this page; None/empty means
    # "everyone who has Admin Panel access at all" (see app/admin_auth.py).
    allowed_roles_json = db.Column(db.Text, nullable=True)
    created_at = db.Column(db.DateTime, default=_now, nullable=False)

    @property
    def allowed_roles(self) -> list[str] | None:
        if not self.allowed_roles_json:
            return None
        try:
            return json.loads(self.allowed_roles_json)
        except (TypeError, ValueError):
            return None

    @allowed_roles.setter
    def allowed_roles(self, value: list[str] | None) -> None:
        self.allowed_roles_json = json.dumps(value) if value else None

    def visible_to(self, role_name: str) -> bool:
        if not self.is_enabled:
            return False
        allowed = self.allowed_roles
        return (not allowed) or role_name == "super_admin" or role_name in allowed

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "key": self.key,
            "title": self.title,
            "route": self.route,
            "order": self.order,
            "is_enabled": self.is_enabled,
            "is_system": self.is_system,
            "parent_id": self.parent_id,
        }


class CustomFieldDef(db.Model):
    """Schema-only for now (Part 1) -- defines what custom fields exist
    per entity type, but nothing renders/stores VALUES on actual
    Item/Tool/Project/Wire records yet (spec section 20, a later part).
    """
    __tablename__ = "admin_custom_field_defs"

    VALID_ENTITY_TYPES = ("item", "tool", "project", "wire", "user")
    VALID_FIELD_TYPES = ("text", "number", "dropdown", "checkbox", "date")

    id = db.Column(db.Integer, primary_key=True)
    entity_type = db.Column(db.String(32), nullable=False, index=True)
    name = db.Column(db.String(64), nullable=False)  # machine key
    label = db.Column(db.String(120), nullable=False)
    field_type = db.Column(db.String(32), nullable=False, default="text")
    required = db.Column(db.Boolean, nullable=False, default=False)
    options_json = db.Column(db.Text, nullable=True)  # for field_type == "dropdown"
    created_at = db.Column(db.DateTime, default=_now, nullable=False)

    __table_args__ = (
        db.UniqueConstraint("entity_type", "name", name="uq_custom_field_entity_name"),
    )

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "entity_type": self.entity_type,
            "name": self.name,
            "label": self.label,
            "field_type": self.field_type,
            "required": self.required,
        }


class WeldingWireBatch(db.Model):
    """One 'Add Welding Wire' submission from the Admin Panel's Welding
    Wire screen: a name + size + wire_code, plus however many identical
    physical items were made at once (quantity). Distinct from
    app.models.WireCoil (which tracks ONE physical spool's live weight
    through checkout/checkin) -- this is purely a batch label generator:
    "print me N barcodes for N rolls of this wire, each one starting
    with the wire code so a glance at a label identifies the product".

    The N generated codes aren't stored as a column here -- each one is
    its own row in the existing Barcode lookup table (entity_type=
    "welding_wire_batch", entity_id=this row's id), the same central
    table items/tools/projects use, so scanning any of them anywhere
    else in the app already resolves back to this batch for free."""
    __tablename__ = "welding_wire_batches"

    id = db.Column(db.Integer, primary_key=True)
    unique_name = db.Column(db.String(200), nullable=False, unique=True)
    size = db.Column(db.String(64), nullable=False)
    wire_code = db.Column(db.String(32), nullable=False)
    quantity = db.Column(db.Integer, nullable=False)
    created_at = db.Column(db.DateTime, default=_now, nullable=False)
    created_by = db.Column(db.String(64), nullable=True)  # username, for the audit trail

    def to_dict(self, include_barcodes: bool = False) -> dict:
        d = {
            "id": self.id,
            "unique_name": self.unique_name,
            "size": self.size,
            "wire_code": self.wire_code,
            "quantity": self.quantity,
            "created_at": self.created_at.isoformat() if self.created_at else None,
            "created_by": self.created_by,
        }
        if include_barcodes:
            codes = (
                Barcode.query
                .filter_by(entity_type="welding_wire_batch", entity_id=self.id)
                .order_by(Barcode.id.asc())
                .all()
            )
            d["barcodes"] = [b.code for b in codes]
        return d


class KioskPairingToken(db.Model):
    """Lets a session already logged into the kiosk open the Admin Panel
    without re-entering a badge code (e.g. a QR/link flow from the main
    kiosk screen). Single-use: redeeming marks it revoked so it can't be
    replayed. 12h expiry regardless of use.
    """
    __tablename__ = "admin_kiosk_pairing_tokens"

    id = db.Column(db.Integer, primary_key=True)
    token = db.Column(db.String(64), nullable=False, unique=True, index=True)
    issued_by_user_id = db.Column(db.Integer, db.ForeignKey("local_users.id"), nullable=False)
    created_at = db.Column(db.DateTime, default=_now, nullable=False)
    expires_at = db.Column(db.DateTime, nullable=False)
    revoked = db.Column(db.Boolean, nullable=False, default=False)

    @staticmethod
    def issue(user: LocalUser) -> "KioskPairingToken":
        tok = KioskPairingToken(
            token=secrets.token_urlsafe(32),
            issued_by_user_id=user.id,
            expires_at=_now() + timedelta(hours=12),
        )
        db.session.add(tok)
        return tok

    @property
    def is_valid(self) -> bool:
        if self.revoked:
            return False
        expires = self.expires_at
        if expires.tzinfo is None:
            expires = expires.replace(tzinfo=timezone.utc)
        return expires > _now()

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "token": self.token,
            "created_at": self.created_at.isoformat() if self.created_at else None,
            "expires_at": self.expires_at.isoformat() if self.expires_at else None,
            "revoked": self.revoked,
            "is_valid": self.is_valid,
        }


# ── Page Builder (drag-and-drop components on a custom AdminPage) ─────
#
# Whitelisted per entity type on purpose: this powers a data_table
# component whose columns/filter field are chosen by whoever has
# manage_sidebar permission and then queried directly against the
# model -- an unwhitelisted column name would let a crafted config
# probe arbitrary columns (or error out revealing schema). Keeping
# both the entity list AND the column list to an explicit allowlist
# means a bad config can only ever be rejected, never silently do
# something unintended.
ENTITY_MODELS = {"item": Item, "tool": Tool, "project": Project}
ENTITY_COLUMNS = {
    "item": ["id", "name", "sku", "quantity", "unit", "category"],
    "tool": ["id", "name", "status", "checked_out_by_name", "current_project"],
    "project": ["id", "name", "is_active"],
}
COMPONENT_TYPES = ("heading", "text", "stat_card", "data_table", "divider")


class AdminPageComponent(db.Model):
    """One block on a custom AdminPage's canvas. order determines
    top-to-bottom position; the Page Builder UI reorders these via
    drag-and-drop, which just PUTs a new order list back.

    config_json's shape depends on component_type -- see
    app/routes_admin_panel.py's _validate_component_config for what
    each type actually accepts; kept as free-form JSON here rather than
    one column per possible field so adding a new component type later
    doesn't need a migration.
    """
    __tablename__ = "admin_page_components"

    id = db.Column(db.Integer, primary_key=True)
    page_id = db.Column(db.Integer, db.ForeignKey("admin_pages.id"), nullable=False, index=True)
    component_type = db.Column(db.String(32), nullable=False)
    config_json = db.Column(db.Text, nullable=False, default="{}")
    order = db.Column(db.Integer, nullable=False, default=0)
    created_at = db.Column(db.DateTime, default=_now, nullable=False)

    @property
    def config(self) -> dict:
        try:
            return json.loads(self.config_json or "{}")
        except (TypeError, ValueError):
            return {}

    @config.setter
    def config(self, value: dict) -> None:
        self.config_json = json.dumps(value or {})

    def to_dict(self) -> dict:
        return {
            "id": self.id, "page_id": self.page_id,
            "component_type": self.component_type,
            "config": self.config, "order": self.order,
        }


class AdminAuditLogEntry(db.Model):
    """Admin-panel-specific action log -- distinct from
    app.models.ActivityEvent (real stock/tool activity) and SyncLog
    (cloud push/pull). This is "who changed something about how the
    kiosk itself is configured/administered.\""""
    __tablename__ = "admin_audit_log"

    id = db.Column(db.Integer, primary_key=True)
    created_at = db.Column(db.DateTime, default=_now, nullable=False)
    actor_username = db.Column(db.String(64), nullable=True)
    action = db.Column(db.String(64), nullable=False)
    detail = db.Column(db.String(500), nullable=True)

    @staticmethod
    def log(actor_username: str | None, action: str, detail: str | None = None) -> None:
        db.session.add(AdminAuditLogEntry(actor_username=actor_username, action=action, detail=detail))

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "created_at": self.created_at.isoformat() if self.created_at else None,
            "actor_username": self.actor_username,
            "action": self.action,
            "detail": self.detail,
        }
AWW_ADMIN_MODELS
echo "Wrote app/admin_models.py"

mkdir -p "$(dirname "$TARGET_DIR/app/routes_admin_panel.py")"
cat > "$TARGET_DIR/app/routes_admin_panel.py" <<'AWW_ROUTES_ADMIN_PANEL'
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
AWW_ROUTES_ADMIN_PANEL
echo "Wrote app/routes_admin_panel.py"

mkdir -p "$(dirname "$TARGET_DIR/app/codes.py")"
cat > "$TARGET_DIR/app/codes.py" <<'AWW_CODES'
"""
Shared code generation for barcodes (items/tools/projects) and badge
codes (users). Factored out so app/routes_admin.py (the web admin
panel) and main.py's run_create_user_inprocess (the CLI path used by
the Setup Wizard and cloud pairing) can't drift out of sync -- both
need the exact same "always guarantee a real code" guarantee, since
badge_code is now the ONLY way to log in (see app/routes_auth.py).
"""
import secrets

from app.models import Barcode, LocalUser, Item

# Kept separate from _CODE_ALPHABET's use elsewhere in this file so a
# prefix code (e.g. a wire_code like "WW001") stays exactly as typed --
# only the random suffix appended to it uses the unambiguous charset.

# Unambiguous charset -- no 0/O/1/I, since these may end up hand-typed
# or printed on a label.
_CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
_CODE_LENGTH = 8
_MAX_GEN_ATTEMPTS = 20


def _random_code(length: int = _CODE_LENGTH) -> str:
    return "".join(secrets.choice(_CODE_ALPHABET) for _ in range(length))


def unique_barcode_code() -> str:
    for _ in range(_MAX_GEN_ATTEMPTS):
        code = _random_code()
        if not Barcode.query.filter_by(code=code).first():
            return code
    raise RuntimeError("Could not generate a unique barcode code -- this should be virtually impossible; check _CODE_ALPHABET/_CODE_LENGTH.")


def unique_badge_code() -> str:
    for _ in range(_MAX_GEN_ATTEMPTS):
        code = _random_code()
        if not LocalUser.query.filter_by(badge_code=code).first():
            return code
    raise RuntimeError("Could not generate a unique badge code -- this should be virtually impossible; check _CODE_ALPHABET/_CODE_LENGTH.")


def unique_prefixed_code(prefix: str, suffix_length: int = 6) -> str:
    """A unique Barcode.code that always starts with `prefix` (e.g. a
    welding-wire batch's wire_code "WW001" -> "WW001-4K7QRT"), used when
    generating a whole batch of labels for the same product where every
    label should be visually identifiable as belonging to that product
    at a glance, not just individually unique like unique_barcode_code().

    Checks uniqueness against the same Barcode table unique_barcode_code()
    does -- these two code families share one global namespace since
    they're both looked up the same way when scanned."""
    for _ in range(_MAX_GEN_ATTEMPTS):
        code = f"{prefix}-{_random_code(suffix_length)}"
        if not Barcode.query.filter_by(code=code).first():
            return code
    raise RuntimeError(f"Could not generate a unique code for prefix {prefix!r} -- this should be virtually impossible; check _CODE_ALPHABET/suffix_length.")


def unique_sku() -> str:
    """Shorter than barcode/badge codes (6 chars, not 8) and prefixed
    so a glance tells a SKU apart from a barcode/badge -- these three
    code families are visually distinct on purpose, since they mean
    different things (a SKU is a catalog identifier admins may already
    have from a supplier; a barcode_code is what a scanner reads)."""
    for _ in range(_MAX_GEN_ATTEMPTS):
        candidate = "SKU-" + _random_code(6)
        if not Item.query.filter_by(sku=candidate).first():
            return candidate
    raise RuntimeError("Could not generate a unique SKU -- this should be virtually impossible; check _CODE_ALPHABET/_CODE_LENGTH.")
AWW_CODES
echo "Wrote app/codes.py"

mkdir -p "$(dirname "$TARGET_DIR/app/templates/admin_panel.html")"
cat > "$TARGET_DIR/app/templates/admin_panel.html" <<'AWW_ADMIN_PANEL_HTML'
<!doctype html>
<html lang="en" class="dark">
<head>
<meta charset="utf-8">
<title>StockTool Kiosk — Admin Panel</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<script src="https://cdn.tailwindcss.com"></script>
<script>
  tailwind.config = { darkMode: 'class' };
</script>
<style>
  .dragging { opacity: 0.4; }
</style>
</head>
<body class="bg-slate-950 text-slate-100 min-h-screen">

<div id="app" class="flex min-h-screen">

  <!-- Sidebar -->
  <aside id="sidebar" class="w-60 shrink-0 bg-slate-900 border-r border-slate-800 hidden md:flex flex-col">
    <div class="px-4 py-4 border-b border-slate-800">
      <div class="text-sm font-semibold">StockTool Kiosk</div>
      <div class="text-xs text-slate-400">Admin Panel</div>
    </div>
    <nav id="nav-list" class="flex-1 overflow-y-auto py-2 text-sm"></nav>
    <div class="px-4 py-3 border-t border-slate-800 text-xs text-slate-400" id="whoami">Not logged in</div>
  </aside>

  <!-- Main -->
  <main class="flex-1 flex flex-col min-w-0">
    <header class="border-b border-slate-800 px-6 py-3 flex items-center justify-between">
      <h1 id="page-title" class="text-base font-semibold">Admin Panel</h1>
      <button id="logout-btn" class="text-xs text-slate-400 hover:text-slate-200 hidden">Log out</button>
    </header>

    <div class="flex-1 overflow-y-auto p-6">

      <!-- LOGIN -->
      <section id="view-login" class="max-w-sm mx-auto mt-16 bg-slate-900 border border-slate-800 rounded-xl p-6">
        <h2 class="text-lg font-semibold mb-1">Log in</h2>
        <p class="text-sm text-slate-400 mb-4">Same badge code or username as the kiosk screen.</p>
        <input id="login-input" type="text" placeholder="Badge code or username"
               class="w-full bg-slate-950 border border-slate-700 rounded-lg px-3 py-2 text-sm mb-3 outline-none focus:border-indigo-500">
        <button id="login-btn" class="w-full bg-indigo-600 hover:bg-indigo-500 rounded-lg py-2 text-sm font-medium">Log in</button>
        <p id="login-error" class="text-xs text-rose-400 mt-3 hidden"></p>
      </section>

      <!-- DASHBOARD -->
      <section id="view-dashboard" class="hidden">
        <div id="dash-grid" class="grid grid-cols-2 md:grid-cols-4 gap-4"></div>
      </section>

      <!-- ROLES -->
      <section id="view-roles" class="hidden max-w-4xl">
        <div class="flex items-center justify-between mb-4">
          <h2 class="text-sm font-semibold text-slate-400 uppercase tracking-wide">Roles &amp; Permissions</h2>
          <button id="new-role-btn" class="bg-indigo-600 hover:bg-indigo-500 text-sm rounded-lg px-3 py-1.5">+ New role</button>
        </div>
        <div id="roles-list" class="space-y-3"></div>
      </section>

      <!-- USERS -->
      <section id="view-users" class="hidden max-w-3xl">
        <h2 class="text-sm font-semibold text-slate-400 uppercase tracking-wide mb-4">Users</h2>
        <table class="w-full text-sm">
          <thead><tr class="text-left text-slate-400 border-b border-slate-800">
            <th class="py-2">Username</th><th>Badge</th><th>Role</th><th>Active</th><th></th>
          </tr></thead>
          <tbody id="users-body"></tbody>
        </table>
      </section>

      <!-- SIDEBAR BUILDER -->
      <section id="view-sidebar-builder" class="hidden max-w-4xl">
        <div class="flex items-center justify-between mb-4">
          <h2 class="text-sm font-semibold text-slate-400 uppercase tracking-wide">Sidebar Builder</h2>
          <button id="new-page-btn" class="bg-indigo-600 hover:bg-indigo-500 text-sm rounded-lg px-3 py-1.5">+ New page</button>
        </div>
        <table class="w-full text-sm">
          <thead><tr class="text-left text-slate-400 border-b border-slate-800">
            <th class="py-2">Order</th><th>Title</th><th>Key</th><th>Route</th><th>Enabled</th><th></th>
          </tr></thead>
          <tbody id="pages-body"></tbody>
        </table>
      </section>

      <!-- PAGE BUILDER (drag-and-drop canvas for a custom page) -->
      <section id="view-page-builder" class="hidden max-w-3xl">
        <div class="flex items-center justify-between mb-1">
          <h2 class="text-sm font-semibold text-slate-400 uppercase tracking-wide" id="builder-page-title">Page Builder</h2>
          <button id="builder-back-btn" class="text-xs text-slate-400 hover:text-slate-200">&larr; Back to Sidebar Builder</button>
        </div>
        <p class="text-xs text-slate-500 mb-4">Drag the ⠿ handle to reorder. Changes save immediately.</p>

        <div id="builder-canvas" class="space-y-2 mb-4"></div>

        <div class="bg-slate-900 border border-slate-800 border-dashed rounded-xl p-4">
          <div class="text-xs font-medium text-slate-400 mb-2">+ Add a component</div>
          <div class="flex flex-wrap gap-2 mb-3">
            <button data-add-type="heading" class="text-xs bg-slate-800 hover:bg-slate-700 rounded-lg px-3 py-1.5">Heading</button>
            <button data-add-type="text" class="text-xs bg-slate-800 hover:bg-slate-700 rounded-lg px-3 py-1.5">Text block</button>
            <button data-add-type="stat_card" class="text-xs bg-slate-800 hover:bg-slate-700 rounded-lg px-3 py-1.5">Stat card</button>
            <button data-add-type="data_table" class="text-xs bg-slate-800 hover:bg-slate-700 rounded-lg px-3 py-1.5">Data table</button>
            <button data-add-type="divider" class="text-xs bg-slate-800 hover:bg-slate-700 rounded-lg px-3 py-1.5">Divider</button>
          </div>
          <div id="builder-add-form"></div>
        </div>
      </section>

      <!-- PAGE RENDER (read-only view of a custom page's built content) -->
      <section id="view-page-render" class="hidden max-w-3xl">
        <div id="page-render-body" class="space-y-4"></div>
      </section>

      <!-- CUSTOM FIELDS -->
      <section id="view-custom-fields" class="hidden max-w-4xl">
        <div class="flex items-center justify-between mb-4">
          <h2 class="text-sm font-semibold text-slate-400 uppercase tracking-wide">Custom Fields</h2>
          <button id="new-field-btn" class="bg-indigo-600 hover:bg-indigo-500 text-sm rounded-lg px-3 py-1.5">+ New field</button>
        </div>
        <table class="w-full text-sm">
          <thead><tr class="text-left text-slate-400 border-b border-slate-800">
            <th class="py-2">Entity</th><th>Name</th><th>Label</th><th>Type</th><th>Required</th><th></th>
          </tr></thead>
          <tbody id="fields-body"></tbody>
        </table>
      </section>

      <!-- WELDING WIRE -->
      <section id="view-welding-wire" class="hidden max-w-4xl">
        <h2 class="text-sm font-semibold text-slate-400 uppercase tracking-wide mb-4">Welding Wire</h2>

        <div class="bg-slate-900 border border-slate-800 rounded-xl p-4 mb-6">
          <div class="text-sm font-medium mb-3">Add Welding Wire</div>
          <div class="grid grid-cols-2 gap-3 mb-3">
            <div>
              <label class="block text-xs text-slate-400 mb-1">Unique Name</label>
              <input id="ww-name" type="text" placeholder="MIG Welding Wire"
                     class="w-full bg-slate-950 border border-slate-700 rounded-lg px-3 py-2 text-sm outline-none focus:border-indigo-500">
            </div>
            <div>
              <label class="block text-xs text-slate-400 mb-1">Size</label>
              <input id="ww-size" type="text" placeholder="0.8 mm"
                     class="w-full bg-slate-950 border border-slate-700 rounded-lg px-3 py-2 text-sm outline-none focus:border-indigo-500">
            </div>
            <div>
              <label class="block text-xs text-slate-400 mb-1">Wire Code</label>
              <input id="ww-code" type="text" placeholder="WW001"
                     class="w-full bg-slate-950 border border-slate-700 rounded-lg px-3 py-2 text-sm outline-none focus:border-indigo-500">
              <p class="text-xs text-slate-500 mt-1">Every generated barcode starts with this.</p>
            </div>
            <div>
              <label class="block text-xs text-slate-400 mb-1">Quantity</label>
              <input id="ww-qty" type="number" min="1" value="10"
                     class="w-full bg-slate-950 border border-slate-700 rounded-lg px-3 py-2 text-sm outline-none focus:border-indigo-500">
            </div>
          </div>
          <button id="ww-submit-btn" class="bg-indigo-600 hover:bg-indigo-500 text-sm rounded-lg px-4 py-2">Generate barcodes</button>
          <p id="ww-error" class="text-xs text-rose-400 mt-2 hidden"></p>
        </div>

        <table class="w-full text-sm">
          <thead><tr class="text-left text-slate-400 border-b border-slate-800">
            <th class="py-2">Unique Name</th><th>Size</th><th>Wire Code</th><th>Barcodes</th><th>Created</th><th></th>
          </tr></thead>
          <tbody id="ww-body"></tbody>
        </table>
      </section>

      <!-- KIOSK TOKENS -->
      <section id="view-kiosk-tokens" class="hidden max-w-3xl">
        <div class="flex items-center justify-between mb-4">
          <h2 class="text-sm font-semibold text-slate-400 uppercase tracking-wide">Kiosk Tokens</h2>
          <button id="new-token-btn" class="bg-indigo-600 hover:bg-indigo-500 text-sm rounded-lg px-3 py-1.5">+ Issue token</button>
        </div>
        <p class="text-xs text-slate-500 mb-4">Valid 12 hours. Lets a session already logged into the kiosk open this Admin Panel without re-entering a badge code.</p>
        <table class="w-full text-sm">
          <thead><tr class="text-left text-slate-400 border-b border-slate-800">
            <th class="py-2">Token</th><th>Issued</th><th>Expires</th><th>Status</th><th></th>
          </tr></thead>
          <tbody id="tokens-body"></tbody>
        </table>
      </section>

      <!-- AUDIT LOG -->
      <section id="view-audit-log" class="hidden max-w-4xl">
        <h2 class="text-sm font-semibold text-slate-400 uppercase tracking-wide mb-4">Audit Log</h2>
        <table class="w-full text-sm">
          <thead><tr class="text-left text-slate-400 border-b border-slate-800">
            <th class="py-2">When</th><th>Actor</th><th>Action</th><th>Detail</th>
          </tr></thead>
          <tbody id="audit-body"></tbody>
        </table>
      </section>

      <!-- PLACEHOLDER (pages not built yet in this part) -->
      <section id="view-placeholder" class="hidden">
        <div class="max-w-md mx-auto mt-16 text-center text-slate-500 text-sm">
          <p id="placeholder-text">This page's schema exists but its screen hasn't been built yet.</p>
        </div>
      </section>

    </div>
  </main>
</div>

<div id="toast" class="fixed bottom-4 right-4 bg-slate-800 border border-slate-700 text-sm px-4 py-2 rounded-lg opacity-0 pointer-events-none transition-opacity"></div>

<script>
const $ = (id) => document.getElementById(id);
let TOKEN = localStorage.getItem("stocktool_admin_token") || "";
let ME = null;
let SIDEBAR_PAGES = [];

function toast(msg) {
  const t = $("toast");
  t.textContent = msg;
  t.classList.remove("opacity-0");
  setTimeout(() => t.classList.add("opacity-0"), 2500);
}

async function api(path, options = {}) {
  const resp = await fetch(path, {
    ...options,
    headers: { "Content-Type": "application/json", "Authorization": `Bearer ${TOKEN}`, ...(options.headers || {}) },
  });
  let body = null;
  try { body = await resp.json(); } catch (e) {}
  if (resp.status === 401) { doLogout(); }
  if (!resp.ok) throw new Error((body && body.error) || `Request failed (${resp.status})`);
  return body;
}

function showView(name) {
  document.querySelectorAll("main section[id^='view-']").forEach(s => s.classList.add("hidden"));
  const el = $(`view-${name}`);
  if (el) el.classList.remove("hidden");
}

function doLogout() {
  TOKEN = ""; ME = null;
  localStorage.removeItem("stocktool_admin_token");
  $("sidebar").classList.add("hidden"); $("sidebar").classList.remove("md:flex");
  $("logout-btn").classList.add("hidden");
  showView("login");
}

// ── Login ──────────────────────────────────────────────────────────
$("login-btn").addEventListener("click", async () => {
  const raw = $("login-input").value.trim();
  $("login-error").classList.add("hidden");
  if (!raw) return;
  try {
    const resp = await fetch("/api/admin-panel/login", {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ badge_code: raw }),
    });
    const body = await resp.json();
    if (!resp.ok) throw new Error(body.error || "Login failed.");
    TOKEN = body.token;
    localStorage.setItem("stocktool_admin_token", TOKEN);
    await afterLogin();
  } catch (e) {
    $("login-error").textContent = e.message;
    $("login-error").classList.remove("hidden");
  }
});
$("login-input").addEventListener("keydown", (e) => { if (e.key === "Enter") $("login-btn").click(); });
$("logout-btn").addEventListener("click", doLogout);

async function afterLogin() {
  ME = await api("/api/admin-panel/me");
  $("whoami").textContent = `${ME.username} — ${ME.role}`;
  $("sidebar").classList.remove("hidden"); $("sidebar").classList.add("md:flex");
  $("logout-btn").classList.remove("hidden");
  await loadSidebar();
  navigateTo(SIDEBAR_PAGES[0] ? SIDEBAR_PAGES[0].key : "dashboard");
}

// ── Sidebar / navigation ─────────────────────────────────────────────
async function loadSidebar() {
  try {
    const r = await fetch("/api/admin-panel/sidebar", { headers: { "Authorization": `Bearer ${TOKEN}` } });
    const body = await r.json();
    SIDEBAR_PAGES = (body.pages || []).filter(p => !p.parent_id);
    const nav = $("nav-list");
    nav.innerHTML = "";
    for (const p of SIDEBAR_PAGES) {
      const a = document.createElement("a");
      a.href = "#"; a.dataset.key = p.key;
      a.className = "block px-4 py-2 text-slate-300 hover:bg-slate-800 hover:text-white cursor-pointer";
      a.textContent = p.title;
      a.addEventListener("click", (e) => { e.preventDefault(); navigateTo(p.key); });
      nav.appendChild(a);
    }
  } catch (e) {
    toast(`Couldn't load sidebar: ${e.message}`);
  }
}

const BUILT_VIEWS = {
  "dashboard": loadDashboard,
  "roles": loadRoles,
  "users": loadUsers,
  "sidebar-builder": loadPages,
  "custom-fields": loadCustomFields,
  "welding-wire": loadWeldingWire,
  "kiosk-tokens": loadTokens,
  "audit-log": loadAuditLog,
};

function navigateTo(key) {
  const page = SIDEBAR_PAGES.find(p => p.key === key);
  $("page-title").textContent = page ? page.title : key;
  if (BUILT_VIEWS[key]) {
    showView(key);
    BUILT_VIEWS[key]();
  } else if (page) {
    // Custom page -- render whatever's been built for it in the Page
    // Builder (empty canvas just shows nothing, not an error).
    showView("page-render");
    loadPageRender(page.id);
  } else {
    showView("placeholder");
    $("placeholder-text").textContent = `"${page ? page.title : key}" exists in the sidebar/page schema but its screen hasn't been built yet.`;
  }
}

// ── Page render (read-only view of a custom page's built content) ────
async function loadPageRender(pageId) {
  try {
    const r = await api(`/api/admin-panel/pages/${pageId}/render`);
    $("page-render-body").innerHTML = r.components.length
      ? r.components.map(renderComponentReadOnly).join("")
      : `<div class="text-sm text-slate-500 mt-8 text-center">Nothing here yet. Add components to this page from Sidebar Builder &rarr; Edit content.</div>`;
  } catch (e) { toast(e.message); }
}

function renderComponentReadOnly(c) {
  if (c.type === "heading") return `<h3 class="text-lg font-semibold">${c.text}</h3>`;
  if (c.type === "text") return `<p class="text-sm text-slate-300">${c.text}</p>`;
  if (c.type === "divider") return `<hr class="border-slate-800">`;
  if (c.type === "stat_card") return `
    <div class="inline-block bg-slate-900 border border-slate-800 rounded-xl p-4 mr-3">
      <div class="text-2xl font-semibold">${c.value}</div>
      <div class="text-xs text-slate-400 mt-1">${c.label}</div>
    </div>`;
  if (c.type === "data_table") return `
    <table class="w-full text-sm">
      <thead><tr class="text-left text-slate-400 border-b border-slate-800">
        ${c.columns.map(col => `<th class="py-2 capitalize">${col.replace(/_/g, " ")}</th>`).join("")}
      </tr></thead>
      <tbody>${c.rows.map(row => `
        <tr class="border-b border-slate-900">${c.columns.map(col => `<td class="py-2">${row[col] ?? ""}</td>`).join("")}</tr>
      `).join("")}</tbody>
    </table>`;
  return "";
}

// ── Dashboard ─────────────────────────────────────────────────────
async function loadDashboard() {
  try {
    const d = await api("/api/admin-panel/dashboard");
    const cards = [
      ["Items", d.item_count], ["Tools", d.tool_count], ["Projects", d.project_count],
      ["Active users", d.user_count], ["Roles", d.role_count], ["Live kiosk tokens", d.pending_kiosk_tokens],
    ];
    $("dash-grid").innerHTML = cards.map(([label, val]) => `
      <div class="bg-slate-900 border border-slate-800 rounded-xl p-4">
        <div class="text-2xl font-semibold">${val}</div>
        <div class="text-xs text-slate-400 mt-1">${label}</div>
      </div>`).join("");
  } catch (e) { toast(e.message); }
}

// ── Roles ─────────────────────────────────────────────────────────
async function loadRoles() {
  try {
    const [rolesResp, permsResp] = await Promise.all([
      api("/api/admin-panel/roles"), api("/api/admin-panel/permissions"),
    ]);
    const catalog = permsResp.permissions;
    const list = $("roles-list");
    list.innerHTML = "";
    for (const role of rolesResp.roles) {
      const card = document.createElement("div");
      card.className = "bg-slate-900 border border-slate-800 rounded-xl p-4";
      const permChecks = Object.entries(catalog).map(([key, desc]) => `
        <label class="flex items-center gap-2 text-xs text-slate-300 py-0.5">
          <input type="checkbox" data-perm="${key}" ${role.permissions.includes(key) ? "checked" : ""} class="rounded bg-slate-950 border-slate-700">
          ${desc}
        </label>`).join("");
      card.innerHTML = `
        <div class="flex items-center justify-between mb-2">
          <div class="font-medium text-sm">${role.display_name} <span class="text-slate-500 text-xs">(${role.name})</span></div>
          ${role.is_system ? '<span class="text-xs text-slate-500">default</span>' :
            `<button class="text-xs text-rose-400 hover:text-rose-300" data-delete-role="${role.id}">Delete</button>`}
        </div>
        <div class="grid grid-cols-2 gap-x-4">${permChecks}</div>
        <button class="mt-3 text-xs bg-slate-800 hover:bg-slate-700 rounded-lg px-3 py-1.5" data-save-role="${role.id}">Save</button>`;
      list.appendChild(card);
    }
    list.querySelectorAll("[data-save-role]").forEach(btn => btn.addEventListener("click", async () => {
      const roleId = btn.dataset.saveRole;
      const card = btn.closest("div.bg-slate-900");
      const permissions = [...card.querySelectorAll("input[data-perm]:checked")].map(i => i.dataset.perm);
      try {
        await api(`/api/admin-panel/roles/${roleId}`, { method: "PUT", body: JSON.stringify({ permissions }) });
        toast("Role saved.");
      } catch (e) { toast(e.message); }
    }));
    list.querySelectorAll("[data-delete-role]").forEach(btn => btn.addEventListener("click", async () => {
      try {
        await api(`/api/admin-panel/roles/${btn.dataset.deleteRole}`, { method: "DELETE" });
        loadRoles();
      } catch (e) { toast(e.message); }
    }));
  } catch (e) { toast(e.message); }
}

$("new-role-btn").addEventListener("click", async () => {
  const displayName = prompt("Role display name (e.g. 'Warehouse Lead'):");
  if (!displayName) return;
  try {
    await api("/api/admin-panel/roles", { method: "POST", body: JSON.stringify({
      name: displayName.toLowerCase().replace(/\s+/g, "_"), display_name: displayName, permissions: [],
    }) });
    loadRoles();
  } catch (e) { toast(e.message); }
});

// ── Users ─────────────────────────────────────────────────────────
async function loadUsers() {
  try {
    const [usersResp, rolesResp] = await Promise.all([api("/api/admin-panel/users"), api("/api/admin-panel/roles")]);
    const roleOptions = rolesResp.roles.map(r => `<option value="${r.name}">${r.display_name}</option>`).join("");
    $("users-body").innerHTML = usersResp.users.map(u => `
      <tr class="border-b border-slate-900">
        <td class="py-2">${u.username}</td><td>${u.badge_code || ""}</td>
        <td><select data-user-role="${u.id}" class="bg-slate-950 border border-slate-700 rounded px-2 py-1 text-xs">${roleOptions}</select></td>
        <td>${u.is_active ? "yes" : "no"}</td>
        <td><button class="text-xs text-indigo-400" data-save-user="${u.id}">Save</button></td>
      </tr>`).join("");
    $("users-body").querySelectorAll("select[data-user-role]").forEach(sel => {
      sel.value = usersResp.users.find(u => u.id == sel.dataset.userRole).role;
    });
    $("users-body").querySelectorAll("[data-save-user]").forEach(btn => btn.addEventListener("click", async () => {
      const sel = document.querySelector(`select[data-user-role="${btn.dataset.saveUser}"]`);
      try {
        await api(`/api/admin-panel/users/${btn.dataset.saveUser}/role`, { method: "PUT", body: JSON.stringify({ role: sel.value }) });
        toast("Role updated.");
      } catch (e) { toast(e.message); }
    }));
  } catch (e) { toast(e.message); }
}

// ── Sidebar Builder (pages) ─────────────────────────────────────────
async function loadPages() {
  try {
    const r = await api("/api/admin-panel/pages");
    $("pages-body").innerHTML = r.pages.map(p => `
      <tr class="border-b border-slate-900">
        <td class="py-2">${p.order}</td><td>${p.title}</td><td class="text-slate-500">${p.key}</td>
        <td class="text-slate-500">${p.route || "—"}</td>
        <td><input type="checkbox" data-toggle-page="${p.id}" ${p.is_enabled ? "checked" : ""} class="rounded bg-slate-950 border-slate-700"></td>
        <td class="whitespace-nowrap">
          <button class="text-xs text-indigo-400 hover:text-indigo-300 mr-2" data-edit-content="${p.id}" data-page-title="${p.title}">Edit content</button>
          ${p.is_system ? "" : `<button class="text-xs text-rose-400" data-delete-page="${p.id}">Delete</button>`}
        </td>
      </tr>`).join("");
    $("pages-body").querySelectorAll("[data-edit-content]").forEach(btn => btn.addEventListener("click", () => {
      openPageBuilder(parseInt(btn.dataset.editContent, 10), btn.dataset.pageTitle);
    }));
    $("pages-body").querySelectorAll("[data-toggle-page]").forEach(cb => cb.addEventListener("change", async () => {
      try {
        await api(`/api/admin-panel/pages/${cb.dataset.togglePage}`, { method: "PUT", body: JSON.stringify({ is_enabled: cb.checked }) });
        toast("Saved."); loadSidebar();
      } catch (e) { toast(e.message); }
    }));
    $("pages-body").querySelectorAll("[data-delete-page]").forEach(btn => btn.addEventListener("click", async () => {
      try { await api(`/api/admin-panel/pages/${btn.dataset.deletePage}`, { method: "DELETE" }); loadPages(); loadSidebar(); }
      catch (e) { toast(e.message); }
    }));
  } catch (e) { toast(e.message); }
}
$("new-page-btn").addEventListener("click", async () => {
  const title = prompt("Page title:");
  if (!title) return;
  try {
    await api("/api/admin-panel/pages", { method: "POST", body: JSON.stringify({
      key: title.toLowerCase().replace(/\s+/g, "-"), title, order: 999,
    }) });
    loadPages(); loadSidebar();
  } catch (e) { toast(e.message); }
});

// ── Custom fields ─────────────────────────────────────────────────
async function loadCustomFields() {
  try {
    const r = await api("/api/admin-panel/custom-fields");
    $("fields-body").innerHTML = r.fields.map(f => `
      <tr class="border-b border-slate-900">
        <td class="py-2">${f.entity_type}</td><td>${f.name}</td><td>${f.label}</td>
        <td class="text-slate-500">${f.field_type}</td><td>${f.required ? "yes" : "no"}</td>
        <td><button class="text-xs text-rose-400" data-delete-field="${f.id}">Delete</button></td>
      </tr>`).join("");
    $("fields-body").querySelectorAll("[data-delete-field]").forEach(btn => btn.addEventListener("click", async () => {
      try { await api(`/api/admin-panel/custom-fields/${btn.dataset.deleteField}`, { method: "DELETE" }); loadCustomFields(); }
      catch (e) { toast(e.message); }
    }));
  } catch (e) { toast(e.message); }
}
$("new-field-btn").addEventListener("click", async () => {
  const entity_type = prompt("Entity (item/tool/project/wire/user):");
  const name = prompt("Field name (machine key, e.g. warranty_expires):");
  const label = prompt("Field label (shown to users):");
  const field_type = prompt("Field type (text/number/dropdown/checkbox/date/...):", "text");
  if (!entity_type || !name || !label || !field_type) return;
  try {
    await api("/api/admin-panel/custom-fields", { method: "POST", body: JSON.stringify({ entity_type, name, label, field_type }) });
    loadCustomFields();
  } catch (e) { toast(e.message); }
});

// ── Welding Wire ─────────────────────────────────────────────────
async function loadWeldingWire() {
  try {
    const r = await api("/api/admin-panel/wire-batches");
    $("ww-body").innerHTML = r.batches.length ? r.batches.map(b => `
      <tr class="border-b border-slate-900">
        <td class="py-2">${b.unique_name}</td><td>${b.size}</td>
        <td class="font-mono text-xs">${b.wire_code}</td>
        <td>${b.quantity}</td>
        <td class="text-slate-500 text-xs">${new Date(b.created_at).toLocaleString()}</td>
        <td class="whitespace-nowrap">
          <a class="text-xs text-indigo-400 hover:text-indigo-300 mr-2" target="_blank"
             href="/api/admin-panel/wire-batches/${b.id}/print">Print labels</a>
          <button class="text-xs text-rose-400" data-delete-batch="${b.id}">Delete</button>
        </td>
      </tr>`).join("") : `<tr><td colspan="6" class="py-6 text-center text-slate-500">No welding wire added yet.</td></tr>`;
    $("ww-body").querySelectorAll("[data-delete-batch]").forEach(btn => btn.addEventListener("click", async () => {
      if (!confirm("Delete this batch and all its generated barcodes?")) return;
      try { await api(`/api/admin-panel/wire-batches/${btn.dataset.deleteBatch}`, { method: "DELETE" }); loadWeldingWire(); }
      catch (e) { toast(e.message); }
    }));
  } catch (e) { toast(e.message); }
}

$("ww-submit-btn").addEventListener("click", async () => {
  $("ww-error").classList.add("hidden");
  const unique_name = $("ww-name").value.trim();
  const size = $("ww-size").value.trim();
  const wire_code = $("ww-code").value.trim();
  const quantity = parseInt($("ww-qty").value, 10);
  try {
    await api("/api/admin-panel/wire-batches", {
      method: "POST", body: JSON.stringify({ unique_name, size, wire_code, quantity }),
    });
    $("ww-name").value = ""; $("ww-size").value = ""; $("ww-code").value = ""; $("ww-qty").value = "10";
    toast("Barcodes generated.");
    loadWeldingWire();
  } catch (e) {
    $("ww-error").textContent = e.message;
    $("ww-error").classList.remove("hidden");
  }
});

// ── Kiosk tokens ─────────────────────────────────────────────────
async function loadTokens() {
  try {
    const r = await api("/api/admin-panel/kiosk-token/list");
    $("tokens-body").innerHTML = r.tokens.map(t => `
      <tr class="border-b border-slate-900">
        <td class="py-2 font-mono text-xs">${t.token.slice(0, 12)}…</td>
        <td class="text-slate-500 text-xs">${new Date(t.created_at).toLocaleString()}</td>
        <td class="text-slate-500 text-xs">${new Date(t.expires_at).toLocaleString()}</td>
        <td>${t.revoked ? '<span class="text-rose-400">revoked</span>' : (t.is_valid ? '<span class="text-emerald-400">valid</span>' : '<span class="text-slate-500">expired</span>')}</td>
        <td>${(!t.revoked && t.is_valid) ? `<button class="text-xs text-rose-400" data-revoke-token="${t.id}">Revoke</button>` : ""}</td>
      </tr>`).join("");
    $("tokens-body").querySelectorAll("[data-revoke-token]").forEach(btn => btn.addEventListener("click", async () => {
      try { await api(`/api/admin-panel/kiosk-token/${btn.dataset.revokeToken}/revoke`, { method: "POST" }); loadTokens(); }
      catch (e) { toast(e.message); }
    }));
  } catch (e) { toast(e.message); }
}
$("new-token-btn").addEventListener("click", async () => {
  try {
    const r = await api("/api/admin-panel/kiosk-token/issue", { method: "POST" });
    prompt("New token (copy it now):", r.token);
    loadTokens();
  } catch (e) { toast(e.message); }
});

// ── Audit log ───────────────────────────────────────────────────
async function loadAuditLog() {
  try {
    const r = await api("/api/admin-panel/audit-log");
    $("audit-body").innerHTML = r.entries.map(e => `
      <tr class="border-b border-slate-900">
        <td class="py-2 text-slate-500 text-xs">${new Date(e.created_at).toLocaleString()}</td>
        <td>${e.actor_username || "—"}</td><td class="font-mono text-xs">${e.action}</td>
        <td class="text-slate-500 text-xs">${e.detail || ""}</td>
      </tr>`).join("");
  } catch (e) { toast(e.message); }
}

// ── Page Builder (drag-and-drop canvas for a custom page) ────────────
let BUILDER_PAGE_ID = null;
let ENTITY_SCHEMA = null;
let CANVAS_DND_INIT = false;

function openPageBuilder(pageId, title) {
  BUILDER_PAGE_ID = pageId;
  $("page-title").textContent = "Page Builder";
  $("builder-page-title").textContent = `Page Builder — ${title}`;
  $("builder-add-form").innerHTML = "";
  showView("page-builder");
  loadBuilderCanvas();
}
$("builder-back-btn").addEventListener("click", () => { showView("sidebar-builder"); loadPages(); });

async function getEntitySchema() {
  if (!ENTITY_SCHEMA) ENTITY_SCHEMA = (await api("/api/admin-panel/page-builder/entity-schema")).entities;
  return ENTITY_SCHEMA;
}

async function loadBuilderCanvas() {
  try {
    const r = await api(`/api/admin-panel/pages/${BUILDER_PAGE_ID}/components`);
    renderBuilderCanvas(r.components);
  } catch (e) { toast(e.message); }
}

function summarizeComponent(c) {
  const cfg = c.config;
  if (c.component_type === "heading" || c.component_type === "text") return cfg.text || "(empty)";
  if (c.component_type === "stat_card") {
    return `${cfg.label || ""} — count of ${cfg.entity_type}` + (cfg.filter_field ? ` where ${cfg.filter_field} = ${cfg.filter_value}` : "");
  }
  if (c.component_type === "data_table") return `${cfg.entity_type} table — columns: ${(cfg.columns || []).join(", ") || "all"}`;
  if (c.component_type === "divider") return "—— divider ——";
  return "";
}

function renderBuilderCanvas(components) {
  const canvas = $("builder-canvas");
  canvas.innerHTML = components.length ? components.map(c => `
    <div class="bg-slate-900 border border-slate-800 rounded-xl p-3 flex items-start gap-3" draggable="true" data-comp-id="${c.id}">
      <div class="cursor-grab text-slate-600 select-none pt-1" title="Drag to reorder">⠿</div>
      <div class="flex-1 min-w-0">
        <div class="text-xs text-slate-500 uppercase tracking-wide mb-1">${c.component_type.replace(/_/g, " ")}</div>
        <div class="text-sm text-slate-300 truncate">${summarizeComponent(c)}</div>
      </div>
      <button class="text-xs text-rose-400 shrink-0" data-delete-comp="${c.id}">Delete</button>
    </div>`).join("") : `<div class="text-sm text-slate-500 text-center py-6 border border-dashed border-slate-800 rounded-xl">No components yet — add one below.</div>`;

  canvas.querySelectorAll("[data-comp-id]").forEach(el => {
    el.addEventListener("dragstart", () => el.classList.add("dragging"));
    el.addEventListener("dragend", () => el.classList.remove("dragging"));
  });
  canvas.querySelectorAll("[data-delete-comp]").forEach(btn => btn.addEventListener("click", async () => {
    try {
      await api(`/api/admin-panel/pages/${BUILDER_PAGE_ID}/components/${btn.dataset.deleteComp}`, { method: "DELETE" });
      loadBuilderCanvas();
    } catch (e) { toast(e.message); }
  }));

  if (!CANVAS_DND_INIT) { initCanvasDragDrop(); CANVAS_DND_INIT = true; }
}

// Native HTML5 drag-and-drop: reorders the DOM live as you drag over
// the canvas, then persists the final order on drop.
function initCanvasDragDrop() {
  const canvas = $("builder-canvas");
  canvas.addEventListener("dragover", (e) => {
    e.preventDefault();
    const dragging = canvas.querySelector(".dragging");
    if (!dragging) return;
    const afterEl = getDragAfterElement(canvas, e.clientY);
    if (afterEl == null) canvas.appendChild(dragging);
    else canvas.insertBefore(dragging, afterEl);
  });
  canvas.addEventListener("drop", async (e) => {
    e.preventDefault();
    const order = [...canvas.querySelectorAll("[data-comp-id]")].map(el => parseInt(el.dataset.compId, 10));
    try {
      await api(`/api/admin-panel/pages/${BUILDER_PAGE_ID}/components/reorder`, { method: "PUT", body: JSON.stringify({ order }) });
    } catch (e2) { toast(e2.message); loadBuilderCanvas(); }
  });
}

function getDragAfterElement(container, y) {
  const els = [...container.querySelectorAll("[data-comp-id]:not(.dragging)")];
  return els.reduce((closest, child) => {
    const box = child.getBoundingClientRect();
    const offset = y - box.top - box.height / 2;
    if (offset < 0 && offset > closest.offset) return { offset, element: child };
    return closest;
  }, { offset: Number.NEGATIVE_INFINITY }).element;
}

// ── Add-component forms (one per palette button) ─────────────────────
document.querySelectorAll("[data-add-type]").forEach(btn => btn.addEventListener("click", () => showAddForm(btn.dataset.addType)));

async function showAddForm(type) {
  const container = $("builder-add-form");

  if (type === "divider") {
    return submitAddComponent(type, {});
  }

  if (type === "heading" || type === "text") {
    container.innerHTML = `
      <div class="flex gap-2">
        <input id="add-field-text" type="text" placeholder="${type === "heading" ? "Heading text" : "Paragraph text"}"
               class="flex-1 bg-slate-950 border border-slate-700 rounded-lg px-3 py-2 text-sm">
        <button id="add-field-submit" class="bg-indigo-600 hover:bg-indigo-500 text-sm rounded-lg px-3 py-2">Add</button>
      </div>`;
    $("add-field-submit").addEventListener("click", () => submitAddComponent(type, { text: $("add-field-text").value }));
    return;
  }

  const schema = await getEntitySchema();
  const entityOptions = Object.keys(schema).map(e => `<option value="${e}">${e}</option>`).join("");

  if (type === "stat_card") {
    container.innerHTML = `
      <div class="grid grid-cols-2 gap-2 mb-2">
        <input id="add-sc-label" type="text" placeholder="Label (e.g. 'Low stock items')" class="bg-slate-950 border border-slate-700 rounded-lg px-3 py-2 text-sm">
        <select id="add-sc-entity" class="bg-slate-950 border border-slate-700 rounded-lg px-3 py-2 text-sm">${entityOptions}</select>
      </div>
      <button id="add-field-submit" class="bg-indigo-600 hover:bg-indigo-500 text-sm rounded-lg px-3 py-2">Add</button>`;
    $("add-field-submit").addEventListener("click", () => submitAddComponent(type, {
      label: $("add-sc-label").value || "Count", entity_type: $("add-sc-entity").value,
    }));
    return;
  }

  if (type === "data_table") {
    container.innerHTML = `
      <select id="add-dt-entity" class="bg-slate-950 border border-slate-700 rounded-lg px-3 py-2 text-sm mb-2">${entityOptions}</select>
      <div id="add-dt-columns" class="flex flex-wrap gap-3 mb-2 text-xs"></div>
      <button id="add-field-submit" class="bg-indigo-600 hover:bg-indigo-500 text-sm rounded-lg px-3 py-2">Add</button>`;
    const renderCols = () => {
      const cols = schema[$("add-dt-entity").value] || [];
      $("add-dt-columns").innerHTML = cols.map(c => `
        <label class="flex items-center gap-1 text-slate-300"><input type="checkbox" value="${c}" checked class="rounded bg-slate-950 border-slate-700">${c}</label>`).join("");
    };
    renderCols();
    $("add-dt-entity").addEventListener("change", renderCols);
    $("add-field-submit").addEventListener("click", () => {
      const columns = [...$("add-dt-columns").querySelectorAll("input:checked")].map(i => i.value);
      submitAddComponent(type, { entity_type: $("add-dt-entity").value, columns, limit: 25 });
    });
  }
}

async function submitAddComponent(type, config) {
  try {
    await api(`/api/admin-panel/pages/${BUILDER_PAGE_ID}/components`, {
      method: "POST", body: JSON.stringify({ component_type: type, config }),
    });
    $("builder-add-form").innerHTML = "";
    loadBuilderCanvas();
  } catch (e) { toast(e.message); }
}

// ── Init ──────────────────────────────────────────────────────────
if (TOKEN) { afterLogin().catch(() => doLogout()); } else { showView("login"); }
</script>

</body>
</html>
AWW_ADMIN_PANEL_HTML
echo "Wrote app/templates/admin_panel.html"

mkdir -p "$(dirname "$TARGET_DIR/app/templates/welding_wire_print.html")"
cat > "$TARGET_DIR/app/templates/welding_wire_print.html" <<'AWW_WIRE_PRINT_HTML'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{{ batch.unique_name }} — welding wire labels</title>
<style>
  :root {
    --bg: #0c1120; --panel: #161d33; --panel-border: #232b45;
    --text: #e6e9f2; --muted: #8b93a8; --accent: #6d5ef0;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0; background: var(--bg); color: var(--text);
    font: 15px/1.5 -apple-system, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    padding: 24px;
  }
  .header { max-width: 900px; margin: 0 auto 20px; display: flex; align-items: center; justify-content: space-between; }
  .header h1 { font-size: 20px; margin: 0; }
  .header .meta { color: var(--muted); font-size: 13px; margin-top: 4px; }
  .actions button {
    padding: 10px 18px; border-radius: 8px; border: none; cursor: pointer;
    font: inherit; font-weight: 600; font-size: 14px; background: var(--accent); color: #fff;
  }
  .grid {
    max-width: 900px; margin: 0 auto;
    display: grid; grid-template-columns: repeat(auto-fill, minmax(240px, 1fr)); gap: 14px;
  }
  .label {
    background: var(--panel); border: 1px solid var(--panel-border); border-radius: 12px;
    padding: 14px; text-align: center;
  }
  .label .name { font-weight: 600; font-size: 14px; margin-bottom: 2px; }
  .label .size { color: var(--muted); font-size: 12px; margin-bottom: 10px; }
  .barcode-box { background: #fff; border-radius: 6px; padding: 10px; margin-bottom: 8px; }
  .barcode-box svg { width: 100%; height: auto; display: block; }
  .code { font-size: 12px; color: var(--muted); font-family: ui-monospace, monospace; }

  @media print {
    body { background: #fff; color: #000; padding: 0; }
    .header .actions { display: none; }
    .header .meta { color: #444; }
    .grid { gap: 8px; }
    .label { border: 1px solid #ccc; break-inside: avoid; page-break-inside: avoid; }
    .label .size, .code { color: #444; }
  }
</style>
</head>
<body>
  <div class="header">
    <div>
      <h1>{{ batch.unique_name }}</h1>
      <div class="meta">{{ batch.size }} &middot; {{ batch.wire_code }} &middot; {{ labels|length }} label{{ "s" if labels|length != 1 else "" }}</div>
    </div>
    <div class="actions"><button onclick="window.print()">Print all</button></div>
  </div>

  <div class="grid">
    {% for label in labels %}
    <div class="label">
      <div class="name">{{ batch.unique_name }}</div>
      <div class="size">{{ batch.size }}</div>
      <div class="barcode-box">{{ label.svg|safe }}</div>
      <div class="code">{{ label.code }}</div>
    </div>
    {% endfor %}
  </div>
</body>
</html>
AWW_WIRE_PRINT_HTML
echo "Wrote app/templates/welding_wire_print.html"


echo "Wrote all files."

# Best-effort restart: this app has no systemd unit on your VPS (per
# earlier diagnosis) -- it's run directly as:
#   /root/stocktool-kiosk/venv/bin/python3 /root/stocktool-kiosk/main.py --service
# Editing .py/.html files on disk does NOT affect an already-running
# process, so it has to actually restart to pick any of this up.
PID=$(pgrep -f "python3 .*main\.py --service" | head -n1 || true)
if [[ -n "$PID" ]]; then
  echo "Found running kiosk process (PID $PID). Restarting it..."
  kill "$PID"
  sleep 2
  VENV_PY="$TARGET_DIR/venv/bin/python3"
  if [[ ! -x "$VENV_PY" ]]; then VENV_PY="python3"; fi
  ( cd "$TARGET_DIR" && nohup "$VENV_PY" main.py --service > service.log 2>&1 & )
  sleep 3
  echo "Restarted. Checking /api/status ..."
  curl -sS http://127.0.0.1:8420/api/status && echo "" || echo "Couldn't reach /api/status -- check service.log"
else
  echo "No running 'main.py --service' process found -- start the app yourself so these changes take effect."
fi

echo ""
echo "Done. Log into the Admin Panel (/ui/admin) and check the sidebar for 'Welding Wire'."
echo "If it's not there for a non-super_admin role, grant it the new"
echo "'Add welding wire & generate barcodes' permission under Roles & Permissions."
