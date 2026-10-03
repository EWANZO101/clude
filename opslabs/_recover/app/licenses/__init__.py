"""
═══════════════════════════════════════════════════════════════════════════
  app/licenses/__init__.py — License Manager sub-package for OpsLabs
═══════════════════════════════════════════════════════════════════════════
  Mounts the license manager under /licenses/ inside the OpsLabs Flask
  app. Has its own:
    • Database tables (prefixed lic_*)
    • Admin & customer login (separate from OpsLabs accounts)
    • Templates (in app/licenses/templates/)
    • Blueprints (lic_admin, lic_customer, lic_auth, lic_api)

  Integration with OpsLabs:
    • Shares the same Flask app, SQLAlchemy db, and SQLite database file
    • lic_customers.opslabs_company_id → companies.id (optional link)

  URL layout:
    /licenses/                    public landing
    /licenses/auth/login          license-admin login
    /licenses/admin/              license-admin dashboard
    /licenses/portal/login        customer login
    /licenses/portal/             customer dashboard
    /licenses/api/...             validation API for software clients
═══════════════════════════════════════════════════════════════════════════
"""
import os
from flask import render_template, redirect, url_for, Blueprint, jsonify

# Re-export the parent app's SQLAlchemy + login manager
from .. import db, login_manager


# ════════════════════════════════════════════════════════════════════════
# A tiny landing-page blueprint for /licenses/
# ════════════════════════════════════════════════════════════════════════
landing_bp = Blueprint("lic_landing", __name__)


@landing_bp.route("/")
def landing():
    """Public /licenses/ — bounces visitors to the right portal."""
    return render_template("licenses/landing.html")


@landing_bp.route("/health")
def health():
    return jsonify({"ok": True, "service": "opslabs-licenses"})


# ════════════════════════════════════════════════════════════════════════
# Register everything onto the parent Flask app
# ════════════════════════════════════════════════════════════════════════
def register(app):
    """Called from OpsLabs's create_app() after the main blueprints."""

    # ─── 1. Make licenses templates discoverable ──────────────────────
    # Add our templates directory as an extra search path. Flask's default
    # ChoiceLoader will check both our directory and the main app/templates.
    import os
    from jinja2 import ChoiceLoader, FileSystemLoader
    lic_templates = os.path.join(os.path.dirname(__file__), "templates")
    if os.path.isdir(lic_templates):
        app.jinja_loader = ChoiceLoader([
            FileSystemLoader(lic_templates),
            app.jinja_loader,
        ])

    # ─── 2. Import models so SQLAlchemy registers them on shared db ───
    from . import models                 # noqa
    from .auth     import bp as auth_bp
    from .admin    import bp as admin_bp
    from .customer import bp as customer_bp
    from .api      import bp as api_bp

    app.register_blueprint(landing_bp,  url_prefix="/licenses")
    app.register_blueprint(auth_bp,     url_prefix="/licenses/auth")
    app.register_blueprint(admin_bp,    url_prefix="/licenses/admin")
    app.register_blueprint(customer_bp, url_prefix="/licenses/portal")
    app.register_blueprint(api_bp,      url_prefix="/licenses/api")

    # The validation API does not use CSRF (clients are external programs).
    # If OpsLabs has CSRF protection enabled, exempt the api blueprint:
    try:
        from flask_wtf.csrf import CSRFProtect
        # Find the csrf instance — search app extensions
        csrf = app.extensions.get("csrf")
        if csrf:
            csrf.exempt(api_bp)
    except ImportError:
        pass

    # Give the license blueprints their OWN login manager + session cookie.
    # Cookie is scoped to /licenses/ so it never collides with OpsLabs sessions.
    _setup_independent_login(app)

    # Context processor — make Settings.get() available to license templates.
    # Templates expect unprefixed names; OpsLabs's own processor uses
    # different names (setting, content) so there's no collision.
    @app.context_processor
    def _inject_license_settings():
        # Only inject these on /licenses/* — outside that scope they would
        # shadow OpsLabs's own variables and rebrand the main site.
        from flask import request, has_request_context
        if not has_request_context() or not request.path.startswith("/licenses"):
            return {}
        try:
            from .models import Settings
            return {
                "site_name":     Settings.get("site_name", "OpsLabs Licenses"),
                "site_tagline":  Settings.get("site_tagline", "License Manager"),
                "company_name":  Settings.get("company_name", "OpsLabs Systems"),
                "primary_color": Settings.get("primary_color", "blue"),
                "session_timeout": Settings.get("session_timeout", "3600"),
            }
        except Exception:
            return {
                "site_name":      "OpsLabs Licenses",
                "site_tagline":   "License Manager",
                "company_name":   "OpsLabs Systems",
                "primary_color":  "blue",
                "session_timeout":"3600",
            }

    # Defensive: license templates inherited csrf_token() calls but
    # OpsLabs doesn't use Flask-WTF. Register a no-op so they don't crash.
    if "csrf_token" not in app.jinja_env.globals:
        app.jinja_env.globals["csrf_token"] = lambda: ""

    app.logger.info("License Manager mounted at /licenses/")


