from functools import wraps

from flask import abort
from flask_login import current_user, login_required

PERMISSION_DEFINITIONS = [
    ("servers.view", "servers", "View servers"),
    ("servers.create", "servers", "Create servers"),
    ("servers.edit", "servers", "Edit servers"),
    ("servers.delete", "servers", "Delete servers"),
    ("orders.view", "orders", "View orders"),
    ("orders.create", "orders", "Create orders"),
    ("orders.edit", "orders", "Edit orders"),
    ("orders.cancel", "orders", "Cancel orders"),
    ("customers.view", "customers", "View customers"),
    ("customers.edit", "customers", "Edit customers"),
    ("sellers.view", "sellers", "View sellers"),
    ("sellers.approve", "sellers", "Approve sellers"),
    ("sellers.suspend", "sellers", "Suspend sellers"),
    ("requests.view", "requests", "View BYOE requests"),
    ("requests.edit", "requests", "Edit BYOE requests"),
    ("requests.approve", "requests", "Approve BYOE requests"),
    ("requests.reject", "requests", "Reject BYOE requests"),
    ("requests.lock", "requests", "Lock BYOE requests"),
    ("requests.unlock", "requests", "Unlock BYOE requests"),
    ("equipment.view", "equipment", "View equipment"),
    ("equipment.create", "equipment", "Create equipment"),
    ("equipment.edit", "equipment", "Edit equipment"),
    ("equipment.delete", "equipment", "Delete equipment"),
    ("equipment.inspect", "equipment", "Inspect equipment"),
    ("invoices.view", "invoices", "View invoices"),
    ("invoices.create", "invoices", "Create invoices"),
    ("invoices.edit", "invoices", "Edit invoices"),
    ("payments.view", "payments", "View payments"),
    ("payments.refund", "payments", "Refund payments"),
    ("shipping.view", "shipping", "View shipments"),
    ("shipping.create", "shipping", "Create shipments"),
    ("shipping.edit", "shipping", "Edit shipments"),
    ("chat.view", "chat", "View chat"),
    ("chat.send", "chat", "Send chat messages"),
    ("tickets.view", "tickets", "View support tickets"),
    ("tickets.edit", "tickets", "Edit support tickets"),
    ("hardware.view", "hardware", "View hardware catalog"),
    ("hardware.edit", "hardware", "Edit hardware catalog"),
    ("infrastructure.view", "infrastructure", "View racks/network/power"),
    ("infrastructure.edit", "infrastructure", "Edit racks/network/power"),
    ("api.manage", "api", "Manage API keys and webhooks"),
    ("settings.view", "settings", "View system settings"),
    ("settings.edit", "settings", "Edit system settings"),
    ("users.view", "users", "View users"),
    ("users.edit", "users", "Edit users, roles and permissions"),
    ("audit.view", "audit", "View audit logs"),
]

DEFAULT_ROLES = {
    "Super Admin": {"is_system": True, "permissions": "__all__"},
    "Support": {
        "is_system": True,
        "permissions": [
            "chat.view", "chat.send", "tickets.view", "tickets.edit",
            "customers.view", "orders.view", "requests.view", "equipment.view",
        ],
    },
    "Sales": {
        "is_system": True,
        "permissions": [
            "servers.view", "servers.edit", "orders.view", "orders.edit",
            "customers.view", "sellers.view",
        ],
    },
    "Finance": {
        "is_system": True,
        "permissions": [
            "invoices.view", "invoices.create", "invoices.edit",
            "payments.view", "payments.refund", "orders.view",
        ],
    },
    "Shipping": {
        "is_system": True,
        "permissions": ["shipping.view", "shipping.create", "shipping.edit", "equipment.view"],
    },
    "Warehouse": {
        "is_system": True,
        "permissions": ["equipment.view", "equipment.edit", "equipment.inspect", "shipping.view"],
    },
    "Infrastructure": {
        "is_system": True,
        "permissions": ["infrastructure.view", "infrastructure.edit", "equipment.view"],
    },
    "Network": {
        "is_system": True,
        "permissions": ["infrastructure.view", "infrastructure.edit"],
    },
    "Seller Owner": {
        "is_system": True,
        "permissions": ["servers.view", "servers.create", "servers.edit", "orders.view"],
    },
    "Seller Staff": {
        "is_system": True,
        "permissions": ["servers.view", "orders.view"],
    },
}


def permission_required(code):
    def decorator(fn):
        @wraps(fn)
        @login_required
        def wrapper(*args, **kwargs):
            if not current_user.has_permission(code):
                abort(403)
            return fn(*args, **kwargs)

        return wrapper

    return decorator


def role_required(*role_names):
    def decorator(fn):
        @wraps(fn)
        @login_required
        def wrapper(*args, **kwargs):
            if not any(current_user.has_role(r) for r in role_names):
                abort(403)
            return fn(*args, **kwargs)

        return wrapper

    return decorator


def seed_roles_and_permissions():
    from app.extensions import db
    from app.models import Permission, Role, RolePermission

    perm_by_code = {}
    for code, category, description in PERMISSION_DEFINITIONS:
        perm = Permission.query.filter_by(code=code).first()
        if not perm:
            perm = Permission(code=code, category=category, description=description)
            db.session.add(perm)
        perm_by_code[code] = perm
    db.session.flush()

    for role_name, cfg in DEFAULT_ROLES.items():
        role = Role.query.filter_by(name=role_name).first()
        if not role:
            role = Role(name=role_name, is_system=cfg.get("is_system", False))
            db.session.add(role)
            db.session.flush()

        wanted_codes = (
            set(perm_by_code.keys())
            if cfg["permissions"] == "__all__"
            else set(cfg["permissions"])
        )
        existing_codes = role.permission_codes
        for code in wanted_codes - existing_codes:
            db.session.add(
                RolePermission(role_id=role.id, permission_id=perm_by_code[code].id)
            )

    db.session.commit()
