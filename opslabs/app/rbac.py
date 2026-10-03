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
FOUNDER = "founder"
SUPER_ADMIN = "super_admin"
ADMIN = "admin"
STAFF = "staff"
SUPPORT = "support"
CUSTOMER = "customer"

ROLES = [FOUNDER, SUPER_ADMIN, ADMIN, STAFF, SUPPORT, CUSTOMER]
ROLE_RANK = {FOUNDER: 100, SUPER_ADMIN: 50, ADMIN: 40, STAFF: 30, SUPPORT: 20, CUSTOMER: 10}
ROLE_LABELS = {
    FOUNDER: "Founder", SUPER_ADMIN: "Super Admin", ADMIN: "Admin", STAFF: "Staff",
    SUPPORT: "Support", CUSTOMER: "Customer",
}

# Map any legacy/loose value onto a canonical role
_LEGACY = {"user": CUSTOMER, "member": CUSTOMER, "client": CUSTOMER,
           "administrator": ADMIN, "owner": FOUNDER}


# ── Admin page catalog ───────────────────────────────────────────────────────
# Every page that lives behind /admin. Founder and Admin always see all of
# them. Anyone else (staff, support, ...) must be individually granted a page
# below before it appears in their sidebar, or its URL will work for them.
ADMIN_PAGES = {
    "dashboard": "Dashboard",
    "tickets":   "Ticket Queue",
    "jobs":      "Quick Jobs",
    "reviews":   "Reviews",
    "roadmap":   "Roadmap",
    "packages":  "Packages",
    "callouts":  "Call-outs",
    "partners":  "Partners",
    "users":     "Users",
    "companies": "Companies",
    "api_keys":  "API Keys",
    "content":   "Homepage Editor",
    "settings":  "Settings",
    "role_perms": "Role Permissions",
}

# Roles that can be given default page grants on /admin/roles. Founder and
# Admin are excluded — they already see every page and don't need defaults.
MANAGEABLE_ROLES = [SUPER_ADMIN, STAFF, SUPPORT]


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


def is_founder(user) -> bool:
    return canonical_role(user) == FOUNDER


def outranks(user_a, user_b) -> bool:
    """True if user_a has strictly higher authority than user_b — used to stop
    an Admin from touching a Founder's account (Founder always overrules Admin)."""
    return rank(user_a) > rank(user_b)


def role_default_pages(role) -> list:
    """Default admin page keys granted to every account with this role
    (set via /admin/roles). Founder/Admin don't need this — they get
    everything regardless."""
    from .models import RolePagePermission  # lazy: avoid circular import
    rp = RolePagePermission.query.filter_by(role=role).first()
    return rp.page_list() if rp else []


def set_role_default_pages(role, pages) -> None:
    """Save the default page list for a role. `pages` is an iterable of
    ADMIN_PAGES keys; unknown keys are dropped."""
    from . import db
    from .models import RolePagePermission
    clean = [p for p in pages if p in ADMIN_PAGES]
    rp = RolePagePermission.query.filter_by(role=role).first()
    if not rp:
        rp = RolePagePermission(role=role)
        db.session.add(rp)
    rp.pages = ",".join(clean)
    db.session.commit()


def user_admin_pages(user) -> list:
    """The full list of admin page keys this account can open: the role's
    default pages (set on /admin/roles) plus anything granted individually
    on the account itself. Only meaningful for accounts below Admin —
    Founder/Admin get everything regardless."""
    raw = getattr(user, "permissions", "") or ""
    individual = [p.strip() for p in raw.split(",") if p.strip()]
    role_pages = role_default_pages(canonical_role(user))
    return sorted(set(individual) | set(role_pages))


def page_allowed(user, page_key) -> bool:
    """Can this user open the given /admin page?
    Founder overrules Admin, and both see every page. Everyone else needs
    that exact page granted on their account first."""
    if not user or not getattr(user, "is_authenticated", False):
        return False
    if canonical_role(user) in (FOUNDER, ADMIN):
        return True
    return page_key in user_admin_pages(user)


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


def require_admin_page(page_key):
    """Gate a single /admin page. Founder + Admin always pass. Everyone else
    needs `page_key` explicitly granted on their account (see admin/users →
    edit → Page access), and sees a proper 'Access Denied' page instead of a
    bare 403 if they aren't."""
    def deco(fn):
        @wraps(fn)
        def wrapper(*a, **kw):
            if not current_user.is_authenticated:
                flash("Please sign in to continue.", "warning")
                return redirect(url_for("auth.login", next=request.path))
            if not page_allowed(current_user, page_key):
                from flask import render_template
                return render_template(
                    "errors/403.html",
                    page_label=ADMIN_PAGES.get(page_key, page_key.replace("_", " ").title()),
                ), 403
            return fn(*a, **kw)
        return wrapper
    return deco
