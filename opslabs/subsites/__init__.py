"""
OpsLab Systems — subsites app.

A small, independent Flask app that serves the six dedicated service
websites (Website Development, FiveM Development, Tech Support, Hosting,
System Setup, On-Site IT & Networking). It is deliberately separate from
the main hub app (app/__init__.py) which owns login, tickets, billing,
admin, and the portal — those stay shared and are always linked back to
from every subsite.

Which of the six sites is rendered is decided by the subdomain in the
request's Host header (e.g. websites.yourdomain.com -> "websites").
For local development / testing without real DNS, every site is also
reachable at /preview/<key>, e.g. http://127.0.0.1:5050/preview/websites
"""
import os
import importlib.util

from flask import Flask, render_template, abort, request
from werkzeug.middleware.proxy_fix import ProxyFix

# services_data.py is plain-data Python (no Flask/SQLAlchemy imports), but it
# lives inside the `app` package alongside the hub app's __init__.py, which
# *does* need the hub's dependencies (flask_sqlalchemy, flask_login, ...)
# installed. The subsites app deliberately doesn't need any of that, so we
# load services_data.py directly by file path rather than doing
# `from app.services_data import ...`, which would import the app package
# (and therefore app/__init__.py) as a side effect.
_data_path = os.path.join(os.path.dirname(__file__), "..", "app", "services_data.py")
_spec = importlib.util.spec_from_file_location("opslab_services_data", _data_path)
_services_data = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_services_data)

SERVICES = _services_data.SERVICES
SUBDOMAINS = _services_data.SUBDOMAINS
SUBDOMAINS_ORDERED = _services_data.SUBDOMAINS_ORDERED

from .config import PUBLIC_DOMAIN, HUB_SUBDOMAIN, CONTACT_EMAIL, hub_url, subdomain_url


def _site_key_from_host(host):
    """Extract the subdomain label from a Host header, e.g.
    'websites.yourdomain.com:5050' -> 'websites'."""
    if not host:
        return None
    host = host.split(":")[0]
    parts = host.split(".")
    if len(parts) < 3:
        # bare domain / localhost / IP — no subdomain present
        return None
    return parts[0]


def create_subsite_app(site_key=None):
    """
    site_key=None  -> legacy multi-tenant mode: which site to render is
                      decided per-request from the Host header (used by
                      run_subsites.py for local dev preview of all six at
                      once on one port).
    site_key="fivem" (etc.) -> single-site mode: this process ALWAYS
                      serves that one division, full stop, regardless of
                      what Host header comes in. This is what production
                      uses now — one fully independent process per
                      subdomain (see wsgi_subsite.py), so there is no
                      routing logic left that could serve the wrong site.
    """
    if site_key is not None and site_key not in SUBDOMAINS:
        raise ValueError(f"Unknown site_key {site_key!r}; must be one of {sorted(SUBDOMAINS)}")

    app = Flask(__name__)
    # Same reason as the hub app (see app/__init__.py) — nginx terminates
    # TLS in front of this app too, so it needs ProxyFix to know requests
    # are actually HTTPS.
    app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1, x_host=1, x_port=1, x_prefix=1)
    app.config["PREFERRED_URL_SCHEME"] = os.environ.get("PREFERRED_URL_SCHEME", "https")
    app.config["PUBLIC_DOMAIN"] = PUBLIC_DOMAIN
    app.config["HUB_SUBDOMAIN"] = HUB_SUBDOMAIN
    app.config["SITE_KEY"] = site_key

    @app.context_processor
    def inject_helpers():
        return dict(
            hub_url=hub_url,
            subdomain_url=subdomain_url,
            PUBLIC_DOMAIN=PUBLIC_DOMAIN,
            CONTACT_EMAIL=CONTACT_EMAIL,
        )

    def render_site(key):
        slug = SUBDOMAINS.get(key)
        if not slug:
            abort(404)
        service = SERVICES[slug]
        siblings = [
            (sub, slug2, svc)
            for sub, slug2, svc in SUBDOMAINS_ORDERED
            if sub != key
        ]
        return render_template(
            "home.html",
            key=key,
            s=service,
            siblings=siblings,
            accent=service["accent"],
            site_name=service["short_name"],
            cta_short=service["cta_label"],
        )

    @app.route("/")
    def index():
        if site_key:
            # Single-site mode: always this division, no host sniffing.
            return render_site(site_key)
        key = _site_key_from_host(request.host)
        if key and key in SUBDOMAINS:
            return render_site(key)
        # No recognised subdomain (bare domain hit this app directly) —
        # show a small directory of all six sites instead of a dead end.
        return render_template("directory.html", sites=SUBDOMAINS_ORDERED)

    @app.route("/preview/<key>")
    def preview(key):
        """Local-dev convenience route: view any of the six sites without
        needing real DNS / subdomains set up yet. Available even in
        single-site mode, purely for local testing."""
        return render_site(key)

    @app.errorhandler(404)
    def not_found(e):
        if site_key:
            return render_site(site_key), 404
        return render_template("directory.html", sites=SUBDOMAINS_ORDERED), 404

    return app
