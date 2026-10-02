"""Role CRUD + permission-toggle business logic, shared by the human-facing
admin.py routes (kiosk terminal's own /admin panel) and sync_api.py's new
role sync routes (the Instance Agent, on behalf of the remote Client
Portal/Admin Panel — see agent/commands.py's role_* command types). One
implementation of every guardrail (can't delete a built-in role, can't
delete a role still in use, can't strand the kiosk with no admin-capable
login left) rather than two copies that could drift apart.

Every function returns (ok: bool, message: str) — the human routes turn
that into flash()+redirect, the sync routes turn it into a JSON body.
"""
from app.extensions import db
from app.models import (
    LocalUser, Role, RolePermission, RoleSidebarPermission, AuditLogEntry,
    SIDEBAR_ITEMS, ROLES as ROLES_BASELINE,
)
from app.permissions import ADMIN_ROLES


def _audit(actor: str, action: str, target: str = None, detail: str = None):
    db.session.add(AuditLogEntry(actor=actor, action=action, target=target, detail=detail))


def create_role(actor: str, name: str, description: str = None) -> tuple:
    name = (name or "").strip().lower().replace(" ", "_")
    if not name:
        return False, "Role name is required."
    if name in Role.all_role_names():
        return False, f"Role '{name}' already exists."
    role = Role(name=name, description=(description or "").strip() or None)
    db.session.add(role)
    _audit(actor, "role_create", target=name)
    db.session.commit()
    return True, f"Role '{name}' created."


def delete_role(actor: str, role_name: str) -> tuple:
    if role_name in ROLES_BASELINE:
        return False, f"'{role_name}' is a built-in role and can't be deleted."
    role = Role.query.get(role_name)
    if role is None:
        return False, f"Unknown role '{role_name}'."
    if LocalUser.query.filter_by(role=role_name).count() > 0:
        return False, f"'{role_name}' is still assigned to at least one user — reassign them first."
    db.session.delete(role)
    RolePermission.query.filter_by(role=role_name).delete()
    RoleSidebarPermission.query.filter_by(role=role_name).delete()
    _audit(actor, "role_delete", target=role_name)
    db.session.commit()
    return True, f"Role '{role_name}' deleted."


def set_role_login(actor: str, role_name: str, enabled: bool) -> tuple:
    if role_name not in Role.all_role_names():
        return False, f"Unknown role '{role_name}'."

    if not enabled and role_name in ADMIN_ROLES:
        # Guard: disabling logins for every admin-capable role would strand
        # the kiosk with no way back into this panel (short of the CLI).
        still_others = LocalUser.query.filter(
            LocalUser.role.in_([r for r in ADMIN_ROLES if r != role_name]), LocalUser.is_active.is_(True)
        ).count()
        role_login_enabled_elsewhere = any(
            (RolePermission.query.get(r).login_enabled if RolePermission.query.get(r) else True)
            for r in ADMIN_ROLES if r != role_name
        )
        if still_others == 0 or not role_login_enabled_elsewhere:
            return False, "Can't disable login for this role — no other admin-capable role could log in to re-enable it."

    rp = RolePermission.query.get(role_name)
    if rp is None:
        rp = RolePermission(role=role_name)
        db.session.add(rp)
    rp.login_enabled = enabled
    _audit(actor, "role_login_toggle", target=role_name, detail=f"login_enabled={enabled}")
    db.session.commit()
    return True, f"Login for '{role_name}' {'enabled' if enabled else 'disabled'}."


def set_role_sidebar(actor: str, role_name: str, visibility: dict) -> tuple:
    """visibility: {item_key: bool}. Unlisted keys are left unchanged."""
    if role_name not in Role.all_role_names():
        return False, f"Unknown role '{role_name}'."

    valid_keys = {key for key, _, _ in SIDEBAR_ITEMS}
    changed = []
    for key, visible in visibility.items():
        if key not in valid_keys:
            continue
        row = RoleSidebarPermission.query.get((role_name, key))
        if row is None:
            row = RoleSidebarPermission(role=role_name, item_key=key)
            db.session.add(row)
        if row.visible != bool(visible):
            changed.append(f"{key}={bool(visible)}")
        row.visible = bool(visible)

    if changed:
        _audit(actor, "sidebar_change", target=role_name, detail=", ".join(changed))
        db.session.commit()
        return True, "Sidebar updated."
    return True, "No changes."


def role_state(role_name: str) -> dict:
    """Everything the remote side needs to display/edit one role."""
    rp = RolePermission.query.get(role_name)
    return {
        "name": role_name,
        "is_builtin": role_name in ROLES_BASELINE,
        "user_count": LocalUser.query.filter_by(role=role_name).count(),
        "login_enabled": rp.login_enabled if rp else True,
        "sidebar": {key: RoleSidebarPermission.get_or_default(role_name, key) for key, _, _ in SIDEBAR_ITEMS},
    }


def all_roles_state() -> list:
    return [role_state(r) for r in Role.all_role_names()]
