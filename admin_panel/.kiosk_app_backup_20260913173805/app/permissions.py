from functools import wraps

from flask import abort
from flask_login import current_user

from app.models import SIDEBAR_ITEMS, RoleSidebarPermission

ADMIN_ROLES = ("super_admin", "admin")


def visible_items_for(role: str) -> set:
    """Every sidebar item key visible to this role, computed against the
    lazy get-or-default table — an unconfigured install returns every
    item, matching pre-Part-6 behavior."""
    return {key for key, _, _ in SIDEBAR_ITEMS if RoleSidebarPermission.get_or_default(role, key)}


def require_sidebar_item(item_key: str):
    """Returns a before_request function that 403s a whole blueprint if
    the current user's role can't see item_key. Applied once per
    blueprint (items/tools/wire/projects/scan) rather than decorating
    every individual route — the kiosk is a touch UI with no address
    bar, so gating the blueprint's entry points covers the actual attack
    surface without hand-decorating dozens of action routes. Sub-links
    within a section (Low Stock, Tool Economics, Wire Reporting, etc.)
    are sidebar-visibility-only, not independently route-gated — a
    documented scope boundary, not an oversight."""

    def _guard():
        if not current_user.is_authenticated:
            return  # flask-login's own login_required handling applies first
        if not RoleSidebarPermission.get_or_default(current_user.role, item_key):
            abort(403)

    return _guard


def require_admin_role(view):
    """Hard-coded role check for the Admin Panel itself — deliberately
    NOT driven by RoleSidebarPermission, so the permission system this
    panel manages can never be used (accidentally or otherwise) to lock
    every admin out of the panel that would fix it."""

    @wraps(view)
    def wrapped(*args, **kwargs):
        if not current_user.is_authenticated or current_user.role not in ADMIN_ROLES:
            abort(403)
        return view(*args, **kwargs)

    return wrapped
