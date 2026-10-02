"""
═══════════════════════════════════════════════════════════════════════════
  rbac.py — role hierarchy + permission decorators
═══════════════════════════════════════════════════════════════════════════
  Backward compatible with the existing `User.role` strings:
    legacy "user" → customer, "admin" → admin, "staff" → staff.

  Usage:
      from .rbac import require_role, require_permission, STAFF

      @bp.route("/admin/thing")
      @require_role(STAFF)
      def thing(): ...

      @bp.route("/invoices/<int:i>/void", methods=["POST"])
      @require_permission("invoice.manage")
      def void(i): ...
═══════════════════════════════════════════════════════════════════════════
"""
from functools import wraps
from flask import abort, redirect, url_for, request, flash
from flask_login import current_user

# Canonical roles (high → low authority)
SUPER_ADMIN = "super_admin"
ADMIN = "admin"
STAFF = "staff"
SUPPORT = "support"
CUSTOMER = "customer"

ROLES = [SUPER_ADMIN, ADMIN, STAFF, SUPPORT, CUSTOMER]
ROLE_RANK = {SUPER_ADMIN: 50, ADMIN: 40, STAFF: 30, SUPPORT: 20, CUSTOMER: 10}
ROLE_LABELS = {
    SUPER_ADMIN: "Super Admin", ADMIN: "Admin", STAFF: "Staff",
    SUPPORT: "Support", CUSTOMER: "Customer",
}

# Map any legacy/loose value onto a canonical role
_LEGACY = {"user": CUSTOMER, "member": CUSTOMER, "client": CUSTOMER,
           "administrator": ADMIN, "owner": SUPER_ADMIN}


def canonical_role(user) -> str:
    raw = (getattr(user, "role", None) or "").strip().lower()
    if raw in ROLE_RANK:
        return raw
    return _LEGACY.get(raw, CUSTOMER)


def rank(user) -> int:
    return ROLE_RANK.get(canonical_role(user), 0)


def at_least(user, role) -> bool:
    return rank(user) >= ROLE_RANK.get(role, 999)


def is_staff_plus(user) -> bool:
    """Anyone who works for the company (support and above)."""
    return at_least(user, SUPPORT)


# ── Permission map: permission → minimum role ───────────────────────────────
# Add freely; unknown permissions default to ADMIN (fail safe).
PERMISSIONS = {
    # projects
    "project.view_all":     SUPPORT,
    "project.manage":       STAFF,
    "project.update_stage": STAFF,
    # appointments
    "appointment.view_all": SUPPORT,
    "appointment.manage":   STAFF,
    # invoices / billing
    "invoice.view_all":     SUPPORT,
    "invoice.manage":       ADMIN,
    "payment.refund":       ADMIN,
    # products / shop
    "product.manage":       ADMIN,
    # support tickets
    "ticket.view_all":      SUPPORT,
    "ticket.manage":        SUPPORT,
    # users / system
    "user.manage":          ADMIN,
    "role.manage":          SUPER_ADMIN,
    "settings.manage":      ADMIN,
    "audit.view":           ADMIN,
    "kb.manage":            STAFF,
    "announcement.manage":  ADMIN,
}


def has_permission(user, permission) -> bool:
    required = PERMISSIONS.get(permission, ADMIN)
    return at_least(user, required)


# ── Decorators ──────────────────────────────────────────────────────────────
def _deny():
    if not current_user.is_authenticated:
        flash("Please sign in to continue.", "warning")
        return redirect(url_for("auth.login", next=request.path))
    abort(403)


def require_role(min_role):
    def deco(fn):
        @wraps(fn)
        def wrapper(*a, **kw):
            if not current_user.is_authenticated or not at_least(current_user, min_role):
                return _deny()
            return fn(*a, **kw)
        return wrapper
    return deco


def require_permission(permission):
    def deco(fn):
        @wraps(fn)
        def wrapper(*a, **kw):
            if not current_user.is_authenticated or not has_permission(current_user, permission):
                return _deny()
            return fn(*a, **kw)
        return wrapper
    return deco