def _setup_independent_login(app):
    """Create a SECOND LoginManager + session interface for /licenses/.

    Uses a separate cookie name + path so it never collides with OpsLabs.
    Auth endpoints under /licenses/* use this; everything else uses the
    OpsLabs login_manager.
    """
    from flask_login import LoginManager
    from .models import AdminUser, Customer

    # Dedicated login manager
    lic_lm = LoginManager()
    lic_lm.login_view = "lic_auth.login"
    lic_lm.session_protection = "basic"

    # Use a separate session cookie scoped to /licenses
    # IMPORTANT: this is achieved by writing to a custom session key,
    # not a separate cookie (Flask only supports one session cookie per app).
    # Instead we namespace WITHIN the existing session.
    @lic_lm.user_loader
    def _load(user_id):
        if not user_id:
            return None
        try:
            return AdminUser.query.get(int(user_id))
        except (TypeError, ValueError):
            return None

    lic_lm.init_app(app)
    app.lic_login_manager = lic_lm

    # Tell Flask-Login on a per-request basis which manager to use:
    # if the request is under /licenses/, the lic_lm takes over.
    from flask import request, session, has_request_context
    from flask_login import LoginManager as _LM
    from flask_login.utils import _get_user

    # Patch: the trick is that OpsLabs's LoginManager and ours both look
    # at flask.session for a "_user_id" key. We rewrite the key per scope.
    original_request_loader = login_manager._request_callback
    original_user_loader   = login_manager._user_callback

    LICENSE_SESSION_KEY = "_lic_user_id"

    def _scoped_user_loader(user_id):
        """Used by both managers — picks correct table based on URL scope."""
        if has_request_context() and request.path.startswith("/licenses"):
            # In the license scope, load from AdminUser
            try:
                return AdminUser.query.get(int(user_id))
            except (TypeError, ValueError):
                return None
        # Otherwise delegate to OpsLabs's original loader
        if original_user_loader:
            return original_user_loader(user_id)
        return None

    # Wrap the OpsLabs login_manager's loader with the scoped version
    login_manager._user_callback = _scoped_user_loader

    # Hook into Flask request cycle: swap session key based on URL
    @app.before_request
    def _swap_session_key():
        if not has_request_context():
            return
        if request.path.startswith("/licenses"):
            # Move user_id to the license slot if needed
            lic_id = session.get(LICENSE_SESSION_KEY)
            session["_user_id"] = lic_id  # may be None
        else:
            # Move user_id to the OpsLabs slot
            opslabs_id = session.get("_opslabs_user_id")
            session["_user_id"] = opslabs_id

    @app.after_request
    def _persist_session_key(response):
        if not has_request_context():
            return response
        cur = session.get("_user_id")
        if request.path.startswith("/licenses"):
            if cur is not None:
                session[LICENSE_SESSION_KEY] = cur
            elif LICENSE_SESSION_KEY in session:
                session.pop(LICENSE_SESSION_KEY, None)
        else:
            if cur is not None:
                session["_opslabs_user_id"] = cur
            elif "_opslabs_user_id" in session:
                session.pop("_opslabs_user_id", None)
        return response


