from functools import wraps

from flask import abort, g, request, flash, redirect, url_for
from flask_login import current_user

from app.models import Company, company_has_product


def load_company_context(view):
    """Resolves <company_id> from the URL into g.company, and 404s if the
    current user isn't a member (never leaks existence of companies they're
    not part of) — UNLESS they're a platform admin, who can always view/
    administer any company regardless of membership. That bypass used to
    be a purely theoretical gap (every company in this dataset happened to
    also have the admin as a member) until self-service company creation
    plus the products approve/reject workflow made it a real, hit-every-
    time blocker: a platform admin approving or granting product access
    for some other company they never personally joined would 404 before
    even reaching their own @platform_admin_required-gated route."""
    @wraps(view)
    def wrapper(*args, **kwargs):
        company_id = kwargs.get("company_id")
        company = Company.query.filter_by(public_id=company_id).first()
        if company is None:
            abort(404)
        # getattr, not a direct call: current_user may be a ClientUser (the
        # separate Client Portal account type — see models.py), which has
        # no company membership concept at all. Confine_client_portal_
        # sessions in app/__init__.py already keeps a ClientUser from
        # reaching here in practice; this is a defensive fallback so a gap
        # in that confinement 404s instead of 500ing.
        role_in = getattr(current_user, "role_in", None)
        role = role_in(company.id) if current_user.is_authenticated and role_in else None
        if role is None:
            if current_user.is_authenticated and getattr(current_user, "is_platform_admin", False):
                role = "owner"  # synthetic — full view, same as the real owner's own nav/UI treatment
            else:
                abort(404)
        g.company = company
        g.company_role = role
        return view(*args, **kwargs)
    return wrapper


def require_product_access(slug: str, product_label: str = None):
    """Returns a blueprint-level before_request hook gating an entire
    product's blueprint (e.g. instances.py/rollouts.py for "kiosk") on the
    owning company actually having that product approved — see models.py's
    company_has_product/CompanyProductAccess for the access model this
    enforces. Register with `bp.before_request(require_product_access(...))`,
    same pattern kiosk_app's own require_sidebar_item uses.

    Resolves the company itself from request.view_args rather than
    g.company — this runs before load_company_context's per-view
    decorator does, so g.company isn't set yet. A platform admin always
    passes through (they administer every product regardless of a
    company's own approval state); so does anyone who isn't an
    authenticated member of the company in the URL — that leaves the real
    404-for-non-members behavior in load_company_context completely
    untouched, this only ever turns into a redirect for someone who IS a
    legitimate member of a company that simply hasn't been approved yet."""
    label = product_label or slug

    def _guard():
        company_id = (request.view_args or {}).get("company_id")
        if company_id is None:
            return None
        company = Company.query.filter_by(public_id=company_id).first()
        if company is None:
            return None
        if not current_user.is_authenticated or getattr(current_user, "is_platform_admin", False):
            return None
        role_in = getattr(current_user, "role_in", None)
        role = role_in(company.id) if role_in else None
        if role is None:
            return None  # not a member — let the real view 404 as usual
        if not company_has_product(company.id, slug):
            flash(f"Your company doesn't have access to {label} yet — request it from Company home.", "warning")
            return redirect(url_for("companies.detail", company_id=company.public_id))
        return None

    return _guard


def permission_required(*permissions: str):
    """Use after @load_company_context. Requires g.company to be set.

    Accepts one or more permission names — access is granted if the
    caller's role holds ANY of them. Used where a route serves two roles
    with permissions that don't otherwise overlap — e.g. scheduling a
    single instance's update is reachable via "manage_updates" (owner/
    administrator) or "operate_kiosk_updates" (the Client Portal's
    operator role), without granting operator the rest of what
    manage_updates unlocks elsewhere (bulk scheduling, staged rollouts)."""
    def decorator(view):
        @wraps(view)
        def wrapper(*args, **kwargs):
            if not current_user.is_authenticated:
                abort(401)
            company = getattr(g, "company", None)
            if company is None:
                abort(500)  # misconfigured route — load_company_context must run first
            if not any(current_user.has_permission(company.id, p) for p in permissions):
                abort(403)
            return view(*args, **kwargs)
        return wrapper
    return decorator
