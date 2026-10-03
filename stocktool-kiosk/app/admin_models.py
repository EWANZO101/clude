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

from app.models import db, LocalUser, Item, Tool, Project


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
}

# Seeded once, on first startup after this file is added (see
# app/admin_app.py). Matches the roles named in README_ADMIN_PANEL_PART1.txt.
_DEFAULT_ROLES = [
    # (name, display_name, permissions, is_system)
    ("super_admin", "Super Admin", list(PERMISSIONS.keys()), True),
    ("admin", "Admin", [
        "manage_users", "manage_sidebar", "manage_custom_fields",
        "manage_kiosk_tokens", "view_audit_log",
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