# ════════════════════════════════════════════════════════════════════════
# Seed defaults (called from OpsLabs's seed routine)
# ════════════════════════════════════════════════════════════════════════
def seed_defaults():
    """Idempotent — only inserts rows that don't exist yet.

    Seeds:
      • Default admin: admin@example.com / admin123 (CHANGE AFTER FIRST LOGIN)
      • Permissions + Super Admin / Manager / Viewer roles
      • Sample product + 4 tiers
      • Initial Features library
      • System settings
    """
    from .models import (
        AdminUser, Settings, Role, Permission,
        Product, ProductTier, Feature,
    )

    # ─── Settings ────────────────────────────────────────────────────
    default_settings = [
        ("site_name",                "OpsLabs Licenses", "Site name displayed in license-manager header", "branding"),
        ("site_tagline",             "License Manager",  "Tagline shown below site name",                  "branding"),
        ("company_name",             "OpsLabs Systems",  "Company name for branding",                      "branding"),
        ("primary_color",            "blue",             "Primary theme color (emerald, blue, purple, rose)", "appearance"),
        ("session_timeout",          "3600",             "Session timeout in seconds",                     "security"),
        ("require_2fa",              "false",            "Require two-factor authentication",              "security"),
        ("allow_registration",       "true",             "Allow customer self-registration",               "customers"),
        ("default_license_duration", "365",              "Default license duration in days",               "licenses"),
        ("max_activations_default",  "1",                "Default max activations for new licenses",       "licenses"),
        ("admin_api_key",            "",                 "API key for the management API (long random string)", "api"),
    ]
    for key, value, desc, category in default_settings:
        if not Settings.query.filter_by(key=key).first():
            db.session.add(Settings(key=key, value=value, description=desc, category=category))

    # ─── Permissions ─────────────────────────────────────────────────
    default_permissions = [
        ("licenses.view",        "View Licenses",     "View license list and details",     "licenses"),
        ("licenses.create",      "Create Licenses",   "Create new licenses",                "licenses"),
        ("licenses.edit",        "Edit Licenses",     "Edit license details",               "licenses"),
        ("licenses.delete",      "Delete Licenses",   "Delete licenses",                    "licenses"),
        ("licenses.manage_ips",  "Manage IPs",        "Manage license IP addresses",        "licenses"),
        ("customers.view",       "View Customers",    "View customer list and details",     "customers"),
        ("customers.create",     "Create Customers",  "Create new customers",               "customers"),
        ("customers.edit",       "Edit Customers",    "Edit customer details",              "customers"),
        ("customers.delete",     "Delete Customers",  "Delete customers",                   "customers"),
        ("products.view",        "View Products",     "View products and tiers",            "products"),
        ("products.create",      "Create Products",   "Create new products",                "products"),
        ("products.edit",        "Edit Products",     "Edit product details",               "products"),
        ("products.delete",      "Delete Products",   "Delete products",                    "products"),
        ("roles.view",           "View Roles",        "View roles and permissions",         "admin"),
        ("roles.manage",         "Manage Roles",      "Create, edit, delete roles",         "admin"),
        ("users.view",           "View Users",        "View admin users",                   "admin"),
        ("users.manage",         "Manage Users",      "Create, edit, delete admin users",   "admin"),
        ("settings.view",        "View Settings",     "View system settings",               "admin"),
        ("settings.edit",        "Edit Settings",     "Modify system settings",             "admin"),
        ("activity.view",        "View Activity",     "View activity logs",                 "admin"),
    ]
    for code, name, desc, category in default_permissions:
        if not Permission.query.filter_by(code=code).first():
            db.session.add(Permission(code=code, name=name, description=desc, category=category))

    db.session.flush()

    # ─── Roles ───────────────────────────────────────────────────────
    if not Role.query.filter_by(name="Super Admin").first():
        r = Role(name="Super Admin", description="Full system access", color="red", is_system=True)
        r.permissions = Permission.query.all()
        db.session.add(r)

    if not Role.query.filter_by(name="Manager").first():
        r = Role(name="Manager", description="Manage licenses and customers", color="blue", is_system=False)
        perms = ["licenses.view", "licenses.create", "licenses.edit", "licenses.manage_ips",
                 "customers.view", "customers.create", "customers.edit", "products.view", "activity.view"]
        r.permissions = Permission.query.filter(Permission.code.in_(perms)).all()
        db.session.add(r)

    if not Role.query.filter_by(name="Viewer").first():
        r = Role(name="Viewer", description="View-only access", color="gray", is_system=False)
        perms = ["licenses.view", "customers.view", "products.view", "activity.view"]
        r.permissions = Permission.query.filter(Permission.code.in_(perms)).all()
        db.session.add(r)

    # ─── Default admin ───────────────────────────────────────────────
    if not AdminUser.query.filter_by(email="admin@example.com").first():
        admin = AdminUser(email="admin@example.com", name="License Administrator",
                          is_superadmin=True)
        admin.set_password("admin123")
        db.session.add(admin)

    # ─── Sample product ──────────────────────────────────────────────
    if not Product.query.filter_by(code="STAFF_SCHEDULER").first():
        p = Product(
            name="Staff Scheduler", code="STAFF_SCHEDULER",
            description="Complete staff scheduling and management system",
            require_ip_lock=True, max_ip_addresses=2,
            allow_ip_change=True, ip_change_cooldown=24,
        )
        db.session.add(p)
        db.session.flush()
        tiers = [
            {"name":"Starter","code":"starter","price_monthly":0,"price_yearly":0,"max_users":5,
             "features":{"schedule":True},"sort_order":1},
            {"name":"Basic","code":"basic","price_monthly":29,"price_yearly":290,"max_users":25,
             "features":{"schedule":True,"leave":True,"tasks":True,"board":True},"sort_order":2},
            {"name":"Professional","code":"pro","price_monthly":79,"price_yearly":790,"max_users":100,
             "features":{"schedule":True,"leave":True,"tasks":True,"board":True,"finance":True,"reports":True},
             "sort_order":3},
            {"name":"Enterprise","code":"enterprise","price_monthly":199,"price_yearly":1990,"max_users":0,
             "features":{"schedule":True,"leave":True,"tasks":True,"board":True,"finance":True,
                         "reports":True,"api_access":True,"white_label":True},"sort_order":4},
        ]
        for t in tiers:
            db.session.add(ProductTier(product_id=p.id, **t))

    db.session.commit()

    # ─── Features library ────────────────────────────────────────────
    default_features = [
        ("dispatch",        "Dispatch",          "Live dispatch board and unit management", "cad"),
        ("mdt",             "MDT",               "Mobile Data Terminal access",             "cad"),
        ("citizens",        "Citizens",          "Citizen record management",               "cad"),
        ("vehicle_lookup",  "Vehicle Lookup",    "Vehicle registration & lookup",           "cad"),
        ("reports",         "Reports",           "Incident and arrest reports",             "cad"),
        ("admin_panel",     "Admin Panel",       "System administration access",            "admin"),
        ("api_access",      "API Access",        "External API access",                     "admin"),
        ("white_label",     "White Label",       "Custom branding options",                 "admin"),
        ("finance",         "Finance",           "Finance and billing module",              "billing"),
        ("schedule",        "Scheduling",        "Staff scheduling module",                 "hr"),
        ("leave",           "Leave Management",  "Leave requests and approvals",            "hr"),
        ("tasks",           "Task Manager",      "Task tracking and assignment",            "hr"),
        ("board",           "Board View",        "Kanban/board view for tasks",             "hr"),
    ]
    for code, name, desc, cat in default_features:
        if not Feature.query.filter_by(code=code).first():
            db.session.add(Feature(code=code, name=name, description=desc, category=cat))

    db.session.commit()
