"""Host-header-based tenant resolution for the browser-facing app.

Scope, matching tenancy.py's documented boundary: only Dashboard/Evidence/
Live (views.py) query a resolved tenant's own MySQL database (the 4 tables
tenancy.py provisions there - Evidence, ActiveRecorder, Alert, ExternalFeed).
Cases/Assistant/Community/Admin/Users/Settings remain control-plane-only
regardless of g.tenant - those stay out of scope here on purpose, so there's
no half-tenant-aware view showing one community's nav next to another
community's case data.

Resolution order, by request.host (port stripped):
  1. Exact match against Community.custom_domain
  2. "<slug>.<TENANT_BASE_DOMAIN>" match against Community.slug
  3. The logged-in user's own community_id (self-serve signups,
     community_signup.py) - this is what lets a self-signed-up community's
     admin actually see their own Dashboard/Evidence/Live from this
     deployment's primary URL, with no wildcard DNS record pointed here.
     A staff account on the original single-tenant server has
     community_id = None and never matches this.
  4. Anything else (including the primary PORTAL_PUBLIC_URL host for a
     non-self-serve login) -> no tenant; g.tenant stays None and the app
     behaves exactly as it always has (control-plane only, today's
     production behavior).

A matched Community with status != "active" resolves to None rather than
erroring - same as if the subdomain matched nothing - so a suspended
community's subdomain doesn't leak that it ever existed.
"""

from flask import current_app, g, request
from flask_login import current_user

from .models import Community


def resolve_tenant():
    g.tenant = None
    g.tenant_session = None

    host = (request.host or "").split(":", 1)[0].lower()
    community = None

    if host:
        community = Community.query.filter_by(custom_domain=host, status="active").first()
        if community is None:
            base = (current_app.config.get("TENANT_BASE_DOMAIN") or "").lower()
            if base and host.endswith("." + base):
                slug = host[: -(len(base) + 1)]
                if slug:
                    community = Community.query.filter_by(slug=slug, status="active").first()

    if community is None and current_user.is_authenticated and current_user.community_id:
        community = Community.query.filter_by(id=current_user.community_id, status="active").first()

    if community is not None:
        from . import tenancy

        g.tenant = community
        g.tenant_session = tenancy.get_tenant_session(community)
