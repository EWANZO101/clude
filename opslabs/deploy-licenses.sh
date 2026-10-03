#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────
# OpsLabs — License Manager integration
#
# Mounts the license manager under /licenses/ inside the OpsLabs Flask app.
#   • Drops 47 files into $TARGET/app/licenses/
#   • Patches app/__init__.py to register the sub-package
#   • Restarts opslabs-app
#
# Default login (CHANGE AFTER FIRST USE):
#   admin@example.com / admin123  →  /licenses/auth/login
#
# Usage:    chmod +x deploy-licenses.sh && ./deploy-licenses.sh
# Override: TARGET=/path/to/opslabs ./deploy-licenses.sh
# ─────────────────────────────────────────────────────────────────────────
set -euo pipefail

TARGET="${TARGET:-/root/opslabs}"
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="$TARGET/.deploy-backup/$STAMP"

GREEN=$(tput setaf 2 2>/dev/null || echo "")
YELLOW=$(tput setaf 3 2>/dev/null || echo "")
RED=$(tput setaf 1 2>/dev/null || echo "")
DIM=$(tput dim 2>/dev/null || echo "")
RESET=$(tput sgr0 2>/dev/null || echo "")

say()  { printf "%s▸%s %s\n" "$GREEN"  "$RESET" "$*"; }
warn() { printf "%s!%s %s\n" "$YELLOW" "$RESET" "$*"; }
die()  { printf "%s✗%s %s\n" "$RED"    "$RESET" "$*" >&2; exit 1; }

[ -d "$TARGET" ]                 || die "$TARGET does not exist."
[ -f "$TARGET/app/__init__.py" ] || die "$TARGET/app/__init__.py missing."

say "Target:   $TARGET"
say "Backups → $BACKUP_DIR"
echo ""

mkdir -p "$BACKUP_DIR/app"
cp "$TARGET/app/__init__.py" "$BACKUP_DIR/app/__init__.py.bak" 2>/dev/null || true

write_file() {
    local rel="$1"
    local path="$TARGET/$rel"
    mkdir -p "$(dirname "$path")"
    if [ -f "$path" ]; then
        mkdir -p "$BACKUP_DIR/$(dirname "$rel")"
        cp "$path" "$BACKUP_DIR/$rel"
    fi
    cat > "$path"
}

# ─── 1. Write 47 license-manager files ───

say "Writing app/licenses/__init__.py"
write_file 'app/licenses/__init__.py' << 'OPSLAB_LIC_EOF__7f2d8a5e'
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
            app.jinja_loader,
            FileSystemLoader(lic_templates),
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

    # Make the AdminUser also loadable via Flask-Login.
    # OpsLabs already has its own user_loader for User; we add a fallback
    # by prefixing license user ids with "lic:" so we can disambiguate.
    _wire_login_manager()

    # Context processor — make Settings.get() available to license templates.
    # Templates expect unprefixed names; OpsLabs's own processor uses
    # different names (setting, content) so there's no collision.
    @app.context_processor
    def _inject_license_settings():
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
                "site_name": "OpsLabs Licenses",
                "site_tagline": "License Manager",
                "company_name": "OpsLabs Systems",
                "primary_color": "blue",
                "session_timeout": "3600",
            }

    app.logger.info("License Manager mounted at /licenses/")


def _wire_login_manager():
    """Allow license AdminUser to share the same login_manager with OpsLabs.

    OpsLabs's user_loader returns User; we wrap it so IDs prefixed with
    'lic:' resolve to license AdminUser instead.
    """
    from .models import AdminUser

    original_loader = login_manager._user_callback

    @login_manager.user_loader
    def _combined_loader(user_id):
        if isinstance(user_id, str) and user_id.startswith("lic:"):
            try:
                return AdminUser.query.get(int(user_id[4:]))
            except (TypeError, ValueError):
                return None
        if original_loader is not None:
            return original_loader(user_id)
        return None

    # Override AdminUser.get_id so license admins announce themselves as 'lic:N'
    AdminUser.get_id = lambda self: f"lic:{self.id}"


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
OPSLAB_LIC_EOF__7f2d8a5e

say "Writing app/licenses/admin.py"
write_file 'app/licenses/admin.py' << 'OPSLAB_LIC_EOF__7f2d8a5e'
"""
License Manager - Admin Routes
"""
from flask import Blueprint, render_template, redirect, url_for, flash, request, jsonify
from flask_login import login_required, current_user
from datetime import datetime, timedelta
from .. import db   # shared with OpsLabs
from .models import (
    AdminUser, Settings, Role, Permission,
    License, Customer, Product, ProductTier, 
    LicenseActivation, ActivityLog, Feature
)

bp = Blueprint('lic_admin', __name__)


def log_activity(action, entity_type=None, entity_id=None, details=None):
    """Log admin activity"""
    log = ActivityLog(
        admin_id=current_user.id,
        action=action,
        entity_type=entity_type,
        entity_id=entity_id,
        details=details,
        ip_address=request.remote_addr
    )
    db.session.add(log)
    db.session.commit()


# ==================== DASHBOARD ====================

@bp.route('/')
@login_required
def dashboard():
    """Admin dashboard"""
    # Stats
    total_licenses = License.query.count()
    active_licenses = License.query.filter_by(status='active').count()
    total_customers = Customer.query.count()
    
    # Recent activity
    recent_licenses = License.query.order_by(License.created_at.desc()).limit(5).all()
    recent_activations = LicenseActivation.query.order_by(
        LicenseActivation.activated_at.desc()
    ).limit(10).all()
    
    # Expiring soon (30 days)
    expiring_soon = License.query.filter(
        License.status == 'active',
        License.expires_at != None,
        License.expires_at <= datetime.utcnow() + timedelta(days=30),
        License.expires_at > datetime.utcnow()
    ).count()
    
    # Revenue (simple calculation)
    # In production, you'd track actual payments
    
    return render_template('admin/dashboard.html',
        total_licenses=total_licenses,
        active_licenses=active_licenses,
        total_customers=total_customers,
        expiring_soon=expiring_soon,
        recent_licenses=recent_licenses,
        recent_activations=recent_activations
    )


# ==================== LICENSES ====================

@bp.route('/licenses')
@login_required
def licenses():
    """List all licenses"""
    page = request.args.get('page', 1, type=int)
    status = request.args.get('status', 'all')
    search = request.args.get('search', '')
    
    query = License.query
    
    if status != 'all':
        query = query.filter_by(status=status)
    
    if search:
        query = query.filter(
            (License.license_key.ilike(f'%{search}%')) |
            (License.domain.ilike(f'%{search}%'))
        )
    
    licenses = query.order_by(License.created_at.desc()).paginate(page=page, per_page=20)
    
    # Counts
    counts = {
        'all': License.query.count(),
        'active': License.query.filter_by(status='active').count(),
        'suspended': License.query.filter_by(status='suspended').count(),
        'revoked': License.query.filter_by(status='revoked').count(),
        'expired': License.query.filter(
            License.expires_at < datetime.utcnow()
        ).count()
    }
    
    return render_template('admin/licenses.html',
        licenses=licenses,
        counts=counts,
        current_status=status,
        search=search
    )


@bp.route('/licenses/create', methods=['GET', 'POST'])
@login_required
def create_license():
    """Create a new license"""
    products = Product.query.filter_by(is_active=True).all()
    tiers = ProductTier.query.filter_by(is_active=True).all()
    customers = Customer.query.filter_by(is_active=True).order_by(Customer.company_name).all()
    all_features = Feature.query.filter_by(is_active=True).order_by(
        Feature.product_group, Feature.category, Feature.name).all()

    if request.method == 'POST':
        # Generate unique key
        while True:
            license_key = License.generate_key()
            if not License.query.filter_by(license_key=license_key).first():
                break

        # Calculate expiration
        duration = request.form.get('duration')
        expires_at = None
        if duration == 'monthly':
            expires_at = datetime.utcnow() + timedelta(days=30)
        elif duration == 'yearly':
            expires_at = datetime.utcnow() + timedelta(days=365)
        elif duration == 'custom':
            custom_date = request.form.get('custom_expiry')
            if custom_date:
                expires_at = datetime.strptime(custom_date, '%Y-%m-%d')

        license = License(
            license_key=license_key,
            product_id=request.form.get('product_id'),
            tier_id=request.form.get('tier_id'),
            customer_id=request.form.get('customer_id') or None,
            max_activations=request.form.get('max_activations', 1, type=int),
            expires_at=expires_at,
            domain=request.form.get('domain') or None,
            notes=request.form.get('notes'),
            created_by=current_user.id
        )

        db.session.add(license)
        db.session.flush()

        # Attach selected features
        selected_ids = set(int(x) for x in request.form.getlist('feature_ids'))
        if selected_ids:
            license.features = Feature.query.filter(Feature.id.in_(selected_ids)).all()

        db.session.commit()
        log_activity('create_license', 'license', license.id, f'Created license {license_key}')
        flash(f'License created: {license_key}', 'success')
        return redirect(url_for('lic_admin.view_license', id=license.id))

    # Group by product_group -> category
    grouped_features = {}
    for f in all_features:
        pg = grouped_features.setdefault(f.product_group or 'General', {})
        pg.setdefault(f.category or 'General', []).append(f)

    return render_template('admin/create_license.html',
        products=products,
        tiers=tiers,
        customers=customers,
        grouped_features=grouped_features
    )


@bp.route('/licenses/<int:id>')
@login_required
def view_license(id):
    """View license details"""
    license = License.query.get_or_404(id)
    activations = license.activations.order_by(LicenseActivation.activated_at.desc()).all()
    
    return render_template('admin/view_license.html',
        license=license,
        activations=activations
    )


@bp.route('/licenses/<int:id>/edit', methods=['GET', 'POST'])
@login_required
def edit_license(id):
    """Edit license"""
    license = License.query.get_or_404(id)
    tiers = ProductTier.query.filter_by(product_id=license.product_id, is_active=True).all()
    customers = Customer.query.filter_by(is_active=True).order_by(Customer.company_name).all()
    all_features = Feature.query.filter_by(is_active=True).order_by(Feature.category, Feature.name).all()

    if request.method == 'POST':
        license.tier_id = request.form.get('tier_id')
        license.customer_id = request.form.get('customer_id') or None
        license.max_activations = request.form.get('max_activations', 1, type=int)
        license.domain = request.form.get('domain') or None
        license.notes = request.form.get('notes')

        # Update expiry
        expiry_date = request.form.get('expires_at')
        if expiry_date:
            license.expires_at = datetime.strptime(expiry_date, '%Y-%m-%d')
        else:
            license.expires_at = None

        # Update license-level features
        selected_ids = set(int(x) for x in request.form.getlist('feature_ids'))
        license.features = Feature.query.filter(Feature.id.in_(selected_ids)).all() if selected_ids else []

        db.session.commit()

        log_activity('edit_license', 'license', license.id, f'Updated license {license.license_key}')

        flash('License updated', 'success')
        return redirect(url_for('lic_admin.view_license', id=license.id))

    grouped_features = {}
    for f in all_features:
        pg = grouped_features.setdefault(f.product_group or 'General', {})
        pg.setdefault(f.category or 'General', []).append(f)

    license_feature_ids = {f.id for f in license.features}

    return render_template('admin/edit_license.html',
        license=license,
        tiers=tiers,
        customers=customers,
        grouped_features=grouped_features,
        license_feature_ids=license_feature_ids
    )


@bp.route('/licenses/<int:id>/status', methods=['POST'])
@login_required
def change_license_status(id):
    """Change license status"""
    license = License.query.get_or_404(id)
    new_status = request.form.get('status')
    
    if new_status in ['active', 'suspended', 'revoked']:
        old_status = license.status
        license.status = new_status
        db.session.commit()
        
        log_activity('change_status', 'license', license.id, 
            f'Changed status from {old_status} to {new_status}')
        
        flash(f'License status changed to {new_status}', 'success')
    
    return redirect(url_for('lic_admin.view_license', id=license.id))


@bp.route('/licenses/<int:id>/extend', methods=['POST'])
@login_required
def extend_license(id):
    """Extend license expiration"""
    license = License.query.get_or_404(id)
    days = request.form.get('days', 30, type=int)
    
    if license.expires_at:
        base_date = max(license.expires_at, datetime.utcnow())
    else:
        base_date = datetime.utcnow()
    
    license.expires_at = base_date + timedelta(days=days)
    db.session.commit()
    
    log_activity('extend_license', 'license', license.id, f'Extended by {days} days')
    
    flash(f'License extended by {days} days', 'success')
    return redirect(url_for('lic_admin.view_license', id=license.id))


@bp.route('/licenses/<int:id>/reset-activations', methods=['POST'])
@login_required
def reset_activations(id):
    """Reset license activations"""
    license = License.query.get_or_404(id)
    
    # Deactivate all activations
    LicenseActivation.query.filter_by(license_id=license.id, is_active=True).update({
        'is_active': False,
        'deactivated_at': datetime.utcnow()
    })
    license.current_activations = 0
    db.session.commit()
    
    log_activity('reset_activations', 'license', license.id, 'Reset all activations')
    
    flash('Activations reset', 'success')
    return redirect(url_for('lic_admin.view_license', id=license.id))


# ==================== CUSTOMERS ====================

@bp.route('/customers')
@login_required
def customers():
    """List all customers"""
    page = request.args.get('page', 1, type=int)
    search = request.args.get('search', '')
    
    query = Customer.query
    
    if search:
        query = query.filter(
            (Customer.email.ilike(f'%{search}%')) |
            (Customer.company_name.ilike(f'%{search}%')) |
            (Customer.contact_name.ilike(f'%{search}%'))
        )
    
    customers = query.order_by(Customer.created_at.desc()).paginate(page=page, per_page=20)
    
    return render_template('admin/customers.html', customers=customers, search=search)


@bp.route('/customers/create', methods=['GET', 'POST'])
@login_required
def create_customer():
    """Create a new customer"""
    if request.method == 'POST':
        email = request.form.get('email', '').lower()
        
        if Customer.query.filter_by(email=email).first():
            flash('Email already exists', 'error')
            return redirect(url_for('lic_admin.create_customer'))
        
        customer = Customer(
            email=email,
            company_name=request.form.get('company_name'),
            contact_name=request.form.get('contact_name'),
            phone=request.form.get('phone'),
            address=request.form.get('address'),
            notes=request.form.get('notes')
        )
        
        db.session.add(customer)
        db.session.commit()
        
        log_activity('create_customer', 'customer', customer.id, f'Created customer {email}')
        
        flash('Customer created', 'success')
        return redirect(url_for('lic_admin.view_customer', id=customer.id))
    
    return render_template('admin/create_customer.html')


@bp.route('/customers/<int:id>')
@login_required
def view_customer(id):
    """View customer details"""
    customer = Customer.query.get_or_404(id)
    licenses = customer.licenses.order_by(License.created_at.desc()).all()
    
    return render_template('admin/view_customer.html',
        customer=customer,
        licenses=licenses
    )


@bp.route('/customers/<int:id>/edit', methods=['GET', 'POST'])
@login_required
def edit_customer(id):
    """Edit customer"""
    customer = Customer.query.get_or_404(id)
    
    if request.method == 'POST':
        customer.company_name = request.form.get('company_name')
        customer.contact_name = request.form.get('contact_name')
        customer.phone = request.form.get('phone')
        customer.address = request.form.get('address')
        customer.notes = request.form.get('notes')
        customer.is_active = 'is_active' in request.form
        
        db.session.commit()
        
        flash('Customer updated', 'success')
        return redirect(url_for('lic_admin.view_customer', id=customer.id))
    
    return render_template('admin/edit_customer.html', customer=customer)


# ==================== PRODUCTS & TIERS ====================

@bp.route('/products')
@login_required
def products():
    """List products and tiers"""
    products = Product.query.all()
    return render_template('admin/products.html', products=products)


@bp.route('/products/<int:id>/tiers', methods=['GET', 'POST'])
@login_required
def edit_tiers(id):
    """Edit product tiers"""
    product = Product.query.get_or_404(id)
    all_features = Feature.query.filter_by(is_active=True).order_by(Feature.category, Feature.name).all()

    if request.method == 'POST':
        tier_id = request.form.get('tier_id')
        tier = ProductTier.query.get(tier_id)

        if tier and tier.product_id == product.id:
            tier.name = request.form.get('name')
            tier.price_monthly = request.form.get('price_monthly', 0, type=float)
            tier.price_yearly = request.form.get('price_yearly', 0, type=float)
            tier.max_users = request.form.get('max_users', 0, type=int)

            # Build features dict from Feature table codes
            selected = set(request.form.getlist('lic_features'))
            tier.features = {f.code: (f.code in selected) for f in all_features}

            db.session.commit()
            flash('Tier updated', 'success')

        return redirect(url_for('lic_admin.edit_tiers', id=product.id))

    return render_template('admin/edit_tiers.html', product=product, all_features=all_features)


# ==================== ACTIVITY LOG ====================

@bp.route('/activity')
@login_required
def activity_log():
    """View activity log"""
    page = request.args.get('page', 1, type=int)
    logs = ActivityLog.query.order_by(ActivityLog.created_at.desc()).paginate(page=page, per_page=50)
    
    return render_template('admin/activity_log.html', logs=logs)


# ==================== BULK OPERATIONS ====================

@bp.route('/licenses/bulk-create', methods=['GET', 'POST'])
@login_required
def bulk_create_licenses():
    """Create multiple licenses at once"""
    products = Product.query.filter_by(is_active=True).all()
    tiers = ProductTier.query.filter_by(is_active=True).all()
    
    if request.method == 'POST':
        count = request.form.get('count', 1, type=int)
        count = min(count, 100)  # Max 100 at once
        
        product_id = request.form.get('product_id')
        tier_id = request.form.get('tier_id')
        
        duration = request.form.get('duration')
        expires_at = None
        if duration == 'monthly':
            expires_at = datetime.utcnow() + timedelta(days=30)
        elif duration == 'yearly':
            expires_at = datetime.utcnow() + timedelta(days=365)
        
        created_keys = []
        for _ in range(count):
            while True:
                license_key = License.generate_key()
                if not License.query.filter_by(license_key=license_key).first():
                    break
            
            license = License(
                license_key=license_key,
                product_id=product_id,
                tier_id=tier_id,
                max_activations=1,
                expires_at=expires_at,
                created_by=current_user.id
            )
            db.session.add(license)
            created_keys.append(license_key)
        
        db.session.commit()
        
        log_activity('bulk_create', 'license', None, f'Created {count} licenses')
        
        flash(f'{count} licenses created', 'success')
        return render_template('admin/bulk_result.html', keys=created_keys)
    
    return render_template('admin/bulk_create.html', products=products, tiers=tiers)


# ==================== API for AJAX ====================

@bp.route('/api/tiers/<int:product_id>')
@login_required
def get_tiers(product_id):
    """Get tiers for a product (AJAX)"""
    tiers = ProductTier.query.filter_by(product_id=product_id, is_active=True).all()
    return jsonify([{
        'id': t.id,
        'name': t.name,
        'code': t.code,
        'max_users': t.max_users
    } for t in tiers])


# ==================== PRODUCT MANAGEMENT ====================

@bp.route('/products/create', methods=['GET', 'POST'])
@login_required
def create_product():
    """Create a new product"""
    if request.method == 'POST':
        code = request.form.get('code', '').upper().replace(' ', '_')

        if Product.query.filter_by(code=code).first():
            flash('Product code already exists', 'error')
            return redirect(url_for('lic_admin.create_product'))

        product = Product(
            name=request.form.get('name'),
            code=code,
            description=request.form.get('description'),
            require_ip_lock='require_ip_lock' in request.form,
            max_ip_addresses=request.form.get('max_ip_addresses', 1, type=int),
            allow_ip_change='allow_ip_change' in request.form,
            ip_change_cooldown=request.form.get('ip_change_cooldown', 24, type=int)
        )
        db.session.add(product)
        db.session.commit()

        log_activity('create_product', 'product', product.id, f'Created product {product.name}')
        flash(f'Product "{product.name}" created', 'success')
        # Redirect to kit page so user gets the integration code immediately
        return redirect(url_for('lic_admin.product_kit', id=product.id))

    return render_template('admin/create_product.html')


@bp.route('/products/<int:id>/edit', methods=['GET', 'POST'])
@login_required
def edit_product(id):
    """Edit a product"""
    product = Product.query.get_or_404(id)
    
    if request.method == 'POST':
        product.name = request.form.get('name')
        product.description = request.form.get('description')
        product.require_ip_lock = 'require_ip_lock' in request.form
        product.max_ip_addresses = request.form.get('max_ip_addresses', 1, type=int)
        product.allow_ip_change = 'allow_ip_change' in request.form
        product.ip_change_cooldown = request.form.get('ip_change_cooldown', 24, type=int)
        product.is_active = 'is_active' in request.form
        
        db.session.commit()
        log_activity('edit_product', 'product', product.id, f'Updated product {product.name}')
        flash('Product updated', 'success')
        return redirect(url_for('lic_admin.products'))
    
    return render_template('admin/edit_product.html', product=product)


@bp.route('/products/<int:id>/delete', methods=['POST'])
@login_required
def delete_product(id):
    """Delete a product"""
    product = Product.query.get_or_404(id)
    
    # Check if product has licenses
    if product.licenses.count() > 0:
        flash(f'Cannot delete: {product.licenses.count()} licenses exist for this product', 'error')
        return redirect(url_for('lic_admin.products'))
    
    name = product.name
    
    # Delete tiers first
    ProductTier.query.filter_by(product_id=product.id).delete()
    db.session.delete(product)
    db.session.commit()
    
    log_activity('delete_product', 'product', id, f'Deleted product {name}')
    flash(f'Product "{name}" deleted', 'success')
    return redirect(url_for('lic_admin.products'))


@bp.route('/products/<int:product_id>/tiers/create', methods=['GET', 'POST'])
@login_required
def create_tier(product_id):
    """Create a new tier for a product"""
    product = Product.query.get_or_404(product_id)
    all_features = Feature.query.filter_by(is_active=True).order_by(Feature.category, Feature.name).all()

    if request.method == 'POST':
        # Build features dict from Feature table codes
        selected = set(request.form.getlist('lic_features'))
        features = {f.code: (f.code in selected) for f in all_features}

        tier = ProductTier(
            product_id=product.id,
            name=request.form.get('name'),
            code=request.form.get('code', '').lower().replace(' ', '_'),
            price_monthly=request.form.get('price_monthly', 0, type=float),
            price_yearly=request.form.get('price_yearly', 0, type=float),
            max_users=request.form.get('max_users', 0, type=int),
            sort_order=request.form.get('sort_order', 0, type=int),
            features=features
        )

        db.session.add(tier)
        db.session.commit()

        log_activity('create_tier', 'tier', tier.id, f'Created tier {tier.name} for {product.name}')
        flash(f'Tier "{tier.name}" created', 'success')
        return redirect(url_for('lic_admin.edit_tiers', id=product.id))

    return render_template('admin/create_tier.html', product=product, all_features=all_features)


@bp.route('/tiers/<int:id>/delete', methods=['POST'])
@login_required
def delete_tier(id):
    """Delete a tier"""
    tier = ProductTier.query.get_or_404(id)
    product_id = tier.product_id
    
    # Check if tier has licenses
    if tier.licenses.count() > 0:
        flash(f'Cannot delete: {tier.licenses.count()} licenses use this tier', 'error')
        return redirect(url_for('lic_admin.edit_tiers', id=product_id))
    
    name = tier.name
    db.session.delete(tier)
    db.session.commit()
    
    flash(f'Tier "{name}" deleted', 'success')
    return redirect(url_for('lic_admin.edit_tiers', id=product_id))



@bp.route('/licenses/<int:id>/ips', methods=['GET', 'POST'])
@login_required
def manage_license_ips(id):
    """Manage allowed IPs for a license"""
    license = License.query.get_or_404(id)
    
    if request.method == 'POST':
        action = request.form.get('action')
        
        if action == 'add':
            ip = request.form.get('ip', '').strip()
            if ip:
                allowed_ips = license.allowed_ips or []
                if ip not in allowed_ips:
                    allowed_ips.append(ip)
                    license.allowed_ips = allowed_ips
                    db.session.commit()
                    log_activity('add_ip', 'license', license.id, f'Added IP {ip}')
                    flash(f'IP {ip} added', 'success')
                else:
                    flash('IP already in list', 'warning')
        
        elif action == 'remove':
            ip = request.form.get('ip', '').strip()
            if ip:
                allowed_ips = license.allowed_ips or []
                if ip in allowed_ips:
                    allowed_ips.remove(ip)
                    license.allowed_ips = allowed_ips
                    db.session.commit()
                    log_activity('remove_ip', 'license', license.id, f'Removed IP {ip}')
                    flash(f'IP {ip} removed', 'success')
        
        elif action == 'clear':
            license.allowed_ips = []
            db.session.commit()
            log_activity('clear_ips', 'license', license.id, 'Cleared all IPs')
            flash('All IPs cleared', 'success')
        
        return redirect(url_for('lic_admin.manage_license_ips', id=license.id))
    
    return render_template('admin/manage_ips.html', license=license)


@bp.route('/licenses/<int:id>/delete', methods=['POST'])
@login_required
def delete_license(id):
    """Delete a license"""
    license = License.query.get_or_404(id)
    license_key = license.license_key
    
    # Delete related records
    LicenseActivation.query.filter_by(license_id=license.id).delete()
    
    # Delete IP history if exists
    from app.models import LicenseIPHistory
    LicenseIPHistory.query.filter_by(license_id=license.id).delete()
    
    db.session.delete(license)
    db.session.commit()
    
    log_activity('delete_license', 'license', id, f'Deleted license {license_key}')
    flash(f'License {license_key} deleted', 'success')
    return redirect(url_for('lic_admin.licenses'))


@bp.route('/licenses/<int:id>/purge', methods=['POST'])
@login_required
def purge_license(id):
    """Purge all data for a license (IPs, activations, history) but keep license"""
    license = License.query.get_or_404(id)
    
    # Clear activations
    LicenseActivation.query.filter_by(license_id=license.id).delete()
    license.current_activations = 0
    
    # Clear IP history
    from app.models import LicenseIPHistory
    LicenseIPHistory.query.filter_by(license_id=license.id).delete()
    
    # Clear allowed IPs
    license.allowed_ips = []
    license.last_ip_change = None
    
    db.session.commit()
    
    log_activity('purge_license', 'license', license.id, f'Purged all data for {license.license_key}')
    flash(f'License {license.license_key} purged', 'success')
    return redirect(url_for('lic_admin.view_license', id=license.id))



# ==================== BULK LICENSE ACTIONS ====================

@bp.route('/licenses/bulk-action', methods=['POST'])
@login_required
def bulk_license_action():
    """Perform bulk actions on licenses"""
    action = request.form.get('action')
    license_ids = request.form.getlist('license_ids')
    
    if not license_ids:
        flash('No licenses selected', 'warning')
        return redirect(url_for('lic_admin.licenses'))
    
    count = 0
    
    if action == 'delete':
        for lid in license_ids:
            license = License.query.get(lid)
            if license:
                LicenseActivation.query.filter_by(license_id=license.id).delete()
                from app.models import LicenseIPHistory
                LicenseIPHistory.query.filter_by(license_id=license.id).delete()
                db.session.delete(license)
                count += 1
        db.session.commit()
        log_activity('bulk_delete', 'license', None, f'Deleted {count} licenses')
        flash(f'{count} licenses deleted', 'success')
    
    elif action == 'purge':
        for lid in license_ids:
            license = License.query.get(lid)
            if license:
                LicenseActivation.query.filter_by(license_id=license.id).delete()
                from app.models import LicenseIPHistory
                LicenseIPHistory.query.filter_by(license_id=license.id).delete()
                license.allowed_ips = []
                license.current_activations = 0
                license.last_ip_change = None
                count += 1
        db.session.commit()
        log_activity('bulk_purge', 'license', None, f'Purged {count} licenses')
        flash(f'{count} licenses purged', 'success')
    
    elif action == 'suspend':
        for lid in license_ids:
            license = License.query.get(lid)
            if license and license.status == 'active':
                license.status = 'suspended'
                count += 1
        db.session.commit()
        log_activity('bulk_suspend', 'license', None, f'Suspended {count} licenses')
        flash(f'{count} licenses suspended', 'success')
    
    elif action == 'activate':
        for lid in license_ids:
            license = License.query.get(lid)
            if license and license.status != 'active':
                license.status = 'active'
                count += 1
        db.session.commit()
        log_activity('bulk_activate', 'license', None, f'Activated {count} licenses')
        flash(f'{count} licenses activated', 'success')
    
    elif action == 'revoke':
        for lid in license_ids:
            license = License.query.get(lid)
            if license:
                license.status = 'revoked'
                count += 1
        db.session.commit()
        log_activity('bulk_revoke', 'license', None, f'Revoked {count} licenses')
        flash(f'{count} licenses revoked', 'success')
    
    elif action == 'clear_ips':
        for lid in license_ids:
            license = License.query.get(lid)
            if license:
                license.allowed_ips = []
                count += 1
        db.session.commit()
        log_activity('bulk_clear_ips', 'license', None, f'Cleared IPs for {count} licenses')
        flash(f'IPs cleared for {count} licenses', 'success')
    
    return redirect(url_for('lic_admin.licenses'))


@bp.route('/licenses/delete-all', methods=['POST'])
@login_required
def delete_all_licenses():
    """Delete ALL licenses - dangerous!"""
    confirm = request.form.get('confirm')
    
    if confirm != 'DELETE ALL':
        flash('Please type "DELETE ALL" to confirm', 'error')
        return redirect(url_for('lic_admin.licenses'))
    
    # Delete all related data
    LicenseActivation.query.delete()
    from app.models import LicenseIPHistory
    LicenseIPHistory.query.delete()
    
    count = License.query.count()
    License.query.delete()
    db.session.commit()
    
    log_activity('delete_all', 'license', None, f'Deleted ALL {count} licenses')
    flash(f'All {count} licenses deleted', 'success')
    return redirect(url_for('lic_admin.licenses'))


# ==================== SETTINGS ====================

@bp.route('/settings', methods=['GET', 'POST'])
@login_required
def settings():
    """System settings"""
    from app.models import Settings
    
    if request.method == 'POST':
        for key in request.form:
            if key != 'csrf_token':
                Settings.set(key, request.form[key])
        
        log_activity('update_settings', 'lic_settings', None, 'Updated system settings')
        flash('Settings saved', 'success')
        return redirect(url_for('lic_admin.settings'))
    
    settings_by_category = Settings.get_all_by_category()
    return render_template('admin/settings.html', settings_by_category=settings_by_category)


# ==================== ROLES ====================

@bp.route('/roles')
@login_required
def roles():
    """List all roles"""
    from app.models import Role
    roles = Role.query.order_by(Role.name).all()
    return render_template('admin/roles.html', roles=roles)


@bp.route('/roles/create', methods=['GET', 'POST'])
@login_required
def create_role():
    """Create a new role"""
    from app.models import Role, Permission
    
    if request.method == 'POST':
        name = request.form.get('name')
        
        if Role.query.filter_by(name=name).first():
            flash('Role name already exists', 'error')
            return redirect(url_for('lic_admin.create_role'))
        
        role = Role(
            name=name,
            description=request.form.get('description'),
            color=request.form.get('color', 'gray')
        )
        
        # Add permissions
        perm_ids = request.form.getlist('lic_permissions')
        role.permissions = Permission.query.filter(Permission.id.in_(perm_ids)).all()
        
        db.session.add(role)
        db.session.commit()
        
        log_activity('create_role', 'role', role.id, f'Created role {name}')
        flash(f'Role "{name}" created', 'success')
        return redirect(url_for('lic_admin.roles'))
    
    permissions = Permission.get_all_by_category()
    return render_template('admin/create_role.html', permissions=permissions)


@bp.route('/roles/<int:id>/edit', methods=['GET', 'POST'])
@login_required
def edit_role(id):
    """Edit a role"""
    from app.models import Role, Permission
    
    role = Role.query.get_or_404(id)
    
    if request.method == 'POST':
        role.name = request.form.get('name')
        role.description = request.form.get('description')
        role.color = request.form.get('color', 'gray')
        
        # Update permissions
        perm_ids = request.form.getlist('lic_permissions')
        role.permissions = Permission.query.filter(Permission.id.in_(perm_ids)).all()
        
        db.session.commit()
        
        log_activity('edit_role', 'role', role.id, f'Updated role {role.name}')
        flash('Role updated', 'success')
        return redirect(url_for('lic_admin.roles'))
    
    permissions = Permission.get_all_by_category()
    return render_template('admin/edit_role.html', role=role, permissions=permissions)


@bp.route('/roles/<int:id>/delete', methods=['POST'])
@login_required
def delete_role(id):
    """Delete a role"""
    from app.models import Role
    
    role = Role.query.get_or_404(id)
    
    if role.is_system:
        flash('Cannot delete system role', 'error')
        return redirect(url_for('lic_admin.roles'))
    
    if role.users:
        flash(f'Cannot delete: {len(role.users)} users have this role', 'error')
        return redirect(url_for('lic_admin.roles'))
    
    name = role.name
    db.session.delete(role)
    db.session.commit()
    
    log_activity('delete_role', 'role', id, f'Deleted role {name}')
    flash(f'Role "{name}" deleted', 'success')
    return redirect(url_for('lic_admin.roles'))


# ==================== ADMIN USERS ====================

@bp.route('/users')
@login_required
def admin_users():
    """List admin users"""
    users = AdminUser.query.order_by(AdminUser.name).all()
    return render_template('admin/users.html', users=users)


@bp.route('/users/create', methods=['GET', 'POST'])
@login_required
def create_admin_user():
    """Create a new admin user"""
    from app.models import Role
    
    if request.method == 'POST':
        email = request.form.get('email', '').lower()
        
        if AdminUser.query.filter_by(email=email).first():
            flash('Email already exists', 'error')
            return redirect(url_for('lic_admin.create_admin_user'))
        
        user = AdminUser(
            email=email,
            name=request.form.get('name'),
            is_superadmin='is_superadmin' in request.form,
            avatar_color=request.form.get('avatar_color', 'emerald')
        )
        user.set_password(request.form.get('password'))
        
        # Add roles
        role_ids = request.form.getlist('lic_roles')
        user.roles = Role.query.filter(Role.id.in_(role_ids)).all()
        
        db.session.add(user)
        db.session.commit()
        
        log_activity('create_user', 'admin_user', user.id, f'Created admin user {email}')
        flash(f'User "{user.name}" created', 'success')
        return redirect(url_for('lic_admin.admin_users'))
    
    roles = Role.query.order_by(Role.name).all()
    return render_template('admin/create_user.html', roles=roles)


@bp.route('/users/<int:id>/edit', methods=['GET', 'POST'])
@login_required
def edit_admin_user(id):
    """Edit an admin user"""
    from app.models import Role
    
    user = AdminUser.query.get_or_404(id)
    
    if request.method == 'POST':
        user.name = request.form.get('name')
        user.is_superadmin = 'is_superadmin' in request.form
        user.is_active = 'is_active' in request.form
        user.avatar_color = request.form.get('avatar_color', 'emerald')
        
        # Update password if provided
        new_password = request.form.get('password')
        if new_password:
            user.set_password(new_password)
        
        # Update roles
        role_ids = request.form.getlist('lic_roles')
        user.roles = Role.query.filter(Role.id.in_(role_ids)).all()
        
        db.session.commit()
        
        log_activity('edit_user', 'admin_user', user.id, f'Updated admin user {user.email}')
        flash('User updated', 'success')
        return redirect(url_for('lic_admin.admin_users'))
    
    roles = Role.query.order_by(Role.name).all()
    return render_template('admin/edit_user.html', user=user, roles=roles)


@bp.route('/users/<int:id>/delete', methods=['POST'])
@login_required
def delete_admin_user(id):
    """Delete an admin user"""
    user = AdminUser.query.get_or_404(id)
    
    if user.id == current_user.id:
        flash('Cannot delete your own account', 'error')
        return redirect(url_for('lic_admin.admin_users'))
    
    email = user.email
    db.session.delete(user)
    db.session.commit()
    
    log_activity('delete_user', 'admin_user', id, f'Deleted admin user {email}')
    flash(f'User deleted', 'success')
    return redirect(url_for('lic_admin.admin_users'))


# ==================== FEATURES ====================

@bp.route('/features')
@login_required
def features():
    """List all features"""
    from app.models import Feature
    all_features = Feature.query.order_by(Feature.product_group, Feature.category, Feature.name).all()
    grouped = Feature.grouped()
    return render_template('admin/features.html', features=all_features, grouped=grouped)


@bp.route('/features/create', methods=['GET', 'POST'])
@login_required
def create_feature():
    """Create a new feature"""
    from app.models import Feature
    if request.method == 'POST':
        code         = request.form.get('code', '').strip().lower().replace(' ', '_')
        name         = request.form.get('name', '').strip()
        description  = request.form.get('description', '').strip()
        product_group = request.form.get('product_group', 'General').strip()
        category     = request.form.get('category', 'Core').strip()
        icon         = request.form.get('icon', 'puzzle').strip()

        if not code or not name:
            flash('Code and name are required', 'error')
            return redirect(url_for('lic_admin.create_feature'))

        if Feature.query.filter_by(code=code).first():
            flash(f'Feature code "{code}" already exists', 'error')
            return redirect(url_for('lic_admin.create_feature'))

        feature = Feature(
            code=code, name=name, description=description,
            product_group=product_group, category=category, icon=icon
        )
        db.session.add(feature)
        db.session.commit()
        log_activity('create_feature', 'feature', feature.id, f'Created feature {name}')
        flash(f'Feature "{name}" created', 'success')
        return redirect(url_for('lic_admin.features'))

    return render_template('admin/create_feature.html')


@bp.route('/features/<int:id>/edit', methods=['GET', 'POST'])
@login_required
def edit_feature(id):
    """Edit a feature"""
    from app.models import Feature
    feature = Feature.query.get_or_404(id)

    if request.method == 'POST':
        feature.name          = request.form.get('name', feature.name).strip()
        feature.description   = request.form.get('description', '').strip()
        feature.product_group = request.form.get('product_group', 'General').strip()
        feature.category      = request.form.get('category', 'Core').strip()
        feature.icon          = request.form.get('icon', 'puzzle').strip()
        feature.is_active     = request.form.get('is_active') == 'on'
        db.session.commit()
        log_activity('edit_feature', 'feature', feature.id, f'Edited feature {feature.name}')
        flash('Feature updated', 'success')
        return redirect(url_for('lic_admin.features'))

    return render_template('admin/edit_feature.html', feature=feature)


@bp.route('/features/<int:id>/delete', methods=['POST'])
@login_required
def delete_feature(id):
    """Delete a feature"""
    from app.models import Feature
    feature = Feature.query.get_or_404(id)
    name = feature.name
    db.session.delete(feature)
    db.session.commit()
    log_activity('delete_feature', 'feature', id, f'Deleted feature {name}')
    flash(f'Feature "{name}" deleted', 'success')
    return redirect(url_for('lic_admin.features'))


@bp.route('/features/<int:id>/toggle', methods=['POST'])
@login_required
def toggle_feature(id):
    """Toggle feature active state"""
    from app.models import Feature
    feature = Feature.query.get_or_404(id)
    feature.is_active = not feature.is_active
    db.session.commit()
    return jsonify({'active': feature.is_active, 'name': feature.name})


# ==================== API EXPLORER ====================

@bp.route('/api-explorer')
@login_required
def api_explorer():
    """Live API Explorer page"""
    from app.models import Settings
    base_url = request.host_url.rstrip('/')
    return render_template('admin/api_explorer.html', base_url=base_url)


# ==================== PRODUCT KIT ====================

@bp.route('/products/<int:id>/kit')
@login_required
def product_kit(id):
    """Integration code kit for a product"""
    product = Product.query.get_or_404(id)
    base_url = request.host_url.rstrip('/')
    return render_template('admin/product_kit.html', product=product, base_url=base_url)
OPSLAB_LIC_EOF__7f2d8a5e

say "Writing app/licenses/api.py"
write_file 'app/licenses/api.py' << 'OPSLAB_LIC_EOF__7f2d8a5e'
"""
License Manager - API Endpoints
"""
from flask import Blueprint, request, jsonify
from datetime import datetime
from .. import db   # shared with OpsLabs
from .models import License, LicenseActivation, ActivityLog

bp = Blueprint('lic_api', __name__)


@bp.route('/validate', methods=['POST'])
def validate_license():
    data = request.get_json()
    
    if not data:
        return jsonify({'valid': False, 'error': 'No data provided'}), 400
    
    license_key = data.get('license_key', '').strip().upper()
    hardware_id = data.get('hardware_id', '')
    domain = data.get('domain', '')
    
    if not license_key:
        return jsonify({'valid': False, 'error': 'No license key provided'}), 400
    
    license = License.query.filter_by(license_key=license_key).first()
    
    if not license:
        return jsonify({'valid': False, 'error': 'Invalid license key'}), 200
    
    if license.status == 'revoked':
        return jsonify({'valid': False, 'error': 'License has been revoked'}), 200
    
    if license.status == 'suspended':
        return jsonify({'valid': False, 'error': 'License has been suspended'}), 200
    
    if license.status != 'active':
        return jsonify({'valid': False, 'error': f'License status: {license.status}'}), 200
    
    if license.is_expired:
        return jsonify({'valid': False, 'error': 'License has expired'}), 200
    
    if license.domain and domain:
        license_domain = license.domain.lower().strip()
        check_domain = domain.lower().split(':')[0].strip()
        if not (check_domain == license_domain or check_domain.endswith('.' + license_domain)):
            return jsonify({'valid': False, 'error': f'License not valid for domain: {domain}'}), 200
    
    if False:  # hardware_id checked on activation
        if False:
            return jsonify({'valid': False, 'error': 'License not valid for this server'}), 200
    
    activation = LicenseActivation.query.filter_by(license_id=license.id, is_active=True).first()
    if activation:
        activation.last_check = datetime.utcnow()
        if hardware_id:
            activation.hardware_id = hardware_id
        if domain:
            activation.domain = domain
        activation.ip_address = request.remote_addr
        db.session.commit()
    
    features = []
    if license.tier and license.tier.features:
        for feature, enabled in license.tier.features.items():
            if enabled:
                features.append(feature)
    
    response = {
        'valid': True,
        'product': license.product.code if license.product else None,
        'tier': license.tier.code if license.tier else None,
        'tier_name': license.tier.name if license.tier else None,
        'max_users': license.tier.max_users if license.tier else 0,
        'features': features,
        'expires_at': license.expires_at.isoformat() if license.expires_at else None,
        'days_until_expiry': license.days_until_expiry,
        'customer': license.customer.company_name if license.customer else None
    }
    
    return jsonify(response), 200


@bp.route('/activate', methods=['POST'])
def activate_license():
    data = request.get_json()
    
    if not data:
        return jsonify({'success': False, 'error': 'No data provided'}), 400
    
    license_key = data.get('license_key', '').strip().upper()
    hardware_id = data.get('hardware_id', '')
    hostname = data.get('hostname', '')
    domain = data.get('domain', '')
    
    if not license_key:
        return jsonify({'success': False, 'error': 'No license key provided'}), 400
    
    license = License.query.filter_by(license_key=license_key).first()
    
    if not license:
        return jsonify({'success': False, 'error': 'Invalid license key'}), 200
    
    if not license.is_valid:
        return jsonify({'success': False, 'error': 'License is not valid'}), 200
    
    active_count = LicenseActivation.query.filter_by(license_id=license.id, is_active=True).count()
    
    existing = None
    if hardware_id:
        existing = LicenseActivation.query.filter_by(license_id=license.id, hardware_id=hardware_id, is_active=True).first()
    
    if existing:
        existing.last_check = datetime.utcnow()
        existing.domain = domain
        existing.ip_address = request.remote_addr
        db.session.commit()
        return jsonify({'success': True, 'activation_id': existing.id, 'message': 'Activation updated'}), 200
    
    if license.max_activations > 0 and active_count >= license.max_activations:
        return jsonify({'success': False, 'error': f'Maximum activations reached ({license.max_activations})'}), 200
    
    activation = LicenseActivation(
        license_id=license.id,
        domain=domain,
        ip_address=request.remote_addr,
        hardware_id=hardware_id,
        server_info={'hostname': hostname}
    )
    db.session.add(activation)
    
    license.current_activations = active_count + 1
    if not license.activated_at:
        license.activated_at = datetime.utcnow()
    
    if not license.hardware_id and hardware_id:
        license.hardware_id = hardware_id
    
    if not license.domain and domain:
        license.domain = domain
    
    db.session.commit()
    
    return jsonify({'success': True, 'activation_id': activation.id, 'message': 'License activated successfully'}), 200


@bp.route('/health', methods=['GET'])
def health_check():
    return jsonify({'status': 'ok', 'timestamp': datetime.utcnow().isoformat(), 'service': 'License Manager API'}), 200
OPSLAB_LIC_EOF__7f2d8a5e

say "Writing app/licenses/auth.py"
write_file 'app/licenses/auth.py' << 'OPSLAB_LIC_EOF__7f2d8a5e'
"""
License Manager - Authentication Routes
"""
from flask import Blueprint, render_template, redirect, url_for, flash, request
from flask_login import login_user, logout_user, current_user, login_required
from datetime import datetime
from .. import db   # shared with OpsLabs
from .models import AdminUser

bp = Blueprint('lic_auth', __name__)


@bp.route('/login', methods=['GET', 'POST'])
def login():
    if current_user.is_authenticated:
        return redirect(url_for('lic_admin.dashboard'))
    
    if request.method == 'POST':
        email = request.form.get('email', '').lower()
        password = request.form.get('password', '')
        remember = 'remember' in request.form
        
        user = AdminUser.query.filter_by(email=email).first()
        
        if user is None or not user.check_password(password):
            flash('Invalid email or password', 'error')
            return redirect(url_for('lic_auth.login'))
        
        if not user.is_active:
            flash('Account disabled', 'error')
            return redirect(url_for('lic_auth.login'))
        
        user.last_login = datetime.utcnow()
        db.session.commit()
        
        login_user(user, remember=remember)
        
        next_page = request.args.get('next')
        if not next_page or not next_page.startswith('/'):
            next_page = url_for('lic_admin.dashboard')
        
        return redirect(next_page)
    
    return render_template('auth/login.html')


@bp.route('/logout')
@login_required
def logout():
    logout_user()
    flash('Logged out', 'info')
    return redirect(url_for('lic_auth.login'))


@bp.route('/profile', methods=['GET', 'POST'])
@login_required
def profile():
    if request.method == 'POST':
        current_user.name = request.form.get('name')
        
        new_password = request.form.get('new_password')
        if new_password:
            current_password = request.form.get('current_password')
            if not current_user.check_password(current_password):
                flash('Current password is incorrect', 'error')
                return redirect(url_for('lic_auth.profile'))
            current_user.set_password(new_password)
        
        db.session.commit()
        flash('Profile updated', 'success')
        return redirect(url_for('lic_auth.profile'))
    
    return render_template('auth/profile.html')
OPSLAB_LIC_EOF__7f2d8a5e

say "Writing app/licenses/customer.py"
write_file 'app/licenses/customer.py' << 'OPSLAB_LIC_EOF__7f2d8a5e'
"""
License Manager - Customer Portal
"""
from flask import Blueprint, render_template, redirect, url_for, flash, request, session
from functools import wraps
from datetime import datetime
from .. import db   # shared with OpsLabs
from .models import Customer, License, LicenseActivation, LicenseIPHistory

bp = Blueprint('lic_customer', __name__)


def customer_required(f):
    @wraps(f)
    def decorated_function(*args, **kwargs):
        customer_id = session.get('customer_id')
        if not customer_id:
            return redirect(url_for('lic_customer.login'))
        customer = Customer.query.get(customer_id)
        if not customer or not customer.is_active:
            session.pop('customer_id', None)
            return redirect(url_for('lic_customer.login'))
        return f(customer, *args, **kwargs)
    return decorated_function


@bp.route('/login', methods=['GET', 'POST'])
def login():
    if session.get('customer_id'):
        return redirect(url_for('lic_customer.dashboard'))
    
    if request.method == 'POST':
        email = request.form.get('email', '').lower().strip()
        password = request.form.get('password', '')
        
        customer = Customer.query.filter_by(email=email).first()
        
        if customer and customer.check_password(password):
            if not customer.is_active:
                flash('Account is disabled', 'error')
                return redirect(url_for('lic_customer.login'))
            
            session['customer_id'] = customer.id
            customer.last_login = datetime.utcnow()
            db.session.commit()
            return redirect(url_for('lic_customer.dashboard'))
        
        flash('Invalid email or password', 'error')
    
    return render_template('customer/login.html')


@bp.route('/register', methods=['GET', 'POST'])
def register():
    if session.get('customer_id'):
        return redirect(url_for('lic_customer.dashboard'))
    
    if request.method == 'POST':
        email = request.form.get('email', '').lower().strip()
        password = request.form.get('password', '')
        company_name = request.form.get('company_name', '').strip()
        contact_name = request.form.get('contact_name', '').strip()
        
        if Customer.query.filter_by(email=email).first():
            flash('Email already registered', 'error')
            return redirect(url_for('lic_customer.register'))
        
        if len(password) < 8:
            flash('Password must be at least 8 characters', 'error')
            return redirect(url_for('lic_customer.register'))
        
        customer = Customer(email=email, company_name=company_name or None, contact_name=contact_name or None)
        customer.set_password(password)
        db.session.add(customer)
        db.session.commit()
        
        session['customer_id'] = customer.id
        flash('Account created!', 'success')
        return redirect(url_for('lic_customer.dashboard'))
    
    return render_template('customer/register.html')


@bp.route('/logout')
def logout():
    session.pop('customer_id', None)
    flash('Logged out', 'info')
    return redirect(url_for('lic_customer.login'))


@bp.route('/')
@customer_required
def dashboard(customer):
    licenses = customer.licenses.order_by(License.created_at.desc()).all()
    return render_template('customer/dashboard.html', customer=customer, licenses=licenses)


@bp.route('/license/<int:id>')
@customer_required
def view_license(customer, id):
    license = License.query.filter_by(id=id, customer_id=customer.id).first_or_404()
    activations = license.activations.order_by(LicenseActivation.activated_at.desc()).all()
    ip_history = license.ip_history.order_by(LicenseIPHistory.changed_at.desc()).limit(20).all()
    can_change_ip = license.can_change_ip()
    change_message = None
    
    return render_template('customer/view_license.html',
        customer=customer, license=license, activations=activations,
        ip_history=ip_history, can_change_ip=can_change_ip,
        change_message=change_message, current_ip=request.remote_addr)


@bp.route('/license/<int:id>/add-ip', methods=['POST'])
@customer_required
def add_ip(customer, id):
    license = License.query.filter_by(id=id, customer_id=customer.id).first_or_404()
    
    can_change, message = license.can_change_ip()
    if not can_change:
        flash(message, 'error')
        return redirect(url_for('lic_customer.view_license', id=id))
    
    ip = request.form.get('ip_address', '').strip() or request.remote_addr
    
    if not license.allowed_ips:
        license.allowed_ips = []
    
    if ip in license.allowed_ips:
        flash('IP already in list', 'info')
        return redirect(url_for('lic_customer.view_license', id=id))
    
    if len(license.allowed_ips) >= license.product.max_ip_addresses:
        flash(f'Maximum {license.product.max_ip_addresses} IPs allowed', 'error')
        return redirect(url_for('lic_customer.view_license', id=id))
    
    license.allowed_ips = license.allowed_ips + [ip]
    license.last_ip_change = datetime.utcnow()
    
    history = LicenseIPHistory(license_id=license.id, ip_address=ip, action='added', changed_by='customer')
    db.session.add(history)
    db.session.commit()
    
    flash(f'IP {ip} added', 'success')
    return redirect(url_for('lic_customer.view_license', id=id))


@bp.route('/license/<int:id>/remove-ip', methods=['POST'])
@customer_required
def remove_ip(customer, id):
    license = License.query.filter_by(id=id, customer_id=customer.id).first_or_404()
    
    can_change, message = license.can_change_ip()
    if not can_change:
        flash(message, 'error')
        return redirect(url_for('lic_customer.view_license', id=id))
    
    ip = request.form.get('ip_address', '').strip()
    
    if license.allowed_ips and ip in license.allowed_ips:
        license.allowed_ips = [i for i in license.allowed_ips if i != ip]
        license.last_ip_change = datetime.utcnow()
        
        history = LicenseIPHistory(license_id=license.id, ip_address=ip, action='removed', changed_by='customer')
        db.session.add(history)
        db.session.commit()
        flash(f'IP {ip} removed', 'success')
    else:
        flash('IP not found', 'error')
    
    return redirect(url_for('lic_customer.view_license', id=id))


@bp.route('/license/<int:id>/use-current-ip', methods=['POST'])
@customer_required
def use_current_ip(customer, id):
    license = License.query.filter_by(id=id, customer_id=customer.id).first_or_404()
    
    can_change, message = license.can_change_ip()
    if not can_change:
        flash(message, 'error')
        return redirect(url_for('lic_customer.view_license', id=id))
    
    current_ip = request.remote_addr
    old_ips = license.allowed_ips or []
    
    license.allowed_ips = [current_ip]
    license.last_ip_change = datetime.utcnow()
    
    for old_ip in old_ips:
        if old_ip != current_ip:
            db.session.add(LicenseIPHistory(license_id=license.id, ip_address=old_ip, action='removed', changed_by='customer'))
    
    db.session.add(LicenseIPHistory(license_id=license.id, ip_address=current_ip, action='added', changed_by='customer'))
    db.session.commit()
    
    flash(f'License locked to IP: {current_ip}', 'success')
    return redirect(url_for('lic_customer.view_license', id=id))


@bp.route('/activate', methods=['GET', 'POST'])
@customer_required
def activate_license(customer):
    if request.method == 'POST':
        key = request.form.get('license_key', '').strip().upper()
        
        license = License.query.filter_by(license_key=key).first()
        
        if not license:
            flash('Invalid license key', 'error')
            return redirect(url_for('lic_customer.activate_license'))
        
        if license.customer_id and license.customer_id != customer.id:
            flash('License already assigned to another account', 'error')
            return redirect(url_for('lic_customer.activate_license'))
        
        if license.customer_id == customer.id:
            flash('License already in your account', 'info')
            return redirect(url_for('lic_customer.view_license', id=license.id))
        
        license.customer_id = customer.id
        db.session.commit()
        
        flash('License added to your account!', 'success')
        return redirect(url_for('lic_customer.view_license', id=license.id))
    
    return render_template('customer/activate.html', customer=customer)


@bp.route('/profile', methods=['GET', 'POST'])
@customer_required
def profile(customer):
    if request.method == 'POST':
        customer.company_name = request.form.get('company_name', '').strip() or None
        customer.contact_name = request.form.get('contact_name', '').strip() or None
        customer.phone = request.form.get('phone', '').strip() or None
        customer.address = request.form.get('address', '').strip() or None
        
        new_password = request.form.get('new_password', '')
        if new_password:
            current_password = request.form.get('current_password', '')
            if not customer.check_password(current_password):
                flash('Current password incorrect', 'error')
                return redirect(url_for('lic_customer.profile'))
            if len(new_password) < 8:
                flash('Password must be at least 8 characters', 'error')
                return redirect(url_for('lic_customer.profile'))
            customer.set_password(new_password)
        
        db.session.commit()
        flash('Profile updated', 'success')
    
    return render_template('customer/profile.html', customer=customer)
OPSLAB_LIC_EOF__7f2d8a5e

say "Writing app/licenses/models.py"
write_file 'app/licenses/models.py' << 'OPSLAB_LIC_EOF__7f2d8a5e'
"""
License Manager - Database Models
"""
from datetime import datetime, timedelta
from flask_login import UserMixin
from werkzeug.security import generate_password_hash, check_password_hash
from .. import db   # shared with OpsLabs
import secrets
import json

# ==================== SETTINGS ====================

class Settings(db.Model):
    """System settings key-value store"""
    __tablename__ = 'lic_settings'
    
    id = db.Column(db.Integer, primary_key=True)
    key = db.Column(db.String(100), unique=True, nullable=False)
    value = db.Column(db.Text)
    description = db.Column(db.String(255))
    category = db.Column(db.String(50), default='general')
    updated_at = db.Column(db.DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)
    
    @staticmethod
    def get(key, default=None):
        setting = Settings.query.filter_by(key=key).first()
        return setting.value if setting else default
    
    @staticmethod
    def set(key, value, description=None, category='general'):
        setting = Settings.query.filter_by(key=key).first()
        if setting:
            setting.value = value
            if description:
                setting.description = description
        else:
            setting = Settings(key=key, value=value, description=description, category=category)
            db.session.add(setting)
        db.session.commit()
        return setting
    
    @staticmethod
    def get_all_by_category():
        settings = Settings.query.order_by(Settings.category, Settings.key).all()
        result = {}
        for s in settings:
            if s.category not in result:
                result[s.category] = []
            result[s.category].append(s)
        return result


# ==================== ROLES & PERMISSIONS ====================

role_permissions = db.Table('lic_role_permissions',
    db.Column('role_id', db.Integer, db.ForeignKey('lic_roles.id'), primary_key=True),
    db.Column('permission_id', db.Integer, db.ForeignKey('lic_permissions.id'), primary_key=True)
)

user_roles = db.Table('lic_user_roles',
    db.Column('user_id', db.Integer, db.ForeignKey('lic_admin_users.id'), primary_key=True),
    db.Column('role_id', db.Integer, db.ForeignKey('lic_roles.id'), primary_key=True)
)


class Permission(db.Model):
    """Permissions for role-based access control"""
    __tablename__ = 'lic_permissions'
    
    id = db.Column(db.Integer, primary_key=True)
    code = db.Column(db.String(50), unique=True, nullable=False)
    name = db.Column(db.String(100), nullable=False)
    description = db.Column(db.String(255))
    category = db.Column(db.String(50), default='general')
    
    @staticmethod
    def get_all_by_category():
        perms = Permission.query.order_by(Permission.category, Permission.name).all()
        result = {}
        for p in perms:
            if p.category not in result:
                result[p.category] = []
            result[p.category].append(p)
        return result


class Role(db.Model):
    """Roles for admin users"""
    __tablename__ = 'lic_roles'
    
    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(50), unique=True, nullable=False)
    description = db.Column(db.String(255))
    color = db.Column(db.String(20), default='gray')
    is_system = db.Column(db.Boolean, default=False)  # Can't be deleted
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    
    permissions = db.relationship('Permission', secondary=role_permissions, backref='lic_roles')
    
    def has_permission(self, code):
        return any(p.code == code for p in self.permissions)


class AdminUser(db.Model, UserMixin):
    """Admin users for the license manager"""
    __tablename__ = 'lic_admin_users'
    
    id = db.Column(db.Integer, primary_key=True)
    email = db.Column(db.String(120), unique=True, nullable=False)
    password_hash = db.Column(db.String(256), nullable=False)
    name = db.Column(db.String(100), nullable=False)
    is_superadmin = db.Column(db.Boolean, default=False)
    is_active = db.Column(db.Boolean, default=True)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    last_login = db.Column(db.DateTime)
    avatar_color = db.Column(db.String(20), default='emerald')
    
    roles = db.relationship('Role', secondary=user_roles, backref='users')
    
    def set_password(self, password):
        self.password_hash = generate_password_hash(password)
    
    def check_password(self, password):
        return check_password_hash(self.password_hash, password)
    
    def has_permission(self, code):
        if self.is_superadmin:
            return True
        return any(role.has_permission(code) for role in self.roles)
    
    def get_id(self):
        return str(self.id)


# ==================== CUSTOMERS ====================

class Customer(db.Model):
    """Customer accounts"""
    __tablename__ = 'lic_customers'
    
    id = db.Column(db.Integer, primary_key=True)
    email = db.Column(db.String(120), unique=True, nullable=False)
    password_hash = db.Column(db.String(256))
    company_name = db.Column(db.String(200))
    contact_name = db.Column(db.String(100))
    phone = db.Column(db.String(50))
    address = db.Column(db.Text)
    notes = db.Column(db.Text)
    is_active = db.Column(db.Boolean, default=True)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    last_login = db.Column(db.DateTime)
    
    # OpsLabs integration — link this license customer to an OpsLabs company
    opslabs_company_id = db.Column(db.Integer,
                                   db.ForeignKey('companies.id'),
                                   nullable=True, index=True)
    opslabs_company    = db.relationship('Company', foreign_keys=[opslabs_company_id])
    
    licenses = db.relationship('License', backref='customer', lazy='dynamic')
    
    def set_password(self, password):
        self.password_hash = generate_password_hash(password)
    
    def check_password(self, password):
        if not self.password_hash:
            return False
        return check_password_hash(self.password_hash, password)


# ==================== PRODUCTS & TIERS ====================

class Product(db.Model):
    """Software products that can be licensed"""
    __tablename__ = 'lic_products'
    
    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(100), nullable=False)
    code = db.Column(db.String(50), unique=True, nullable=False)
    description = db.Column(db.Text)
    is_active = db.Column(db.Boolean, default=True)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    
    # IP Lock settings
    require_ip_lock = db.Column(db.Boolean, default=False)
    max_ip_addresses = db.Column(db.Integer, default=2)
    allow_ip_change = db.Column(db.Boolean, default=True)
    ip_change_cooldown = db.Column(db.Integer, default=24)  # hours
    
    tiers = db.relationship('ProductTier', backref='product', lazy='dynamic')
    licenses = db.relationship('License', backref='product', lazy='dynamic')


class ProductTier(db.Model):
    """Pricing/feature tiers for products"""
    __tablename__ = 'lic_product_tiers'
    
    id = db.Column(db.Integer, primary_key=True)
    product_id = db.Column(db.Integer, db.ForeignKey('lic_products.id'), nullable=False)
    name = db.Column(db.String(50), nullable=False)
    code = db.Column(db.String(50), nullable=False)
    description = db.Column(db.Text)
    price_monthly = db.Column(db.Float, default=0)
    price_yearly = db.Column(db.Float, default=0)
    max_users = db.Column(db.Integer, default=0)  # 0 = unlimited
    features = db.Column(db.JSON, default=dict)
    sort_order = db.Column(db.Integer, default=0)
    is_active = db.Column(db.Boolean, default=True)
    
    licenses = db.relationship('License', backref='tier', lazy='dynamic')
    
    def get_features_list(self):
        if not self.features:
            return []
        return [k for k, v in self.features.items() if v]


# ==================== LICENSES ====================

class License(db.Model):
    """License keys"""
    __tablename__ = 'lic_licenses'
    
    id = db.Column(db.Integer, primary_key=True)
    license_key = db.Column(db.String(50), unique=True, nullable=False)
    product_id = db.Column(db.Integer, db.ForeignKey('lic_products.id'), nullable=False)
    tier_id = db.Column(db.Integer, db.ForeignKey('lic_product_tiers.id'), nullable=False)
    customer_id = db.Column(db.Integer, db.ForeignKey('lic_customers.id'))
    
    status = db.Column(db.String(20), default='active')  # active, suspended, revoked, expired
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    expires_at = db.Column(db.DateTime)
    
    # Activation limits
    max_activations = db.Column(db.Integer, default=1)
    current_activations = db.Column(db.Integer, default=0)
    
    # Domain/IP restrictions
    domain = db.Column(db.String(255))
    allowed_ips = db.Column(db.JSON, default=list)
    last_ip_change = db.Column(db.DateTime)
    
    # Metadata
    notes = db.Column(db.Text)
    created_by = db.Column(db.Integer, db.ForeignKey('lic_admin_users.id'))
    
    activations = db.relationship('LicenseActivation', backref='license', lazy='dynamic')
    ip_history  = db.relationship('LicenseIPHistory',  backref='license', lazy='dynamic')
    features    = db.relationship('Feature', secondary='lic_license_features', backref='lic_licenses')

    def get_features(self):
        """Return active feature codes — license-level overrides tier defaults"""
        if self.features:
            return [f.code for f in self.features if f.is_active]
        if self.tier and self.tier.features:
            return [k for k, v in self.tier.features.items() if v]
        return []

    def to_dict(self):
        return {
            'license_key':       self.license_key,
            'status':            self.status,
            'product':           self.product.code if self.product else None,
            'tier':              self.tier.code if self.tier else None,
            'tier_name':         self.tier.name if self.tier else None,
            'lic_features':          self.get_features(),
            'expires_at':        self.expires_at.isoformat() if self.expires_at else None,
            'days_until_expiry': self.days_until_expiry,
            'max_activations':   self.max_activations,
            'customer':          self.customer.company_name if self.customer else None,
        }

    @staticmethod
    def generate_key():
        """Generate a unique license key"""
        chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ0123456789'
        parts = [''.join(secrets.choice(chars) for _ in range(4)) for _ in range(4)]
        return '-'.join(parts)
    
    @property
    def is_expired(self):
        if not self.expires_at:
            return False
        return datetime.utcnow() > self.expires_at
    
    @property
    def days_until_expiry(self):
        if not self.expires_at:
            return None
        delta = self.expires_at - datetime.utcnow()
        return max(0, delta.days)
    
    @property
    def is_valid(self):
        return self.status == 'active' and not self.is_expired
    
    def can_change_ip(self):
        if not self.last_ip_change:
            return True
        cooldown = timedelta(hours=self.product.ip_change_cooldown)
        return datetime.utcnow() >= self.last_ip_change + cooldown
    
    def is_ip_allowed(self, ip):
        if not self.product.require_ip_lock:
            return True
        if not self.allowed_ips:
            return True
        return ip in self.allowed_ips


class LicenseActivation(db.Model):
    """Track license activations"""
    __tablename__ = 'lic_activations'
    
    id = db.Column(db.Integer, primary_key=True)
    license_id = db.Column(db.Integer, db.ForeignKey('lic_licenses.id'), nullable=False)
    domain = db.Column(db.String(255))
    ip_address = db.Column(db.String(50))
    hardware_id = db.Column(db.String(255))
    hostname = db.Column(db.String(255))
    activated_at = db.Column(db.DateTime, default=datetime.utcnow)
    last_check = db.Column(db.DateTime, default=datetime.utcnow)
    is_active = db.Column(db.Boolean, default=True)
    deactivated_at = db.Column(db.DateTime)


class LicenseIPHistory(db.Model):
    """Track IP address changes for licenses"""
    __tablename__ = 'lic_ip_history'
    
    id = db.Column(db.Integer, primary_key=True)
    license_id = db.Column(db.Integer, db.ForeignKey('lic_licenses.id'), nullable=False)
    ip_address = db.Column(db.String(50), nullable=False)
    action = db.Column(db.String(20))  # added, removed, auto_registered
    changed_by = db.Column(db.String(50))  # admin, customer, api
    changed_at = db.Column(db.DateTime, default=datetime.utcnow)


# ==================== FEATURES ====================

class Feature(db.Model):
    """Global feature definitions that can be assigned to licenses"""
    __tablename__ = 'lic_features'

    id          = db.Column(db.Integer, primary_key=True)
    code        = db.Column(db.String(80), unique=True, nullable=False)   # e.g. 'dispatch'
    name        = db.Column(db.String(120), nullable=False)               # e.g. 'Dispatch Module'
    description = db.Column(db.Text)
    category    = db.Column(db.String(60), default='general')             # e.g. 'cad', 'billing'
    icon        = db.Column(db.String(40), default='puzzle')              # heroicon name stub
    is_active   = db.Column(db.Boolean, default=True)
    created_at  = db.Column(db.DateTime, default=datetime.utcnow)

    @staticmethod
    def all_active():
        return Feature.query.filter_by(is_active=True).order_by(Feature.category, Feature.name).all()

    @staticmethod
    def grouped():
        feats = Feature.query.order_by(Feature.category, Feature.name).all()
        result = {}
        for f in feats:
            result.setdefault(f.category, []).append(f)
        return result


# Junction table — which extra features a *specific* license has enabled/disabled
license_features = db.Table(
    'lic_license_features',
    db.Column('license_id', db.Integer, db.ForeignKey('lic_licenses.id'), primary_key=True),
    db.Column('feature_id', db.Integer, db.ForeignKey('lic_features.id'),  primary_key=True),
    db.Column('enabled',    db.Boolean, default=True),
)


# ==================== ACTIVITY LOG ====================

class ActivityLog(db.Model):
    """Admin activity log"""
    __tablename__ = 'lic_activity_logs'
    
    id = db.Column(db.Integer, primary_key=True)
    admin_id = db.Column(db.Integer, db.ForeignKey('lic_admin_users.id'))
    action = db.Column(db.String(100), nullable=False)
    entity_type = db.Column(db.String(50))
    entity_id = db.Column(db.Integer)
    details = db.Column(db.Text)
    ip_address = db.Column(db.String(50))
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    
    admin = db.relationship('AdminUser', backref='lic_activity_logs')
OPSLAB_LIC_EOF__7f2d8a5e

say "Writing app/licenses/templates/admin/activity_log.html"
write_file 'app/licenses/templates/admin/activity_log.html' << 'OPSLAB_LIC_EOF__7f2d8a5e'
{% extends "licenses/base.html" %}
{% block title %}Activity Log - License Manager{% endblock %}

{% block content %}
<div class="mb-6">
    <h1 class="text-2xl font-bold">Activity Log</h1>
    <p class="text-gray-500">All admin actions</p>
</div>

<div class="bg-dark-800 border border-dark-600 rounded-xl overflow-hidden">
    <table class="w-full">
        <thead class="bg-dark-700">
            <tr>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-400 uppercase">Time</th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-400 uppercase">Admin</th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-400 uppercase">Action</th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-400 uppercase">Details</th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-400 uppercase">IP</th>
            </tr>
        </thead>
        <tbody class="divide-y divide-dark-600">
            {% for log in logs.items %}
            <tr class="hover:bg-dark-700">
                <td class="px-4 py-3 text-sm text-gray-400">{{ log.created_at.strftime('%d %b %Y %H:%M') }}</td>
                <td class="px-4 py-3 text-sm">{{ log.admin.name if log.admin else 'System' }}</td>
                <td class="px-4 py-3">
                    <span class="px-2 py-1 text-xs rounded bg-dark-600">{{ log.action }}</span>
                </td>
                <td class="px-4 py-3 text-sm text-gray-400">{{ log.details or '—' }}</td>
                <td class="px-4 py-3 text-sm text-gray-500 font-mono">{{ log.ip_address }}</td>
            </tr>
            {% else %}
            <tr>
                <td colspan="5" class="px-4 py-8 text-center text-gray-500">No activity yet</td>
            </tr>
            {% endfor %}
        </tbody>
    </table>
</div>

{% if logs.pages > 1 %}
<div class="flex justify-center mt-6 gap-2">
    {% for page in logs.iter_pages() %}
        {% if page %}
        <a href="{{ url_for('lic_admin.activity_log', page=page) }}"
           class="px-3 py-1 rounded {% if page == logs.page %}bg-emerald-600{% else %}bg-dark-700{% endif %}">
            {{ page }}
        </a>
        {% endif %}
    {% endfor %}
</div>
{% endif %}
{% endblock %}
OPSLAB_LIC_EOF__7f2d8a5e

say "Writing app/licenses/templates/admin/api_explorer.html"
write_file 'app/licenses/templates/admin/api_explorer.html' << 'OPSLAB_LIC_EOF__7f2d8a5e'
{% extends "licenses/base.html" %}
{% block title %}API Explorer — {{ site_name }}{% endblock %}

{% block content %}

{# ── Macro must be defined before first use in Jinja2 ── #}
{% macro endpoint_card() %}
<div class="bg-dark-800 border border-dark-700/50 rounded-2xl overflow-hidden">
  {{ caller() }}
</div>
{% endmacro %}

<div class="p-6 space-y-6">

  <!-- Header -->
  <div class="flex items-center justify-between">
    <div>
      <h1 class="text-2xl font-bold text-white">API Explorer</h1>
      <p class="text-sm text-gray-500 mt-1">Live documentation and testing for all licence API endpoints</p>
    </div>
    <div class="flex items-center gap-2 px-3 py-2 bg-dark-800 border border-dark-700/50 rounded-xl">
      <div class="w-2 h-2 rounded-full bg-emerald-400 animate-pulse"></div>
      <span class="text-xs font-mono text-gray-400">Base URL:</span>
      <code class="text-xs font-mono text-emerald-400" id="baseUrlDisplay">{{ base_url }}/api</code>
    </div>
  </div>

  <!-- Quick copy base URL -->
  <div class="bg-dark-800 border border-dark-700/50 rounded-xl px-4 py-3 flex items-center gap-3">
    <svg class="w-4 h-4 text-gray-500 flex-shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"/>
    </svg>
    <p class="text-xs text-gray-500 flex-1">All endpoints require <code class="text-amber-400 bg-dark-700 px-1.5 py-0.5 rounded font-mono">Content-Type: application/json</code>. No authentication required for API calls — secure using IP lock or domain lock on the licence itself.</p>
  </div>

  <!-- ── LICENCE ENDPOINTS ─────────────────────────────────────── -->
  <div class="space-y-3">
    <h2 class="text-xs font-bold text-gray-500 uppercase tracking-wider px-1">Licence Validation</h2>

    <!-- POST /api/validate -->
    {% call endpoint_card() %}
    <div data-endpoint="validate">
      <div class="endpoint-header flex items-center gap-3 px-5 py-4 cursor-pointer select-none" onclick="toggle('validate')">
        <span class="method-badge method-post">POST</span>
        <code class="text-sm font-mono text-white">/api/validate</code>
        <span class="text-sm text-gray-500 ml-2">Validate a licence key — returns features, tier, expiry</span>
        <svg class="w-4 h-4 text-gray-600 ml-auto chevron transition-transform" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7"/>
        </svg>
      </div>
      <div class="endpoint-body hidden px-5 pb-5 space-y-4 border-t border-dark-700/50 pt-4">
        <p class="text-sm text-gray-400">Validates a licence key. Auto-registers the caller's IP on first use if IP lock is enabled. Returns all features assigned to the licence.</p>

        <div class="grid grid-cols-2 gap-4">
          <div>
            <p class="text-xs font-semibold text-gray-400 uppercase tracking-wider mb-2">Request Body</p>
            <div class="space-y-2">
              <div class="field-row">
                <code class="field-name">license_key</code>
                <span class="field-type required">string *</span>
                <span class="field-desc">The licence key e.g. <code class="text-emerald-400">XXXX-XXXX-XXXX-XXXX</code></span>
              </div>
              <div class="field-row">
                <code class="field-name">domain</code>
                <span class="field-type">string</span>
                <span class="field-desc">Caller's domain for domain-lock check</span>
              </div>
              <div class="field-row">
                <code class="field-name">hardware_id</code>
                <span class="field-type">string</span>
                <span class="field-desc">Unique hardware identifier for the machine</span>
              </div>
            </div>
          </div>
          <div>
            <p class="text-xs font-semibold text-gray-400 uppercase tracking-wider mb-2">Response</p>
            <pre class="response-sample">{"valid": true,
  "product": "NOVACAD",
  "tier": "pro",
  "tier_name": "Professional",
  "features": ["dispatch","mdt","citizens"],
  "expires_at": "2026-12-31T00:00:00",
  "days_until_expiry": 291,
  "customer": "Acme PD",
  "your_ip": "1.2.3.4"
}</pre>
          </div>
        </div>

        <!-- Try it out -->
        <div class="tryit-box">
          <p class="text-xs font-semibold text-gray-400 uppercase tracking-wider mb-3">Try It Out</p>
          <div class="grid grid-cols-3 gap-3 mb-3">
            <div>
              <label class="field-label">license_key *</label>
              <input type="text" placeholder="XXXX-XXXX-XXXX-XXXX" class="tryit-input" id="v_license_key">
            </div>
            <div>
              <label class="field-label">domain</label>
              <input type="text" placeholder="example.com" class="tryit-input" id="v_domain">
            </div>
            <div>
              <label class="field-label">hardware_id</label>
              <input type="text" placeholder="optional" class="tryit-input" id="v_hardware_id">
            </div>
          </div>
          <button onclick="tryPost('/api/validate', {license_key: gv('v_license_key'), domain: gv('v_domain'), hardware_id: gv('v_hardware_id')}, 'validate_result')"
                  class="tryit-btn">Send Request</button>
          <div id="validate_result" class="result-box hidden mt-3"></div>
        </div>
      </div>
    </div>
    {% endcall %}

    <!-- POST /api/activate -->
    {% call endpoint_card() %}
    <div data-endpoint="activate">
      <div class="endpoint-header flex items-center gap-3 px-5 py-4 cursor-pointer select-none" onclick="toggle('activate')">
        <span class="method-badge method-post">POST</span>
        <code class="text-sm font-mono text-white">/api/activate</code>
        <span class="text-sm text-gray-500 ml-2">Activate a licence on a server / machine</span>
        <svg class="w-4 h-4 text-gray-600 ml-auto chevron transition-transform" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7"/>
        </svg>
      </div>
      <div class="endpoint-body hidden px-5 pb-5 space-y-4 border-t border-dark-700/50 pt-4">
        <p class="text-sm text-gray-400">Creates a new activation record. If the hardware ID already has an active activation, it is updated instead. Returns the full licence object including features.</p>

        <div class="grid grid-cols-2 gap-4">
          <div>
            <p class="text-xs font-semibold text-gray-400 uppercase tracking-wider mb-2">Request Body</p>
            <div class="space-y-2">
              <div class="field-row"><code class="field-name">license_key</code><span class="field-type required">string *</span><span class="field-desc">Licence key</span></div>
              <div class="field-row"><code class="field-name">domain</code><span class="field-type">string</span><span class="field-desc">Domain of the server</span></div>
              <div class="field-row"><code class="field-name">hardware_id</code><span class="field-type">string</span><span class="field-desc">Unique ID to track this machine</span></div>
              <div class="field-row"><code class="field-name">hostname</code><span class="field-type">string</span><span class="field-desc">Human-readable server name</span></div>
            </div>
          </div>
          <div>
            <p class="text-xs font-semibold text-gray-400 uppercase tracking-wider mb-2">Response</p>
            <pre class="response-sample">{"success": true,
  "message": "License activated",
  "activation_id": 42,
  "license": { ...licence object... },
  "your_ip": "1.2.3.4"
}</pre>
          </div>
        </div>

        <div class="tryit-box">
          <p class="text-xs font-semibold text-gray-400 uppercase tracking-wider mb-3">Try It Out</p>
          <div class="grid grid-cols-2 gap-3 mb-3">
            <div><label class="field-label">license_key *</label><input type="text" placeholder="XXXX-XXXX-XXXX-XXXX" class="tryit-input" id="a_license_key"></div>
            <div><label class="field-label">hostname</label><input type="text" placeholder="my-server" class="tryit-input" id="a_hostname"></div>
            <div><label class="field-label">domain</label><input type="text" placeholder="example.com" class="tryit-input" id="a_domain"></div>
            <div><label class="field-label">hardware_id</label><input type="text" placeholder="hw-abc123" class="tryit-input" id="a_hardware_id"></div>
          </div>
          <button onclick="tryPost('/api/activate', {license_key:gv('a_license_key'),domain:gv('a_domain'),hardware_id:gv('a_hardware_id'),hostname:gv('a_hostname')}, 'activate_result')"
                  class="tryit-btn">Send Request</button>
          <div id="activate_result" class="result-box hidden mt-3"></div>
        </div>
      </div>
    </div>
    {% endcall %}

    <!-- POST /api/deactivate -->
    {% call endpoint_card() %}
    <div data-endpoint="deactivate">
      <div class="endpoint-header flex items-center gap-3 px-5 py-4 cursor-pointer select-none" onclick="toggle('deactivate')">
        <span class="method-badge method-post">POST</span>
        <code class="text-sm font-mono text-white">/api/deactivate</code>
        <span class="text-sm text-gray-500 ml-2">Deactivate a licence activation</span>
        <svg class="w-4 h-4 text-gray-600 ml-auto chevron transition-transform" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7"/>
        </svg>
      </div>
      <div class="endpoint-body hidden px-5 pb-5 space-y-4 border-t border-dark-700/50 pt-4">
        <p class="text-sm text-gray-400">Deactivates the most recent activation for a licence. Pass <code class="text-amber-400">activation_id</code> to deactivate a specific one.</p>
        <div class="grid grid-cols-2 gap-4">
          <div>
            <p class="text-xs font-semibold text-gray-400 uppercase tracking-wider mb-2">Request Body</p>
            <div class="space-y-2">
              <div class="field-row"><code class="field-name">license_key</code><span class="field-type required">string *</span><span class="field-desc">Licence key</span></div>
              <div class="field-row"><code class="field-name">activation_id</code><span class="field-type">integer</span><span class="field-desc">Specific activation to deactivate</span></div>
            </div>
          </div>
          <div>
            <p class="text-xs font-semibold text-gray-400 uppercase tracking-wider mb-2">Response</p>
            <pre class="response-sample">{"success": true,
  "message": "License deactivated"
}</pre>
          </div>
        </div>
        <div class="tryit-box">
          <p class="text-xs font-semibold text-gray-400 uppercase tracking-wider mb-3">Try It Out</p>
          <div class="grid grid-cols-2 gap-3 mb-3">
            <div><label class="field-label">license_key *</label><input type="text" placeholder="XXXX-XXXX-XXXX-XXXX" class="tryit-input" id="d_license_key"></div>
            <div><label class="field-label">activation_id</label><input type="number" placeholder="optional" class="tryit-input" id="d_activation_id"></div>
          </div>
          <button onclick="tryPost('/api/deactivate', {license_key:gv('d_license_key'),activation_id:gv('d_activation_id')||null}, 'deactivate_result')"
                  class="tryit-btn">Send Request</button>
          <div id="deactivate_result" class="result-box hidden mt-3"></div>
        </div>
      </div>
    </div>
    {% endcall %}

    <!-- POST /api/heartbeat -->
    {% call endpoint_card() %}
    <div data-endpoint="heartbeat">
      <div class="endpoint-header flex items-center gap-3 px-5 py-4 cursor-pointer select-none" onclick="toggle('heartbeat')">
        <span class="method-badge method-post">POST</span>
        <code class="text-sm font-mono text-white">/api/heartbeat</code>
        <span class="text-sm text-gray-500 ml-2">Periodic keep-alive check from a running application</span>
        <svg class="w-4 h-4 text-gray-600 ml-auto chevron transition-transform" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7"/>
        </svg>
      </div>
      <div class="endpoint-body hidden px-5 pb-5 space-y-4 border-t border-dark-700/50 pt-4">
        <p class="text-sm text-gray-400">Called periodically by a running application to confirm the licence is still valid. Updates the last-seen timestamp on the activation. IP is checked if IP-lock is enabled.</p>
        <div class="grid grid-cols-2 gap-4">
          <div>
            <p class="text-xs font-semibold text-gray-400 uppercase tracking-wider mb-2">Request Body</p>
            <div class="space-y-2">
              <div class="field-row"><code class="field-name">license_key</code><span class="field-type required">string *</span><span class="field-desc">Licence key</span></div>
              <div class="field-row"><code class="field-name">activation_id</code><span class="field-type">integer</span><span class="field-desc">Activation ID from activate response</span></div>
            </div>
          </div>
          <div>
            <p class="text-xs font-semibold text-gray-400 uppercase tracking-wider mb-2">Response</p>
            <pre class="response-sample">{"valid": true,
  "license": { ...licence object... },
  "your_ip": "1.2.3.4"
}</pre>
          </div>
        </div>
        <div class="tryit-box">
          <p class="text-xs font-semibold text-gray-400 uppercase tracking-wider mb-3">Try It Out</p>
          <div class="grid grid-cols-2 gap-3 mb-3">
            <div><label class="field-label">license_key *</label><input type="text" placeholder="XXXX-XXXX-XXXX-XXXX" class="tryit-input" id="hb_license_key"></div>
            <div><label class="field-label">activation_id</label><input type="number" placeholder="optional" class="tryit-input" id="hb_activation_id"></div>
          </div>
          <button onclick="tryPost('/api/heartbeat', {license_key:gv('hb_license_key'),activation_id:gv('hb_activation_id')||null}, 'heartbeat_result')"
                  class="tryit-btn">Send Request</button>
          <div id="heartbeat_result" class="result-box hidden mt-3"></div>
        </div>
      </div>
    </div>
    {% endcall %}
  </div>

  <!-- ── INFO ENDPOINTS ─────────────────────────────────────────── -->
  <div class="space-y-3">
    <h2 class="text-xs font-bold text-gray-500 uppercase tracking-wider px-1">Info & Utility</h2>

    <!-- GET /api/info/<key> -->
    {% call endpoint_card() %}
    <div data-endpoint="info">
      <div class="endpoint-header flex items-center gap-3 px-5 py-4 cursor-pointer select-none" onclick="toggle('info')">
        <span class="method-badge method-get">GET</span>
        <code class="text-sm font-mono text-white">/api/info/&lt;license_key&gt;</code>
        <span class="text-sm text-gray-500 ml-2">Get public summary of a licence</span>
        <svg class="w-4 h-4 text-gray-600 ml-auto chevron transition-transform" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7"/>
        </svg>
      </div>
      <div class="endpoint-body hidden px-5 pb-5 space-y-4 border-t border-dark-700/50 pt-4">
        <p class="text-sm text-gray-400">Returns a brief public summary of a licence — valid/expired, tier name, expiry date. Does not return features or customer details.</p>
        <div class="grid grid-cols-2 gap-4">
          <div>
            <p class="text-xs font-semibold text-gray-400 uppercase tracking-wider mb-2">URL Parameter</p>
            <div class="field-row"><code class="field-name">license_key</code><span class="field-type required">string *</span><span class="field-desc">Key in the URL path</span></div>
          </div>
          <div>
            <p class="text-xs font-semibold text-gray-400 uppercase tracking-wider mb-2">Response</p>
            <pre class="response-sample">{"valid": true,
  "status": "active",
  "tier": "Professional",
  "expires_at": "2026-12-31T00:00:00"
}</pre>
          </div>
        </div>
        <div class="tryit-box">
          <p class="text-xs font-semibold text-gray-400 uppercase tracking-wider mb-3">Try It Out</p>
          <div class="grid grid-cols-2 gap-3 mb-3">
            <div><label class="field-label">license_key *</label><input type="text" placeholder="XXXX-XXXX-XXXX-XXXX" class="tryit-input" id="info_key"></div>
          </div>
          <button onclick="tryGet('/api/info/' + gv('info_key'), 'info_result')"
                  class="tryit-btn">Send Request</button>
          <div id="info_result" class="result-box hidden mt-3"></div>
        </div>
      </div>
    </div>
    {% endcall %}

    <!-- GET /api/my-ip -->
    {% call endpoint_card() %}
    <div data-endpoint="myip">
      <div class="endpoint-header flex items-center gap-3 px-5 py-4 cursor-pointer select-none" onclick="toggle('myip')">
        <span class="method-badge method-get">GET</span>
        <code class="text-sm font-mono text-white">/api/my-ip</code>
        <span class="text-sm text-gray-500 ml-2">Returns the caller's detected IP address</span>
        <svg class="w-4 h-4 text-gray-600 ml-auto chevron transition-transform" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7"/>
        </svg>
      </div>
      <div class="endpoint-body hidden px-5 pb-5 space-y-4 border-t border-dark-700/50 pt-4">
        <p class="text-sm text-gray-400">Useful for checking which IP will be registered when a server calls the validate or activate endpoint — especially behind proxies or NAT.</p>
        <div class="grid grid-cols-2 gap-4">
          <div><p class="text-xs font-semibold text-gray-400 uppercase tracking-wider mb-2">No parameters</p></div>
          <div>
            <p class="text-xs font-semibold text-gray-400 uppercase tracking-wider mb-2">Response</p>
            <pre class="response-sample">{"ip": "1.2.3.4"}</pre>
          </div>
        </div>
        <div class="tryit-box">
          <p class="text-xs font-semibold text-gray-400 uppercase tracking-wider mb-3">Try It Out</p>
          <button onclick="tryGet('/api/my-ip', 'myip_result')" class="tryit-btn">Send Request</button>
          <div id="myip_result" class="result-box hidden mt-3"></div>
        </div>
      </div>
    </div>
    {% endcall %}

    <!-- GET /api/health -->
    {% call endpoint_card() %}
    <div data-endpoint="health">
      <div class="endpoint-header flex items-center gap-3 px-5 py-4 cursor-pointer select-none" onclick="toggle('health')">
        <span class="method-badge method-get">GET</span>
        <code class="text-sm font-mono text-white">/api/health</code>
        <span class="text-sm text-gray-500 ml-2">Server health check</span>
        <svg class="w-4 h-4 text-gray-600 ml-auto chevron transition-transform" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7"/>
        </svg>
      </div>
      <div class="endpoint-body hidden px-5 pb-5 space-y-4 border-t border-dark-700/50 pt-4">
        <p class="text-sm text-gray-400">Simple health check. Use this to confirm the licence server is up before sending a validate request.</p>
        <div class="grid grid-cols-2 gap-4">
          <div><p class="text-xs font-semibold text-gray-400 uppercase tracking-wider mb-2">No parameters</p></div>
          <div>
            <p class="text-xs font-semibold text-gray-400 uppercase tracking-wider mb-2">Response</p>
            <pre class="response-sample">{"status": "ok",
  "timestamp": "2026-03-14T12:00:00"
}</pre>
          </div>
        </div>
        <div class="tryit-box">
          <p class="text-xs font-semibold text-gray-400 uppercase tracking-wider mb-3">Try It Out</p>
          <button onclick="tryGet('/api/health', 'health_result')" class="tryit-btn">Send Request</button>
          <div id="health_result" class="result-box hidden mt-3"></div>
        </div>
      </div>
    </div>
    {% endcall %}
  </div>

  <!-- ── MANAGEMENT API ────────────────────────────────────────── -->
  <div class="space-y-3">
    <div class="flex items-center justify-between">
      <h2 class="text-xs font-bold text-gray-500 uppercase tracking-wider px-1">Management API</h2>
      <span class="text-xs text-amber-400 bg-amber-500/10 border border-amber-500/20 px-2 py-1 rounded-lg">Requires X-API-Key</span>
    </div>

    <!-- API Key input bar -->
    <div class="bg-dark-800 border border-amber-500/20 rounded-xl px-4 py-3 flex items-center gap-3">
      <svg class="w-4 h-4 text-amber-400 flex-shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24">
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 7a2 2 0 012 2m4 0a6 6 0 01-7.743 5.743L11 17H9v2H7v2H4a1 1 0 01-1-1v-2.586a1 1 0 01.293-.707l5.964-5.964A6 6 0 1121 9z"/>
      </svg>
      <label class="text-xs text-amber-400 font-semibold whitespace-nowrap">API Key</label>
      <input type="password" id="globalApiKey" placeholder="Paste your admin_api_key from Settings"
             class="flex-1 bg-dark-700 border border-dark-600 rounded-lg px-3 py-1.5 text-sm font-mono text-white placeholder-gray-600 outline-none focus:border-amber-500/50">
      <button onclick="toggleKeyVisibility()" class="text-xs text-gray-500 hover:text-gray-300 px-2 py-1 bg-dark-700 rounded-lg transition-colors">Show</button>
      <a href="{{ url_for('lic_admin.settings') }}" class="text-xs text-amber-400 hover:text-amber-300 whitespace-nowrap">Set in Settings →</a>
    </div>

    <!-- GET /api/admin/dashboard -->
    {% call endpoint_card() %}
    <div data-endpoint="mgmt_dash">
      <div class="endpoint-header flex items-center gap-3 px-5 py-4 cursor-pointer select-none" onclick="toggle('mgmt_dash')">
        <span class="method-badge method-get">GET</span>
        <code class="text-sm font-mono text-white">/api/admin/dashboard</code>
        <span class="text-sm text-gray-500 ml-2">Summary stats — licences, customers, products, recent activity</span>
        <svg class="w-4 h-4 text-gray-600 ml-auto chevron transition-transform" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7"/></svg>
      </div>
      <div class="endpoint-body hidden px-5 pb-5 space-y-4 border-t border-dark-700/50 pt-4">
        <p class="text-sm text-gray-400">Returns a full stats snapshot — total/active/suspended/revoked licences, expiring-soon count, customer count, and 5 most recent activity log entries.</p>
        <div class="tryit-box">
          <p class="text-xs font-semibold text-gray-400 uppercase tracking-wider mb-3">Try It Out</p>
          <button onclick="tryGetAuth('/api/admin/dashboard', 'mgmt_dash_result')" class="tryit-btn">Send Request</button>
          <div id="mgmt_dash_result" class="result-box hidden mt-3"></div>
        </div>
      </div>
    </div>
    {% endcall %}

    <!-- GET /api/admin/licenses -->
    {% call endpoint_card() %}
    <div data-endpoint="mgmt_lic_list">
      <div class="endpoint-header flex items-center gap-3 px-5 py-4 cursor-pointer select-none" onclick="toggle('mgmt_lic_list')">
        <span class="method-badge method-get">GET</span>
        <code class="text-sm font-mono text-white">/api/admin/licenses</code>
        <span class="text-sm text-gray-500 ml-2">List licences with filters</span>
        <svg class="w-4 h-4 text-gray-600 ml-auto chevron transition-transform" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7"/></svg>
      </div>
      <div class="endpoint-body hidden px-5 pb-5 space-y-4 border-t border-dark-700/50 pt-4">
        <div class="grid grid-cols-2 gap-4">
          <div>
            <p class="text-xs font-semibold text-gray-400 uppercase tracking-wider mb-2">Query Params</p>
            <div class="space-y-1">
              <div class="field-row"><code class="field-name">status</code><span class="field-type">string</span><span class="field-desc">active / suspended / revoked</span></div>
              <div class="field-row"><code class="field-name">customer_id</code><span class="field-type">integer</span><span class="field-desc">Filter by customer</span></div>
              <div class="field-row"><code class="field-name">product_id</code><span class="field-type">integer</span><span class="field-desc">Filter by product</span></div>
              <div class="field-row"><code class="field-name">page</code><span class="field-type">integer</span><span class="field-desc">Page number (default 1)</span></div>
              <div class="field-row"><code class="field-name">per_page</code><span class="field-type">integer</span><span class="field-desc">Results per page (max 100)</span></div>
            </div>
          </div>
          <div>
            <p class="text-xs font-semibold text-gray-400 uppercase tracking-wider mb-2">Response</p>
            <pre class="response-sample">{"total": 42, "page": 1,
  "licenses": [
    {"license_key": "...", "status": "active",
     "features": ["dispatch","mdt"],
     "expires_at": "2026-12-31T00:00:00",
     ...}
  ]
}</pre>
          </div>
        </div>
        <div class="tryit-box">
          <p class="text-xs font-semibold text-gray-400 uppercase tracking-wider mb-3">Try It Out</p>
          <div class="grid grid-cols-3 gap-3 mb-3">
            <div><label class="field-label">status</label><select class="tryit-input" id="ml_status"><option value="">all</option><option>active</option><option>suspended</option><option>revoked</option></select></div>
            <div><label class="field-label">page</label><input type="number" value="1" class="tryit-input" id="ml_page"></div>
            <div><label class="field-label">per_page</label><input type="number" value="10" class="tryit-input" id="ml_per_page"></div>
          </div>
          <button onclick="tryGetAuth('/api/admin/licenses?status='+gv('ml_status')+'&page='+gv('ml_page')+'&per_page='+gv('ml_per_page'), 'mgmt_lic_result')" class="tryit-btn">Send Request</button>
          <div id="mgmt_lic_result" class="result-box hidden mt-3"></div>
        </div>
      </div>
    </div>
    {% endcall %}

    <!-- PATCH /api/admin/licenses/:id/status -->
    {% call endpoint_card() %}
    <div data-endpoint="mgmt_lic_status">
      <div class="endpoint-header flex items-center gap-3 px-5 py-4 cursor-pointer select-none" onclick="toggle('mgmt_lic_status')">
        <span class="method-badge" style="background:rgba(139,92,246,0.15);color:#a78bfa;border:1px solid rgba(139,92,246,0.25)">PATCH</span>
        <code class="text-sm font-mono text-white">/api/admin/licenses/&lt;id&gt;/status</code>
        <span class="text-sm text-gray-500 ml-2">Change a licence's status</span>
        <svg class="w-4 h-4 text-gray-600 ml-auto chevron transition-transform" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7"/></svg>
      </div>
      <div class="endpoint-body hidden px-5 pb-5 space-y-4 border-t border-dark-700/50 pt-4">
        <div class="tryit-box">
          <p class="text-xs font-semibold text-gray-400 uppercase tracking-wider mb-3">Try It Out</p>
          <div class="grid grid-cols-2 gap-3 mb-3">
            <div><label class="field-label">licence ID</label><input type="number" placeholder="1" class="tryit-input" id="ls_id"></div>
            <div><label class="field-label">new status</label><select class="tryit-input" id="ls_status"><option>active</option><option>suspended</option><option>revoked</option></select></div>
          </div>
          <button onclick="tryPatch('/api/admin/licenses/'+gv('ls_id')+'/status', {status: gv('ls_status')}, 'ls_result')" class="tryit-btn">Send Request</button>
          <div id="ls_result" class="result-box hidden mt-3"></div>
        </div>
      </div>
    </div>
    {% endcall %}

    <!-- PUT /api/admin/licenses/:id/features -->
    {% call endpoint_card() %}
    <div data-endpoint="mgmt_lic_feat">
      <div class="endpoint-header flex items-center gap-3 px-5 py-4 cursor-pointer select-none" onclick="toggle('mgmt_lic_feat')">
        <span class="method-badge" style="background:rgba(59,130,246,0.15);color:#60a5fa;border:1px solid rgba(59,130,246,0.25)">PUT</span>
        <code class="text-sm font-mono text-white">/api/admin/licenses/&lt;id&gt;/features</code>
        <span class="text-sm text-gray-500 ml-2">Set features on a licence</span>
        <svg class="w-4 h-4 text-gray-600 ml-auto chevron transition-transform" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7"/></svg>
      </div>
      <div class="endpoint-body hidden px-5 pb-5 space-y-4 border-t border-dark-700/50 pt-4">
        <p class="text-sm text-gray-400">Replaces all features on a licence. Pass an array of feature IDs. Pass an empty array to clear all features (licence will fall back to tier defaults).</p>
        <div class="tryit-box">
          <p class="text-xs font-semibold text-gray-400 uppercase tracking-wider mb-3">Try It Out</p>
          <div class="grid grid-cols-2 gap-3 mb-3">
            <div><label class="field-label">licence ID</label><input type="number" placeholder="1" class="tryit-input" id="lf_id"></div>
            <div><label class="field-label">feature_ids (comma separated)</label><input type="text" placeholder="1,2,3" class="tryit-input" id="lf_ids"></div>
          </div>
          <button onclick="tryPut('/api/admin/licenses/'+gv('lf_id')+'/features', {feature_ids: gv('lf_ids').split(',').filter(Boolean).map(Number)}, 'lf_result')" class="tryit-btn">Send Request</button>
          <div id="lf_result" class="result-box hidden mt-3"></div>
        </div>
      </div>
    </div>
    {% endcall %}

    <!-- GET /api/admin/customers -->
    {% call endpoint_card() %}
    <div data-endpoint="mgmt_cust">
      <div class="endpoint-header flex items-center gap-3 px-5 py-4 cursor-pointer select-none" onclick="toggle('mgmt_cust')">
        <span class="method-badge method-get">GET</span>
        <code class="text-sm font-mono text-white">/api/admin/customers</code>
        <span class="text-sm text-gray-500 ml-2">List customers</span>
        <svg class="w-4 h-4 text-gray-600 ml-auto chevron transition-transform" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7"/></svg>
      </div>
      <div class="endpoint-body hidden px-5 pb-5 space-y-4 border-t border-dark-700/50 pt-4">
        <p class="text-sm text-gray-400">Returns paginated list of customers with licence counts. Also supports <code class="text-amber-400">POST</code> to create a new customer, <code class="text-amber-400">GET /customers/&lt;id&gt;</code> for details, and <code class="text-amber-400">PATCH /customers/&lt;id&gt;</code> to update.</p>
        <div class="tryit-box">
          <p class="text-xs font-semibold text-gray-400 uppercase tracking-wider mb-3">Try It Out</p>
          <button onclick="tryGetAuth('/api/admin/customers', 'mgmt_cust_result')" class="tryit-btn">Send Request</button>
          <div id="mgmt_cust_result" class="result-box hidden mt-3"></div>
        </div>
      </div>
    </div>
    {% endcall %}

    <!-- GET /api/admin/products -->
    {% call endpoint_card() %}
    <div data-endpoint="mgmt_prod">
      <div class="endpoint-header flex items-center gap-3 px-5 py-4 cursor-pointer select-none" onclick="toggle('mgmt_prod')">
        <span class="method-badge method-get">GET</span>
        <code class="text-sm font-mono text-white">/api/admin/products</code>
        <span class="text-sm text-gray-500 ml-2">List products with tiers</span>
        <svg class="w-4 h-4 text-gray-600 ml-auto chevron transition-transform" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7"/></svg>
      </div>
      <div class="endpoint-body hidden px-5 pb-5 space-y-4 border-t border-dark-700/50 pt-4">
        <div class="tryit-box">
          <p class="text-xs font-semibold text-gray-400 uppercase tracking-wider mb-3">Try It Out</p>
          <button onclick="tryGetAuth('/api/admin/products', 'mgmt_prod_result')" class="tryit-btn">Send Request</button>
          <div id="mgmt_prod_result" class="result-box hidden mt-3"></div>
        </div>
      </div>
    </div>
    {% endcall %}

    <!-- GET /api/admin/features -->
    {% call endpoint_card() %}
    <div data-endpoint="mgmt_feat">
      <div class="endpoint-header flex items-center gap-3 px-5 py-4 cursor-pointer select-none" onclick="toggle('mgmt_feat')">
        <span class="method-badge method-get">GET</span>
        <code class="text-sm font-mono text-white">/api/admin/features</code>
        <span class="text-sm text-gray-500 ml-2">List / create / update / delete features</span>
        <svg class="w-4 h-4 text-gray-600 ml-auto chevron transition-transform" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7"/></svg>
      </div>
      <div class="endpoint-body hidden px-5 pb-5 space-y-4 border-t border-dark-700/50 pt-4">
        <p class="text-sm text-gray-400">Full CRUD for features. <code class="text-amber-400">GET</code> lists all, <code class="text-amber-400">POST</code> creates, <code class="text-amber-400">PATCH /features/&lt;id&gt;</code> updates, <code class="text-amber-400">DELETE /features/&lt;id&gt;</code> deletes.</p>
        <div class="tryit-box">
          <p class="text-xs font-semibold text-gray-400 uppercase tracking-wider mb-3">Try It Out</p>
          <button onclick="tryGetAuth('/api/admin/features', 'mgmt_feat_result')" class="tryit-btn">Send Request</button>
          <div id="mgmt_feat_result" class="result-box hidden mt-3"></div>
        </div>
      </div>
    </div>
    {% endcall %}

    <!-- GET /api/admin/roles -->
    {% call endpoint_card() %}
    <div data-endpoint="mgmt_roles">
      <div class="endpoint-header flex items-center gap-3 px-5 py-4 cursor-pointer select-none" onclick="toggle('mgmt_roles')">
        <span class="method-badge method-get">GET</span>
        <code class="text-sm font-mono text-white">/api/admin/roles</code>
        <span class="text-sm text-gray-500 ml-2">List roles with permissions</span>
        <svg class="w-4 h-4 text-gray-600 ml-auto chevron transition-transform" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7"/></svg>
      </div>
      <div class="endpoint-body hidden px-5 pb-5 space-y-4 border-t border-dark-700/50 pt-4">
        <div class="tryit-box">
          <p class="text-xs font-semibold text-gray-400 uppercase tracking-wider mb-3">Try It Out</p>
          <button onclick="tryGetAuth('/api/admin/roles', 'mgmt_roles_result')" class="tryit-btn">Send Request</button>
          <div id="mgmt_roles_result" class="result-box hidden mt-3"></div>
        </div>
      </div>
    </div>
    {% endcall %}

    <!-- GET /api/admin/users -->
    {% call endpoint_card() %}
    <div data-endpoint="mgmt_users">
      <div class="endpoint-header flex items-center gap-3 px-5 py-4 cursor-pointer select-none" onclick="toggle('mgmt_users')">
        <span class="method-badge method-get">GET</span>
        <code class="text-sm font-mono text-white">/api/admin/users</code>
        <span class="text-sm text-gray-500 ml-2">List admin users with roles</span>
        <svg class="w-4 h-4 text-gray-600 ml-auto chevron transition-transform" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7"/></svg>
      </div>
      <div class="endpoint-body hidden px-5 pb-5 space-y-4 border-t border-dark-700/50 pt-4">
        <div class="tryit-box">
          <p class="text-xs font-semibold text-gray-400 uppercase tracking-wider mb-3">Try It Out</p>
          <button onclick="tryGetAuth('/api/admin/users', 'mgmt_users_result')" class="tryit-btn">Send Request</button>
          <div id="mgmt_users_result" class="result-box hidden mt-3"></div>
        </div>
      </div>
    </div>
    {% endcall %}

    <!-- GET /api/admin/activity -->
    {% call endpoint_card() %}
    <div data-endpoint="mgmt_activity">
      <div class="endpoint-header flex items-center gap-3 px-5 py-4 cursor-pointer select-none" onclick="toggle('mgmt_activity')">
        <span class="method-badge method-get">GET</span>
        <code class="text-sm font-mono text-white">/api/admin/activity</code>
        <span class="text-sm text-gray-500 ml-2">Activity log — paginated, filterable</span>
        <svg class="w-4 h-4 text-gray-600 ml-auto chevron transition-transform" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7"/></svg>
      </div>
      <div class="endpoint-body hidden px-5 pb-5 space-y-4 border-t border-dark-700/50 pt-4">
        <div class="grid grid-cols-2 gap-4">
          <div>
            <p class="text-xs font-semibold text-gray-400 uppercase tracking-wider mb-2">Query Params</p>
            <div class="space-y-1">
              <div class="field-row"><code class="field-name">entity_type</code><span class="field-type">string</span><span class="field-desc">license / customer / feature etc.</span></div>
              <div class="field-row"><code class="field-name">action</code><span class="field-type">string</span><span class="field-desc">partial match e.g. "create"</span></div>
              <div class="field-row"><code class="field-name">page / per_page</code><span class="field-type">integer</span><span class="field-desc">pagination (max 200)</span></div>
            </div>
          </div>
          <div><pre class="response-sample">{"total": 150, "logs": [
  {"action": "create_license",
   "entity_type": "license",
   "admin": "Administrator",
   "created_at": "2026-03-14T..."}
]}</pre></div>
        </div>
        <div class="tryit-box">
          <p class="text-xs font-semibold text-gray-400 uppercase tracking-wider mb-3">Try It Out</p>
          <div class="grid grid-cols-3 gap-3 mb-3">
            <div><label class="field-label">entity_type</label><input type="text" placeholder="license" class="tryit-input" id="act_type"></div>
            <div><label class="field-label">action</label><input type="text" placeholder="create" class="tryit-input" id="act_action"></div>
            <div><label class="field-label">per_page</label><input type="number" value="10" class="tryit-input" id="act_pp"></div>
          </div>
          <button onclick="tryGetAuth('/api/admin/activity?entity_type='+gv('act_type')+'&action='+gv('act_action')+'&per_page='+gv('act_pp'), 'mgmt_act_result')" class="tryit-btn">Send Request</button>
          <div id="mgmt_act_result" class="result-box hidden mt-3"></div>
        </div>
      </div>
    </div>
    {% endcall %}
  </div>

  <!-- ── CODE SNIPPETS ──────────────────────────────────────────── -->
  <div class="space-y-3">
    <h2 class="text-xs font-bold text-gray-500 uppercase tracking-wider px-1">Code Examples</h2>
    <div class="bg-dark-800 border border-dark-700/50 rounded-2xl overflow-hidden">
      <!-- Tabs -->
      <div class="flex border-b border-dark-700/50 px-1 pt-1 gap-1">
        <button onclick="showSnippet('python')" id="tab-python" class="snippet-tab snippet-tab-active px-4 py-2.5 text-sm font-medium rounded-t-lg">Python</button>
        <button onclick="showSnippet('js')" id="tab-js" class="snippet-tab px-4 py-2.5 text-sm font-medium rounded-t-lg">JavaScript</button>
        <button onclick="showSnippet('curl')" id="tab-curl" class="snippet-tab px-4 py-2.5 text-sm font-medium rounded-t-lg">cURL</button>
      </div>

      <div id="snippet-python" class="snippet-content p-5">
        <pre class="code-block">import requests

LICENSE_SERVER = "{{ base_url }}"
LICENSE_KEY    = "XXXX-XXXX-XXXX-XXXX"

def validate():
    r = requests.post(f"{LICENSE_SERVER}/api/validate", json={
        "license_key": LICENSE_KEY,
        "hardware_id": "my-server-id",
        "domain": "example.com",
    }, timeout=8)
    data = r.json()
    if data["valid"]:
        print("✓ Valid —", data["tier_name"])
        print("Features:", data["features"])
    else:
        print("✗ Invalid —", data["error"])

validate()</pre>
      </div>

      <div id="snippet-js" class="snippet-content hidden p-5">
        <pre class="code-block">const LICENSE_SERVER = "{{ base_url }}";
const LICENSE_KEY    = "XXXX-XXXX-XXXX-XXXX";

async function validate() {
  const res = await fetch(`${LICENSE_SERVER}/api/validate`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      license_key: LICENSE_KEY,
      hardware_id: "my-server-id",
      domain: window.location.hostname,
    }),
  });
  const data = await res.json();
  if (data.valid) {
    console.log("✓ Valid —", data.tier_name);
    console.log("Features:", data.features);
  } else {
    console.error("✗ Invalid —", data.error);
  }
}

validate();</pre>
      </div>

      <div id="snippet-curl" class="snippet-content hidden p-5">
        <pre class="code-block">curl -X POST {{ base_url }}/api/validate \
  -H "Content-Type: application/json" \
  -d '{
    "license_key": "XXXX-XXXX-XXXX-XXXX",
    "hardware_id": "my-server-id",
    "domain": "example.com"
  }'

# Health check
curl {{ base_url }}/api/health

# Get your server's IP as seen by the licence server
curl {{ base_url }}/api/my-ip

# Public licence info (no auth needed)
curl {{ base_url }}/api/info/XXXX-XXXX-XXXX-XXXX</pre>
      </div>
    </div>
  </div>

</div><!-- /p-6 -->

<style>
  .method-badge { padding: 2px 8px; border-radius: 6px; font-size: 11px; font-weight: 700; font-family: monospace; flex-shrink: 0; }
  .method-post  { background: rgba(234,179,8,0.15); color: #fbbf24; border: 1px solid rgba(234,179,8,0.25); }
  .method-get   { background: rgba(34,197,94,0.15);  color: #4ade80;  border: 1px solid rgba(34,197,94,0.25); }
  .field-row    { display: flex; align-items: baseline; gap: 8px; padding: 4px 0; }
  .field-name   { font-size: 12px; font-family: monospace; color: #e2e8f0; background: #1a1a1a; padding: 1px 6px; border-radius: 4px; white-space: nowrap; }
  .field-type   { font-size: 11px; color: #60a5fa; background: rgba(96,165,250,0.1); padding: 1px 6px; border-radius: 4px; white-space: nowrap; }
  .field-type.required { color: #f87171; background: rgba(248,113,113,0.1); }
  .field-desc   { font-size: 12px; color: #6b7280; }
  .response-sample { font-size: 11px; font-family: monospace; background: #0a0a0a; border: 1px solid #242424; border-radius: 10px; padding: 12px; color: #4ade80; line-height: 1.6; overflow-x: auto; }
  .tryit-box    { background: rgba(16,185,129,0.04); border: 1px solid rgba(16,185,129,0.12); border-radius: 12px; padding: 16px; }
  .tryit-input  { width: 100%; background: #121212; border: 1px solid #2e2e2e; border-radius: 8px; padding: 8px 12px; color: #e2e8f0; font-size: 13px; font-family: monospace; outline: none; transition: border-color .15s; }
  .tryit-input:focus { border-color: rgba(16,185,129,0.4); }
  .tryit-btn    { padding: 8px 18px; background: #10b981; color: white; border: none; border-radius: 9px; font-size: 13px; font-weight: 600; cursor: pointer; transition: background .15s; }
  .tryit-btn:hover { background: #059669; }
  .field-label  { display: block; font-size: 11px; color: #6b7280; margin-bottom: 4px; font-weight: 500; }
  .result-box   { background: #0a0a0a; border: 1px solid #1a1a1a; border-radius: 10px; padding: 14px; font-size: 12px; font-family: monospace; line-height: 1.6; max-height: 260px; overflow-y: auto; }
  .result-ok    { color: #4ade80; }
  .result-err   { color: #f87171; }
  .result-meta  { color: #374151; font-size: 11px; margin-bottom: 6px; }
  .code-block   { font-size: 12px; font-family: monospace; color: #a3e635; line-height: 1.7; overflow-x: auto; background: transparent; }
  .snippet-tab         { color: #6b7280; border-bottom: 2px solid transparent; transition: all .15s; }
  .snippet-tab:hover   { color: #9ca3af; }
  .snippet-tab-active  { color: #10b981; border-bottom-color: #10b981; background: rgba(16,185,129,0.05); }
</style>

<script>
const BASE = "{{ base_url }}";

function gv(id) { return document.getElementById(id)?.value?.trim() || ''; }

function toggle(id) {
  const el = document.querySelector(`[data-endpoint="${id}"] .endpoint-body`);
  const ch = document.querySelector(`[data-endpoint="${id}"] .chevron`);
  el.classList.toggle('hidden');
  ch.style.transform = el.classList.contains('hidden') ? '' : 'rotate(180deg)';
}

async function tryPost(path, body, resultId) {
  const el = document.getElementById(resultId);
  el.classList.remove('hidden');
  el.innerHTML = '<span class="result-meta">Sending…</span>';
  const t = Date.now();
  try {
    const r = await fetch(BASE + path, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body)
    });
    const data = await r.json();
    const ms = Date.now() - t;
    const isOk = data.valid || data.success || data.status === 'ok';
    el.innerHTML = `<div class="result-meta">HTTP ${r.status} · ${ms}ms</div><pre class="${isOk ? 'result-ok' : 'result-err'}">${JSON.stringify(data, null, 2)}</pre>`;
  } catch(e) {
    el.innerHTML = `<span class="result-err">Error: ${e.message}</span>`;
  }
}

async function tryGet(path, resultId) {
  const el = document.getElementById(resultId);
  el.classList.remove('hidden');
  el.innerHTML = '<span class="result-meta">Sending…</span>';
  const t = Date.now();
  try {
    const r = await fetch(BASE + path);
    const data = await r.json();
    const ms = Date.now() - t;
    el.innerHTML = `<div class="result-meta">HTTP ${r.status} · ${ms}ms</div><pre class="result-ok">${JSON.stringify(data, null, 2)}</pre>`;
  } catch(e) {
    el.innerHTML = `<span class="result-err">Error: ${e.message}</span>`;
  }
}

function toggleKeyVisibility() {
  const inp = document.getElementById('globalApiKey');
  const btn = event.target;
  if (inp.type === 'password') { inp.type = 'text'; btn.textContent = 'Hide'; }
  else { inp.type = 'password'; btn.textContent = 'Show'; }
}

function getApiKey() { return document.getElementById('globalApiKey')?.value?.trim() || ''; }

async function tryGetAuth(path, resultId) {
  const key = getApiKey();
  if (!key) { showResult(resultId, null, 'Paste your API key above first', true); return; }
  const el = document.getElementById(resultId);
  el.classList.remove('hidden');
  el.innerHTML = '<span class="result-meta">Sending…</span>';
  const t = Date.now();
  try {
    const r = await fetch(BASE + path, { headers: { 'X-API-Key': key } });
    const data = await r.json();
    const ms = Date.now() - t;
    el.innerHTML = `<div class="result-meta">HTTP ${r.status} · ${ms}ms</div><pre class="${r.ok ? 'result-ok' : 'result-err'}">${JSON.stringify(data, null, 2)}</pre>`;
  } catch(e) { el.innerHTML = `<span class="result-err">Error: ${e.message}</span>`; }
}

async function tryPatch(path, body, resultId) {
  const key = getApiKey();
  if (!key) { showResult(resultId, null, 'Paste your API key above first', true); return; }
  const el = document.getElementById(resultId);
  el.classList.remove('hidden');
  el.innerHTML = '<span class="result-meta">Sending…</span>';
  const t = Date.now();
  try {
    const r = await fetch(BASE + path, {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json', 'X-API-Key': key },
      body: JSON.stringify(body)
    });
    const data = await r.json();
    el.innerHTML = `<div class="result-meta">HTTP ${r.status} · ${Date.now()-t}ms</div><pre class="${r.ok?'result-ok':'result-err'}">${JSON.stringify(data,null,2)}</pre>`;
  } catch(e) { el.innerHTML = `<span class="result-err">Error: ${e.message}</span>`; }
}

async function tryPut(path, body, resultId) {
  const key = getApiKey();
  if (!key) { showResult(resultId, null, 'Paste your API key above first', true); return; }
  const el = document.getElementById(resultId);
  el.classList.remove('hidden');
  el.innerHTML = '<span class="result-meta">Sending…</span>';
  const t = Date.now();
  try {
    const r = await fetch(BASE + path, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json', 'X-API-Key': key },
      body: JSON.stringify(body)
    });
    const data = await r.json();
    el.innerHTML = `<div class="result-meta">HTTP ${r.status} · ${Date.now()-t}ms</div><pre class="${r.ok?'result-ok':'result-err'}">${JSON.stringify(data,null,2)}</pre>`;
  } catch(e) { el.innerHTML = `<span class="result-err">Error: ${e.message}</span>`; }
}

function showResult(resultId, status, msg, isErr) {
  const el = document.getElementById(resultId);
  el.classList.remove('hidden');
  el.innerHTML = `<span class="${isErr ? 'result-err' : 'result-ok'}">${msg}</span>`;
}


  document.querySelectorAll('.snippet-content').forEach(el => el.classList.add('hidden'));
  document.querySelectorAll('.snippet-tab').forEach(el => el.classList.remove('snippet-tab-active'));
  document.getElementById('snippet-' + lang).classList.remove('hidden');
  document.getElementById('tab-' + lang).classList.add('snippet-tab-active');
}
</script>
{% endblock %}
OPSLAB_LIC_EOF__7f2d8a5e

say "Writing app/licenses/templates/admin/bulk_create.html"
write_file 'app/licenses/templates/admin/bulk_create.html' << 'OPSLAB_LIC_EOF__7f2d8a5e'
{% extends "licenses/base.html" %}
{% block title %}Bulk Create Licenses - License Manager{% endblock %}

{% block content %}
<div class="mb-6">
    <h1 class="text-2xl font-bold">Bulk Create Licenses</h1>
    <p class="text-gray-500">Generate multiple license keys at once</p>
</div>

<form method="POST" class="max-w-xl space-y-6">
    <div class="bg-dark-800 border border-dark-600 rounded-xl p-6 space-y-4">
        <div>
            <label class="block text-sm font-medium text-gray-300 mb-2">Number of Licenses *</label>
            <input type="number" name="count" value="10" min="1" max="100" required
                class="w-full px-4 py-2.5 bg-dark-700 border border-dark-500 rounded-lg focus:outline-none focus:border-emerald-500">
            <p class="text-xs text-gray-500 mt-1">Maximum 100 at once</p>
        </div>
        
        <div>
            <label class="block text-sm font-medium text-gray-300 mb-2">Product *</label>
            <select name="product_id" required
                class="w-full px-4 py-2.5 bg-dark-700 border border-dark-500 rounded-lg focus:outline-none focus:border-emerald-500">
                {% for product in products %}
                <option value="{{ product.id }}">{{ product.name }}</option>
                {% endfor %}
            </select>
        </div>
        
        <div>
            <label class="block text-sm font-medium text-gray-300 mb-2">Tier *</label>
            <select name="tier_id" required
                class="w-full px-4 py-2.5 bg-dark-700 border border-dark-500 rounded-lg focus:outline-none focus:border-emerald-500">
                {% for tier in tiers %}
                <option value="{{ tier.id }}">{{ tier.name }}</option>
                {% endfor %}
            </select>
        </div>
        
        <div>
            <label class="block text-sm font-medium text-gray-300 mb-2">Duration</label>
            <select name="duration"
                class="w-full px-4 py-2.5 bg-dark-700 border border-dark-500 rounded-lg focus:outline-none focus:border-emerald-500">
                <option value="lifetime">Lifetime</option>
                <option value="monthly">30 Days</option>
                <option value="yearly">1 Year</option>
            </select>
        </div>
    </div>
    
    <div class="flex gap-4">
        <button type="submit" class="px-6 py-2.5 bg-emerald-600 hover:bg-emerald-700 text-white font-medium rounded-lg">
            Generate Licenses
        </button>
        <a href="{{ url_for('lic_admin.licenses') }}" class="px-6 py-2.5 bg-dark-700 hover:bg-dark-600 rounded-lg border border-dark-500">
            Cancel
        </a>
    </div>
</form>
{% endblock %}
OPSLAB_LIC_EOF__7f2d8a5e

say "Writing app/licenses/templates/admin/bulk_result.html"
write_file 'app/licenses/templates/admin/bulk_result.html' << 'OPSLAB_LIC_EOF__7f2d8a5e'
{% extends "licenses/base.html" %}
{% block title %}Licenses Created - License Manager{% endblock %}

{% block content %}
<div class="mb-6">
    <h1 class="text-2xl font-bold">Licenses Created</h1>
    <p class="text-gray-500">{{ keys|length }} license keys generated successfully</p>
</div>

<div class="bg-dark-800 border border-dark-600 rounded-xl p-6">
    <div class="flex items-center justify-between mb-4">
        <h2 class="font-semibold">License Keys</h2>
        <button onclick="copyAll()" class="px-4 py-2 bg-emerald-600 hover:bg-emerald-700 text-white text-sm rounded-lg transition-colors">
            Copy All
        </button>
    </div>
    
    <div class="bg-dark-900 rounded-lg p-4 font-mono text-sm max-h-96 overflow-y-auto">
        {% for key in keys %}
        <div class="py-1">{{ key }}</div>
        {% endfor %}
    </div>
    
    <textarea id="allKeys" class="hidden">{% for key in keys %}{{ key }}
{% endfor %}</textarea>
</div>

<div class="mt-6 flex gap-4">
    <a href="{{ url_for('lic_admin.licenses') }}" class="px-4 py-2 bg-dark-700 hover:bg-dark-600 rounded-lg border border-dark-500 transition-colors">
        View All Licenses
    </a>
    <a href="{{ url_for('lic_admin.bulk_create_licenses') }}" class="px-4 py-2 bg-dark-700 hover:bg-dark-600 rounded-lg border border-dark-500 transition-colors">
        Create More
    </a>
</div>

<script>
function copyAll() {
    const text = document.getElementById('allKeys').value;
    navigator.clipboard.writeText(text);
    alert('Copied ' + {{ keys|length }} + ' keys to clipboard!');
}
</script>
{% endblock %}
OPSLAB_LIC_EOF__7f2d8a5e

say "Writing app/licenses/templates/admin/create_customer.html"
write_file 'app/licenses/templates/admin/create_customer.html' << 'OPSLAB_LIC_EOF__7f2d8a5e'
{% extends "licenses/base.html" %}
{% block title %}Add Customer - License Manager{% endblock %}

{% block content %}
<div class="mb-6">
    <h1 class="text-2xl font-bold">Add Customer</h1>
    <p class="text-gray-500">Create a new customer account</p>
</div>

<form method="POST" class="max-w-xl space-y-6">
    <div class="bg-dark-800 border border-dark-600 rounded-xl p-6 space-y-4">
        <div>
            <label class="block text-sm font-medium text-gray-300 mb-2">Email *</label>
            <input type="email" name="email" required
                class="w-full px-4 py-2.5 bg-dark-700 border border-dark-500 rounded-lg focus:outline-none focus:border-emerald-500">
        </div>
        
        <div>
            <label class="block text-sm font-medium text-gray-300 mb-2">Company Name</label>
            <input type="text" name="company_name"
                class="w-full px-4 py-2.5 bg-dark-700 border border-dark-500 rounded-lg focus:outline-none focus:border-emerald-500">
        </div>
        
        <div>
            <label class="block text-sm font-medium text-gray-300 mb-2">Contact Name</label>
            <input type="text" name="contact_name"
                class="w-full px-4 py-2.5 bg-dark-700 border border-dark-500 rounded-lg focus:outline-none focus:border-emerald-500">
        </div>
        
        <div>
            <label class="block text-sm font-medium text-gray-300 mb-2">Phone</label>
            <input type="text" name="phone"
                class="w-full px-4 py-2.5 bg-dark-700 border border-dark-500 rounded-lg focus:outline-none focus:border-emerald-500">
        </div>
        
        <div>
            <label class="block text-sm font-medium text-gray-300 mb-2">Address</label>
            <textarea name="address" rows="2"
                class="w-full px-4 py-2.5 bg-dark-700 border border-dark-500 rounded-lg focus:outline-none focus:border-emerald-500"></textarea>
        </div>
        
        <div>
            <label class="block text-sm font-medium text-gray-300 mb-2">Notes</label>
            <textarea name="notes" rows="2"
                class="w-full px-4 py-2.5 bg-dark-700 border border-dark-500 rounded-lg focus:outline-none focus:border-emerald-500"></textarea>
        </div>
    </div>
    
    <div class="flex gap-4">
        <button type="submit" class="px-6 py-2.5 bg-emerald-600 hover:bg-emerald-700 text-white font-medium rounded-lg">
            Create Customer
        </button>
        <a href="{{ url_for('lic_admin.customers') }}" class="px-6 py-2.5 bg-dark-700 hover:bg-dark-600 rounded-lg border border-dark-500">
            Cancel
        </a>
    </div>
</form>
{% endblock %}
OPSLAB_LIC_EOF__7f2d8a5e

say "Writing app/licenses/templates/admin/create_feature.html"
write_file 'app/licenses/templates/admin/create_feature.html' << 'OPSLAB_LIC_EOF__7f2d8a5e'
{% extends "licenses/base.html" %}
{% block title %}New Feature — {{ site_name }}{% endblock %}

{% block content %}
<div class="p-6 max-w-2xl">

  <!-- Header -->
  <div class="flex items-center gap-3 mb-6">
    <a href="{{ url_for('lic_admin.features') }}"
       class="p-2 text-gray-400 hover:text-white hover:bg-dark-700 rounded-lg transition-colors">
      <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 19l-7-7 7-7"/>
      </svg>
    </a>
    <div>
      <h1 class="text-2xl font-bold text-white">New Feature</h1>
      <p class="text-sm text-gray-500">Define a feature that can be assigned to licences</p>
    </div>
  </div>

  <form method="POST" class="bg-dark-800 border border-dark-700/50 rounded-2xl p-6 space-y-5">
    <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">

    <!-- Name -->
    <div>
      <label class="block text-sm font-medium text-gray-300 mb-1.5">Feature Name <span class="text-red-400">*</span></label>
      <input type="text" name="name" required placeholder="e.g. Dispatch Module"
             class="w-full bg-dark-700 border border-dark-600 rounded-xl px-4 py-2.5 text-white placeholder-gray-600 focus:border-emerald-500/50 focus:ring-1 focus:ring-emerald-500/30 outline-none transition text-sm"
             oninput="autoCode(this.value)">
    </div>

    <!-- Code -->
    <div>
      <label class="block text-sm font-medium text-gray-300 mb-1.5">Feature Code <span class="text-red-400">*</span></label>
      <input type="text" name="code" id="codeField" required placeholder="e.g. dispatch"
             class="w-full bg-dark-700 border border-dark-600 rounded-xl px-4 py-2.5 text-white placeholder-gray-600 focus:border-emerald-500/50 focus:ring-1 focus:ring-emerald-500/30 outline-none transition text-sm font-mono">
      <p class="text-xs text-gray-600 mt-1">Lowercase, underscores only. This is what the API returns.</p>
    </div>

    <!-- Category -->
    <div>
      <label class="block text-sm font-medium text-gray-300 mb-1.5">Category</label>
      <input type="text" name="category" placeholder="e.g. cad, billing, reports"
             class="w-full bg-dark-700 border border-dark-600 rounded-xl px-4 py-2.5 text-white placeholder-gray-600 focus:border-emerald-500/50 focus:ring-1 focus:ring-emerald-500/30 outline-none transition text-sm">
      <p class="text-xs text-gray-600 mt-1">Groups features together in the UI and API response</p>
    </div>

    <!-- Description -->
    <div>
      <label class="block text-sm font-medium text-gray-300 mb-1.5">Description</label>
      <textarea name="description" rows="3" placeholder="What does this feature enable?"
                class="w-full bg-dark-700 border border-dark-600 rounded-xl px-4 py-2.5 text-white placeholder-gray-600 focus:border-emerald-500/50 focus:ring-1 focus:ring-emerald-500/30 outline-none transition text-sm resize-none"></textarea>
    </div>

    <!-- Icon hint -->
    <div>
      <label class="block text-sm font-medium text-gray-300 mb-1.5">Icon (Heroicon name)</label>
      <input type="text" name="icon" placeholder="e.g. puzzle, chart-bar, cog"
             class="w-full bg-dark-700 border border-dark-600 rounded-xl px-4 py-2.5 text-white placeholder-gray-600 focus:border-emerald-500/50 focus:ring-1 focus:ring-emerald-500/30 outline-none transition text-sm font-mono">
      <p class="text-xs text-gray-600 mt-1">Optional. Used for display purposes only.</p>
    </div>

    <!-- Actions -->
    <div class="flex items-center gap-3 pt-2">
      <button type="submit"
              class="px-5 py-2.5 bg-emerald-500 hover:bg-emerald-400 text-white rounded-xl font-semibold text-sm transition-colors shadow-lg shadow-emerald-500/20">
        Create Feature
      </button>
      <a href="{{ url_for('lic_admin.features') }}"
         class="px-5 py-2.5 bg-dark-700 hover:bg-dark-600 text-gray-300 rounded-xl font-semibold text-sm transition-colors">
        Cancel
      </a>
    </div>
  </form>
</div>

<script>
let userEditedCode = false;
function autoCode(name) {
  if (userEditedCode) return;
  document.getElementById('codeField').value = name.toLowerCase()
    .replace(/[^a-z0-9\s]/g, '').replace(/\s+/g, '_');
}
document.getElementById('codeField').addEventListener('input', () => { userEditedCode = true; });
</script>
{% endblock %}
OPSLAB_LIC_EOF__7f2d8a5e

say "Writing app/licenses/templates/admin/create_license.html"
write_file 'app/licenses/templates/admin/create_license.html' << 'OPSLAB_LIC_EOF__7f2d8a5e'
{% extends "licenses/base.html" %}
{% block title %}Create License - License Manager{% endblock %}

{% block content %}
<div class="mb-6">
    <h1 class="text-2xl font-bold">Create License</h1>
    <p class="text-gray-500">Generate a new license key</p>
</div>

<form method="POST" class="max-w-2xl space-y-6">
    <div class="bg-dark-800 border border-dark-600 rounded-xl p-6 space-y-4">
        <h2 class="font-semibold mb-4">License Details</h2>
        
        <div class="grid grid-cols-2 gap-4">
            <div>
                <label class="block text-sm font-medium text-gray-300 mb-2">Product *</label>
                <select name="product_id" id="product_id" required
                    class="w-full px-4 py-2.5 bg-dark-700 border border-dark-500 rounded-lg focus:outline-none focus:border-emerald-500">
                    {% for product in products %}
                    <option value="{{ product.id }}">{{ product.name }}</option>
                    {% endfor %}
                </select>
            </div>
            
            <div>
                <label class="block text-sm font-medium text-gray-300 mb-2">Tier *</label>
                <select name="tier_id" id="tier_id" required
                    class="w-full px-4 py-2.5 bg-dark-700 border border-dark-500 rounded-lg focus:outline-none focus:border-emerald-500">
                    {% for tier in tiers %}
                    <option value="{{ tier.id }}" data-product="{{ tier.product_id }}">{{ tier.name }} ({{ tier.max_users or 'Unlimited' }} users)</option>
                    {% endfor %}
                </select>
            </div>
        </div>
        
        <div>
            <label class="block text-sm font-medium text-gray-300 mb-2">Customer (Optional)</label>
            <select name="customer_id"
                class="w-full px-4 py-2.5 bg-dark-700 border border-dark-500 rounded-lg focus:outline-none focus:border-emerald-500">
                <option value="">— No customer —</option>
                {% for customer in customers %}
                <option value="{{ customer.id }}">{{ customer.company_name or customer.email }}</option>
                {% endfor %}
            </select>
        </div>
        
        <div>
            <label class="block text-sm font-medium text-gray-300 mb-2">Duration</label>
            <div class="flex gap-4">
                <label class="flex items-center gap-2">
                    <input type="radio" name="duration" value="lifetime" checked class="text-emerald-500 bg-dark-700 border-dark-500">
                    <span>Lifetime</span>
                </label>
                <label class="flex items-center gap-2">
                    <input type="radio" name="duration" value="monthly" class="text-emerald-500 bg-dark-700 border-dark-500">
                    <span>30 Days</span>
                </label>
                <label class="flex items-center gap-2">
                    <input type="radio" name="duration" value="yearly" class="text-emerald-500 bg-dark-700 border-dark-500">
                    <span>1 Year</span>
                </label>
                <label class="flex items-center gap-2">
                    <input type="radio" name="duration" value="custom" class="text-emerald-500 bg-dark-700 border-dark-500">
                    <span>Custom</span>
                </label>
            </div>
            <input type="date" name="custom_expiry" id="custom_expiry"
                class="mt-2 w-48 px-4 py-2 bg-dark-700 border border-dark-500 rounded-lg focus:outline-none focus:border-emerald-500 hidden">
        </div>
        
        <div class="grid grid-cols-2 gap-4">
            <div>
                <label class="block text-sm font-medium text-gray-300 mb-2">Max Activations</label>
                <input type="number" name="max_activations" value="1" min="1" max="100"
                    class="w-full px-4 py-2.5 bg-dark-700 border border-dark-500 rounded-lg focus:outline-none focus:border-emerald-500">
            </div>
            
            <div>
                <label class="block text-sm font-medium text-gray-300 mb-2">Lock to Domain (Optional)</label>
                <input type="text" name="domain" placeholder="example.com"
                    class="w-full px-4 py-2.5 bg-dark-700 border border-dark-500 rounded-lg focus:outline-none focus:border-emerald-500">
            </div>
        </div>
        
        <div>
            <label class="block text-sm font-medium text-gray-300 mb-2">Notes (Optional)</label>
            <textarea name="notes" rows="2"
                class="w-full px-4 py-2.5 bg-dark-700 border border-dark-500 rounded-lg focus:outline-none focus:border-emerald-500"
                placeholder="Internal notes about this license..."></textarea>
        </div>
    </div>
    
    <!-- Feature Assignment -->
    <div class="bg-dark-800 border border-dark-600 rounded-xl p-6 space-y-4">
      <div class="flex items-center justify-between">
        <div>
          <h2 class="text-sm font-semibold text-gray-400 uppercase tracking-wider">Licence Features</h2>
          <p class="text-xs text-gray-600 mt-0.5">Select which features this licence grants — returned by the API on validation</p>
        </div>
        <div class="flex gap-2">
          <button type="button" onclick="selectAll(true)" class="text-xs text-emerald-400 hover:text-emerald-300 px-2 py-1 hover:bg-emerald-500/10 rounded-lg transition-colors">Select all</button>
          <button type="button" onclick="selectAll(false)" class="text-xs text-gray-500 hover:text-gray-300 px-2 py-1 hover:bg-dark-600 rounded-lg transition-colors">Clear</button>
        </div>
      </div>
      {% if grouped_features %}
        {% for product_group, categories in grouped_features.items() %}
        <!-- Product group -->
        <div class="border border-dark-700/50 rounded-xl overflow-hidden">
          <div class="px-4 py-2.5 bg-dark-700/40 border-b border-dark-700/30 flex items-center justify-between">
            <div class="flex items-center gap-2">
              <div class="w-5 h-5 rounded bg-emerald-500/10 flex items-center justify-center">
                <svg class="w-3 h-3 text-emerald-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M20 7l-8-4-8 4m16 0l-8 4m8-4v10l-8 4m0-10L4 7m8 4v10M4 7v10l8 4"/>
                </svg>
              </div>
              <span class="text-xs font-bold text-gray-300">{{ product_group }}</span>
            </div>
            <div class="flex gap-1.5">
              <button type="button" onclick="selectGroup('{{ product_group|replace(' ','-') }}', true)"
                      class="text-xs text-emerald-400 hover:text-emerald-300 px-1.5 py-0.5 hover:bg-emerald-500/10 rounded transition-colors">All</button>
              <button type="button" onclick="selectGroup('{{ product_group|replace(' ','-') }}', false)"
                      class="text-xs text-gray-600 hover:text-gray-400 px-1.5 py-0.5 hover:bg-dark-600 rounded transition-colors">None</button>
            </div>
          </div>
          <div class="p-3 space-y-3">
            {% for category, cat_features in categories.items() %}
            <div class="space-y-1">
              <p class="text-xs font-semibold text-gray-600 uppercase tracking-wider px-1">{{ category }}</p>
              {% for feature in cat_features %}
              <label class="flex items-center gap-3 px-3 py-2 rounded-xl border cursor-pointer transition-all bg-dark-700/40 border-dark-600/50 text-gray-400 hover:border-dark-500"
                     id="label-{{ feature.id }}">
                <input type="checkbox" name="feature_ids" value="{{ feature.id }}"
                       class="hidden feature-cb" data-pg="{{ product_group|replace(' ','-') }}" onchange="styleLabel(this)">
                <div class="w-4 h-4 rounded border bg-transparent border-dark-500 flex items-center justify-center flex-shrink-0 transition-all" id="box-{{ feature.id }}"></div>
                <div class="flex-1 min-w-0">
                  <p class="text-sm font-medium leading-none">{{ feature.name }}</p>
                  {% if feature.description %}<p class="text-xs text-gray-600 mt-0.5 truncate">{{ feature.description }}</p>{% endif %}
                </div>
                <code class="text-xs font-mono text-gray-600 flex-shrink-0">{{ feature.code }}</code>
              </label>
              {% endfor %}
            </div>
            {% endfor %}
          </div>
        </div>
        {% endfor %}
      {% else %}
        <p class="text-sm text-gray-600 text-center py-4">No features defined yet. <a href="{{ url_for('lic_admin.create_feature') }}" class="text-emerald-400">Create features →</a></p>
      {% endif %}
    </div>

    <div class="flex gap-4">
        <button type="submit" class="px-6 py-2.5 bg-emerald-600 hover:bg-emerald-700 text-white font-medium rounded-lg transition-colors">
            Generate License
        </button>
        <a href="{{ url_for('lic_admin.licenses') }}" class="px-6 py-2.5 bg-dark-700 hover:bg-dark-600 text-white rounded-lg border border-dark-500 transition-colors">
            Cancel
        </a>
    </div>
</form>

<script>
    // Show/hide custom date input
    document.querySelectorAll('input[name="duration"]').forEach(radio => {
        radio.addEventListener('change', function() {
            document.getElementById('custom_expiry').classList.toggle('hidden', this.value !== 'custom');
        });
    });
    
    // Filter tiers by product
    document.getElementById('product_id').addEventListener('change', function() {
        const productId = this.value;
        const tierSelect = document.getElementById('tier_id');
        
        Array.from(tierSelect.options).forEach(option => {
            if (option.dataset.product) {
                option.hidden = option.dataset.product !== productId;
            }
        });
        
        // Select first visible option
        const firstVisible = Array.from(tierSelect.options).find(o => !o.hidden);
        if (firstVisible) tierSelect.value = firstVisible.value;
    });

    // Feature picker
    const CHECK_SVG = '<svg class="w-3 h-3 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="3" d="M5 13l4 4L19 7"/></svg>';
    function styleLabel(cb) {
      const id = cb.value;
      const label = document.getElementById('label-' + id);
      const box   = document.getElementById('box-' + id);
      const on    = cb.checked;
      label.classList.toggle('bg-emerald-500/10', on);
      label.classList.toggle('border-emerald-500/30', on);
      label.classList.toggle('text-white', on);
      label.classList.toggle('bg-dark-700/40', !on);
      label.classList.toggle('border-dark-600/50', !on);
      label.classList.toggle('text-gray-400', !on);
      box.classList.toggle('bg-emerald-500', on);
      box.classList.toggle('border-emerald-500', on);
      box.classList.toggle('bg-transparent', !on);
      box.classList.toggle('border-dark-500', !on);
      box.innerHTML = on ? CHECK_SVG : '';
    }
    function selectAll(state) {
      document.querySelectorAll('.feature-cb').forEach(cb => { cb.checked = state; styleLabel(cb); });
    }
    function selectGroup(pg, state) {
      document.querySelectorAll(`.feature-cb[data-pg="${pg}"]`).forEach(cb => { cb.checked = state; styleLabel(cb); });
    }
</script>
{% endblock %}
OPSLAB_LIC_EOF__7f2d8a5e

say "Writing app/licenses/templates/admin/create_product.html"
write_file 'app/licenses/templates/admin/create_product.html' << 'OPSLAB_LIC_EOF__7f2d8a5e'
{% extends "licenses/base.html" %}
{% block title %}Create Product - License Manager{% endblock %}

{% block content %}
<div class="mb-6">
    <a href="{{ url_for('lic_admin.products') }}" class="text-gray-500 hover:text-gray-300 text-sm mb-2 inline-block">← Back to Products</a>
    <h1 class="text-2xl font-bold">Create Product</h1>
</div>

<form method="POST" class="max-w-xl space-y-6">
    <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
    
    <div class="bg-dark-800 border border-dark-600 rounded-xl p-6 space-y-4">
        <div>
            <label class="block text-sm font-medium text-gray-300 mb-2">Product Name *</label>
            <input type="text" name="name" required
                class="w-full px-4 py-2.5 bg-dark-700 border border-dark-500 rounded-lg focus:outline-none focus:border-emerald-500"
                placeholder="Staff Scheduler">
        </div>
        
        <div>
            <label class="block text-sm font-medium text-gray-300 mb-2">Product Code *</label>
            <input type="text" name="code" required
                class="w-full px-4 py-2.5 bg-dark-700 border border-dark-500 rounded-lg focus:outline-none focus:border-emerald-500 uppercase"
                placeholder="STAFF_SCHEDULER">
            <p class="text-xs text-gray-500 mt-1">Unique identifier (auto-uppercased)</p>
        </div>
        
        <div>
            <label class="block text-sm font-medium text-gray-300 mb-2">Description</label>
            <textarea name="description" rows="3"
                class="w-full px-4 py-2.5 bg-dark-700 border border-dark-500 rounded-lg focus:outline-none focus:border-emerald-500"></textarea>
        </div>
    </div>
    
    <div class="bg-dark-800 border border-dark-600 rounded-xl p-6 space-y-4">
        <h2 class="font-semibold">IP Lock Settings</h2>
        
        <div>
            <label class="flex items-center gap-2">
                <input type="checkbox" name="require_ip_lock" checked
                    class="w-4 h-4 bg-dark-700 border-dark-500 rounded text-emerald-500">
                <span>Require IP Lock</span>
            </label>
            <p class="text-xs text-gray-500 mt-1 ml-6">License will only work from registered IPs</p>
        </div>
        
        <div>
            <label class="block text-sm font-medium text-gray-300 mb-2">Max IP Addresses</label>
            <input type="number" name="max_ip_addresses" value="2" min="1" max="100"
                class="w-full px-4 py-2.5 bg-dark-700 border border-dark-500 rounded-lg focus:outline-none focus:border-emerald-500">
        </div>
        
        <div>
            <label class="flex items-center gap-2">
                <input type="checkbox" name="allow_ip_change" checked
                    class="w-4 h-4 bg-dark-700 border-dark-500 rounded text-emerald-500">
                <span>Allow IP Changes</span>
            </label>
            <p class="text-xs text-gray-500 mt-1 ml-6">Customers can change their IPs in the portal</p>
        </div>
        
        <div>
            <label class="block text-sm font-medium text-gray-300 mb-2">IP Change Cooldown (hours)</label>
            <input type="number" name="ip_change_cooldown" value="24" min="0"
                class="w-full px-4 py-2.5 bg-dark-700 border border-dark-500 rounded-lg focus:outline-none focus:border-emerald-500">
            <p class="text-xs text-gray-500 mt-1">Time between IP changes (0 = no limit)</p>
        </div>
    </div>
    
    <div class="flex gap-4">
        <button type="submit" class="px-6 py-2.5 bg-emerald-600 hover:bg-emerald-700 text-white font-medium rounded-lg">
            Create Product
        </button>
        <a href="{{ url_for('lic_admin.products') }}" class="px-6 py-2.5 bg-dark-700 hover:bg-dark-600 rounded-lg border border-dark-500">
            Cancel
        </a>
    </div>
</form>
{% endblock %}
OPSLAB_LIC_EOF__7f2d8a5e

say "Writing app/licenses/templates/admin/create_role.html"
write_file 'app/licenses/templates/admin/create_role.html' << 'OPSLAB_LIC_EOF__7f2d8a5e'
{% extends "licenses/base.html" %}
{% block title %}Create Role - {{ site_name }}{% endblock %}

{% block content %}
<div class="mb-8">
    <a href="{{ url_for('lic_admin.roles') }}" class="text-gray-500 hover:text-gray-300 text-sm mb-2 inline-flex items-center gap-1">
        <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 19l-7-7 7-7"/></svg>
        Back to Roles
    </a>
    <h1 class="text-3xl font-bold bg-gradient-to-r from-white to-gray-400 bg-clip-text text-transparent">Create Role</h1>
</div>

<form method="POST" class="max-w-4xl">
    <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
    
    <div class="bg-dark-800/50 backdrop-blur border border-dark-700/50 rounded-2xl p-6 mb-6">
        <h2 class="text-lg font-semibold mb-4">Role Details</h2>
        <div class="grid md:grid-cols-2 gap-5">
            <div>
                <label class="block text-sm font-medium text-gray-300 mb-2">Role Name</label>
                <input type="text" name="name" required
                    class="w-full px-4 py-2.5 bg-dark-700 border border-dark-600 rounded-xl focus:outline-none focus:border-{{ primary_color }}-500">
            </div>
            <div>
                <label class="block text-sm font-medium text-gray-300 mb-2">Color</label>
                <select name="color" class="w-full px-4 py-2.5 bg-dark-700 border border-dark-600 rounded-xl focus:outline-none focus:border-{{ primary_color }}-500">
                    {% for color in ['gray', 'red', 'orange', 'amber', 'yellow', 'lime', 'green', 'emerald', 'teal', 'cyan', 'blue', 'indigo', 'violet', 'purple', 'pink', 'rose'] %}
                    <option value="{{ color }}">{{ color|title }}</option>
                    {% endfor %}
                </select>
            </div>
            <div class="md:col-span-2">
                <label class="block text-sm font-medium text-gray-300 mb-2">Description</label>
                <input type="text" name="description"
                    class="w-full px-4 py-2.5 bg-dark-700 border border-dark-600 rounded-xl focus:outline-none focus:border-{{ primary_color }}-500">
            </div>
        </div>
    </div>
    
    <div class="bg-dark-800/50 backdrop-blur border border-dark-700/50 rounded-2xl p-6 mb-6">
        <h2 class="text-lg font-semibold mb-4">Permissions</h2>
        <div class="space-y-6">
            {% for category, perms in permissions.items() %}
            <div>
                <h3 class="text-sm font-medium text-gray-400 uppercase tracking-wider mb-3">{{ category }}</h3>
                <div class="grid md:grid-cols-2 lg:grid-cols-3 gap-3">
                    {% for perm in perms %}
                    <label class="flex items-center gap-3 p-3 bg-dark-700/50 rounded-xl hover:bg-dark-700 cursor-pointer transition-colors">
                        <input type="checkbox" name="permissions" value="{{ perm.id }}" class="w-4 h-4 rounded bg-dark-600 border-dark-500 text-{{ primary_color }}-500 focus:ring-{{ primary_color }}-500">
                        <div>
                            <p class="text-sm font-medium">{{ perm.name }}</p>
                            {% if perm.description %}
                            <p class="text-xs text-gray-500">{{ perm.description }}</p>
                            {% endif %}
                        </div>
                    </label>
                    {% endfor %}
                </div>
            </div>
            {% endfor %}
        </div>
    </div>
    
    <div class="flex gap-3">
        <button type="submit" class="px-6 py-2.5 bg-gradient-to-r from-{{ primary_color }}-500 to-{{ primary_color }}-600 hover:from-{{ primary_color }}-400 hover:to-{{ primary_color }}-500 text-white font-medium rounded-xl shadow-lg shadow-{{ primary_color }}-500/25 transition-all">
            Create Role
        </button>
        <a href="{{ url_for('lic_admin.roles') }}" class="px-6 py-2.5 bg-dark-700 hover:bg-dark-600 rounded-xl font-medium transition-colors">Cancel</a>
    </div>
</form>
{% endblock %}
OPSLAB_LIC_EOF__7f2d8a5e

say "Writing app/licenses/templates/admin/create_tier.html"
write_file 'app/licenses/templates/admin/create_tier.html' << 'OPSLAB_LIC_EOF__7f2d8a5e'
{% extends "licenses/base.html" %}
{% block title %}Create Tier - {{ product.name }} - License Manager{% endblock %}

{% block content %}
<div class="mb-6">
    <a href="{{ url_for('lic_admin.edit_tiers', id=product.id) }}" class="text-gray-500 hover:text-gray-300 text-sm mb-2 inline-block">← Back to Tiers</a>
    <h1 class="text-2xl font-bold">Create Tier</h1>
    <p class="text-gray-500">{{ product.name }}</p>
</div>

<form method="POST" class="max-w-xl space-y-6">
    <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
    
    <div class="bg-dark-800 border border-dark-600 rounded-xl p-6 space-y-4">
        <div class="grid grid-cols-2 gap-4">
            <div>
                <label class="block text-sm font-medium text-gray-300 mb-2">Tier Name *</label>
                <input type="text" name="name" required
                    class="w-full px-4 py-2.5 bg-dark-700 border border-dark-500 rounded-lg focus:outline-none focus:border-emerald-500"
                    placeholder="Professional">
            </div>
            <div>
                <label class="block text-sm font-medium text-gray-300 mb-2">Tier Code *</label>
                <input type="text" name="code" required
                    class="w-full px-4 py-2.5 bg-dark-700 border border-dark-500 rounded-lg focus:outline-none focus:border-emerald-500"
                    placeholder="pro">
            </div>
        </div>
        
        <div class="grid grid-cols-2 gap-4">
            <div>
                <label class="block text-sm font-medium text-gray-300 mb-2">Monthly Price ($)</label>
                <input type="number" name="price_monthly" value="0" step="0.01"
                    class="w-full px-4 py-2.5 bg-dark-700 border border-dark-500 rounded-lg focus:outline-none focus:border-emerald-500">
            </div>
            <div>
                <label class="block text-sm font-medium text-gray-300 mb-2">Yearly Price ($)</label>
                <input type="number" name="price_yearly" value="0" step="0.01"
                    class="w-full px-4 py-2.5 bg-dark-700 border border-dark-500 rounded-lg focus:outline-none focus:border-emerald-500">
            </div>
        </div>
        
        <div class="grid grid-cols-2 gap-4">
            <div>
                <label class="block text-sm font-medium text-gray-300 mb-2">Max Users (0=unlimited)</label>
                <input type="number" name="max_users" value="0"
                    class="w-full px-4 py-2.5 bg-dark-700 border border-dark-500 rounded-lg focus:outline-none focus:border-emerald-500">
            </div>
            <div>
                <label class="block text-sm font-medium text-gray-300 mb-2">Sort Order</label>
                <input type="number" name="sort_order" value="0"
                    class="w-full px-4 py-2.5 bg-dark-700 border border-dark-500 rounded-lg focus:outline-none focus:border-emerald-500">
            </div>
        </div>
        
        <div>
            <label class="block text-sm font-medium text-gray-300 mb-2">Features</label>
            <div class="flex flex-wrap gap-4">
                {% for feature in ['schedule', 'leave', 'tasks', 'board', 'finance', 'reports', 'api_access', 'white_label'] %}
                <label class="flex items-center gap-2">
                    <input type="checkbox" name="{{ feature }}"
                        class="w-4 h-4 bg-dark-700 border-dark-500 rounded text-emerald-500">
                    <span class="text-sm capitalize">{{ feature.replace('_', ' ') }}</span>
                </label>
                {% endfor %}
            </div>
        </div>
    </div>
    
    <div class="flex gap-4">
        <button type="submit" class="px-6 py-2.5 bg-emerald-600 hover:bg-emerald-700 text-white font-medium rounded-lg">
            Create Tier
        </button>
        <a href="{{ url_for('lic_admin.edit_tiers', id=product.id) }}" class="px-6 py-2.5 bg-dark-700 hover:bg-dark-600 rounded-lg border border-dark-500">
            Cancel
        </a>
    </div>
</form>
{% endblock %}
OPSLAB_LIC_EOF__7f2d8a5e

say "Writing app/licenses/templates/admin/create_user.html"
write_file 'app/licenses/templates/admin/create_user.html' << 'OPSLAB_LIC_EOF__7f2d8a5e'
{% extends "licenses/base.html" %}
{% block title %}Create User - {{ site_name }}{% endblock %}

{% block content %}
<div class="mb-8">
    <a href="{{ url_for('lic_admin.admin_users') }}" class="text-gray-500 hover:text-gray-300 text-sm mb-2 inline-flex items-center gap-1">
        <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 19l-7-7 7-7"/></svg>
        Back to Users
    </a>
    <h1 class="text-3xl font-bold bg-gradient-to-r from-white to-gray-400 bg-clip-text text-transparent">Create Admin User</h1>
</div>

<form method="POST" class="max-w-2xl">
    <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
    
    <div class="bg-dark-800/50 backdrop-blur border border-dark-700/50 rounded-2xl p-6 space-y-5">
        <div class="grid md:grid-cols-2 gap-5">
            <div>
                <label class="block text-sm font-medium text-gray-300 mb-2">Name</label>
                <input type="text" name="name" required
                    class="w-full px-4 py-2.5 bg-dark-700 border border-dark-600 rounded-xl focus:outline-none focus:border-{{ primary_color }}-500">
            </div>
            <div>
                <label class="block text-sm font-medium text-gray-300 mb-2">Email</label>
                <input type="email" name="email" required
                    class="w-full px-4 py-2.5 bg-dark-700 border border-dark-600 rounded-xl focus:outline-none focus:border-{{ primary_color }}-500">
            </div>
        </div>
        
        <div>
            <label class="block text-sm font-medium text-gray-300 mb-2">Password</label>
            <input type="password" name="password" required minlength="6"
                class="w-full px-4 py-2.5 bg-dark-700 border border-dark-600 rounded-xl focus:outline-none focus:border-{{ primary_color }}-500">
        </div>
        
        <div>
            <label class="block text-sm font-medium text-gray-300 mb-2">Avatar Color</label>
            <select name="avatar_color" class="w-full px-4 py-2.5 bg-dark-700 border border-dark-600 rounded-xl focus:outline-none focus:border-{{ primary_color }}-500">
                {% for color in ['emerald', 'blue', 'purple', 'rose', 'amber', 'cyan', 'indigo', 'pink', 'red', 'orange'] %}
                <option value="{{ color }}">{{ color|title }}</option>
                {% endfor %}
            </select>
        </div>
        
        <div>
            <label class="block text-sm font-medium text-gray-300 mb-2">Roles</label>
            <div class="grid md:grid-cols-2 gap-3">
                {% for role in roles %}
                <label class="flex items-center gap-3 p-3 bg-dark-700/50 rounded-xl hover:bg-dark-700 cursor-pointer transition-colors">
                    <input type="checkbox" name="roles" value="{{ role.id }}" class="w-4 h-4 rounded bg-dark-600 border-dark-500 text-{{ primary_color }}-500">
                    <div>
                        <p class="text-sm font-medium">{{ role.name }}</p>
                        <p class="text-xs text-gray-500">{{ role.description }}</p>
                    </div>
                </label>
                {% endfor %}
            </div>
        </div>
        
        <label class="flex items-center gap-3 p-3 bg-red-500/10 rounded-xl border border-red-500/20">
            <input type="checkbox" name="is_superadmin" class="w-4 h-4 rounded bg-dark-600 border-dark-500 text-red-500">
            <div>
                <p class="text-sm font-medium text-red-400">Super Admin</p>
                <p class="text-xs text-gray-500">Bypass all permission checks</p>
            </div>
        </label>
    </div>
    
    <div class="mt-6 flex gap-3">
        <button type="submit" class="px-6 py-2.5 bg-gradient-to-r from-{{ primary_color }}-500 to-{{ primary_color }}-600 hover:from-{{ primary_color }}-400 hover:to-{{ primary_color }}-500 text-white font-medium rounded-xl shadow-lg shadow-{{ primary_color }}-500/25 transition-all">
            Create User
        </button>
        <a href="{{ url_for('lic_admin.admin_users') }}" class="px-6 py-2.5 bg-dark-700 hover:bg-dark-600 rounded-xl font-medium transition-colors">Cancel</a>
    </div>
</form>
{% endblock %}
OPSLAB_LIC_EOF__7f2d8a5e

say "Writing app/licenses/templates/admin/customers.html"
write_file 'app/licenses/templates/admin/customers.html' << 'OPSLAB_LIC_EOF__7f2d8a5e'
{% extends "licenses/base.html" %}
{% block title %}Customers - License Manager{% endblock %}

{% block content %}
<div class="flex items-center justify-between mb-6">
    <div>
        <h1 class="text-2xl font-bold">Customers</h1>
        <p class="text-gray-500">Manage customer accounts</p>
    </div>
    <a href="{{ url_for('lic_admin.create_customer') }}" class="px-4 py-2 bg-emerald-600 hover:bg-emerald-700 text-white rounded-lg transition-colors">
        + Add Customer
    </a>
</div>

<!-- Search -->
<div class="bg-dark-800 border border-dark-600 rounded-xl p-4 mb-6">
    <form class="flex gap-4">
        <input type="text" name="search" value="{{ search }}" placeholder="Search by email, company, or name..."
            class="flex-1 px-4 py-2 bg-dark-700 border border-dark-500 rounded-lg text-sm focus:outline-none focus:border-emerald-500">
        <button type="submit" class="px-4 py-2 bg-dark-700 hover:bg-dark-600 rounded-lg transition-colors">
            Search
        </button>
    </form>
</div>

<!-- Customers Table -->
<div class="bg-dark-800 border border-dark-600 rounded-xl overflow-hidden">
    <table class="w-full">
        <thead class="bg-dark-700">
            <tr>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-400 uppercase">Company</th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-400 uppercase">Email</th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-400 uppercase">Contact</th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-400 uppercase">Licenses</th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-400 uppercase">Status</th>
                <th class="px-4 py-3 text-right text-xs font-medium text-gray-400 uppercase">Actions</th>
            </tr>
        </thead>
        <tbody class="divide-y divide-dark-600">
            {% for customer in customers.items %}
            <tr class="hover:bg-dark-700">
                <td class="px-4 py-3">
                    <a href="{{ url_for('lic_admin.view_customer', id=customer.id) }}" class="text-emerald-400 hover:text-emerald-300">
                        {{ customer.company_name or '—' }}
                    </a>
                </td>
                <td class="px-4 py-3 text-sm">{{ customer.email }}</td>
                <td class="px-4 py-3 text-sm">{{ customer.contact_name or '—' }}</td>
                <td class="px-4 py-3 text-sm">{{ customer.licenses.count() }}</td>
                <td class="px-4 py-3">
                    <span class="px-2 py-1 text-xs rounded-full {% if customer.is_active %}bg-green-500/20 text-green-400{% else %}bg-gray-500/20 text-gray-400{% endif %}">
                        {{ 'Active' if customer.is_active else 'Inactive' }}
                    </span>
                </td>
                <td class="px-4 py-3 text-right">
                    <a href="{{ url_for('lic_admin.view_customer', id=customer.id) }}" class="text-gray-400 hover:text-white">View</a>
                </td>
            </tr>
            {% else %}
            <tr>
                <td colspan="6" class="px-4 py-8 text-center text-gray-500">No customers found</td>
            </tr>
            {% endfor %}
        </tbody>
    </table>
</div>

{% if customers.pages > 1 %}
<div class="flex justify-center mt-6 gap-2">
    {% for page in customers.iter_pages() %}
        {% if page %}
        <a href="{{ url_for('lic_admin.customers', page=page, search=search) }}"
           class="px-3 py-1 rounded {% if page == customers.page %}bg-emerald-600 text-white{% else %}bg-dark-700 text-gray-400{% endif %}">
            {{ page }}
        </a>
        {% endif %}
    {% endfor %}
</div>
{% endif %}
{% endblock %}
OPSLAB_LIC_EOF__7f2d8a5e

say "Writing app/licenses/templates/admin/dashboard.html"
write_file 'app/licenses/templates/admin/dashboard.html' << 'OPSLAB_LIC_EOF__7f2d8a5e'
{% extends "licenses/base.html" %}
{% block title %}Dashboard - License Manager{% endblock %}

{% block content %}
<div class="mb-6">
    <h1 class="text-2xl font-bold">Dashboard</h1>
    <p class="text-gray-500">License management overview</p>
</div>

<!-- Stats -->
<div class="grid grid-cols-1 md:grid-cols-4 gap-4 mb-8">
    <div class="bg-dark-800 border border-dark-600 rounded-xl p-5">
        <div class="flex items-center justify-between">
            <div>
                <p class="text-gray-500 text-sm">Total Licenses</p>
                <p class="text-2xl font-bold mt-1">{{ total_licenses }}</p>
            </div>
            <div class="w-12 h-12 bg-blue-500/20 rounded-lg flex items-center justify-center">
                <svg class="w-6 h-6 text-blue-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 7a2 2 0 012 2m4 0a6 6 0 01-7.743 5.743L11 17H9v2H7v2H4a1 1 0 01-1-1v-2.586a1 1 0 01.293-.707l5.964-5.964A6 6 0 1121 9z"/>
                </svg>
            </div>
        </div>
    </div>
    
    <div class="bg-dark-800 border border-dark-600 rounded-xl p-5">
        <div class="flex items-center justify-between">
            <div>
                <p class="text-gray-500 text-sm">Active Licenses</p>
                <p class="text-2xl font-bold mt-1 text-green-400">{{ active_licenses }}</p>
            </div>
            <div class="w-12 h-12 bg-green-500/20 rounded-lg flex items-center justify-center">
                <svg class="w-6 h-6 text-green-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"/>
                </svg>
            </div>
        </div>
    </div>
    
    <div class="bg-dark-800 border border-dark-600 rounded-xl p-5">
        <div class="flex items-center justify-between">
            <div>
                <p class="text-gray-500 text-sm">Customers</p>
                <p class="text-2xl font-bold mt-1">{{ total_customers }}</p>
            </div>
            <div class="w-12 h-12 bg-purple-500/20 rounded-lg flex items-center justify-center">
                <svg class="w-6 h-6 text-purple-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M17 20h5v-2a3 3 0 00-5.356-1.857M17 20H7m10 0v-2c0-.656-.126-1.283-.356-1.857M7 20H2v-2a3 3 0 015.356-1.857M7 20v-2c0-.656.126-1.283.356-1.857m0 0a5.002 5.002 0 019.288 0M15 7a3 3 0 11-6 0 3 3 0 016 0z"/>
                </svg>
            </div>
        </div>
    </div>
    
    <div class="bg-dark-800 border border-dark-600 rounded-xl p-5">
        <div class="flex items-center justify-between">
            <div>
                <p class="text-gray-500 text-sm">Expiring Soon</p>
                <p class="text-2xl font-bold mt-1 text-yellow-400">{{ expiring_soon }}</p>
            </div>
            <div class="w-12 h-12 bg-yellow-500/20 rounded-lg flex items-center justify-center">
                <svg class="w-6 h-6 text-yellow-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z"/>
                </svg>
            </div>
        </div>
    </div>
</div>

<div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
    <!-- Recent Licenses -->
    <div class="bg-dark-800 border border-dark-600 rounded-xl">
        <div class="p-4 border-b border-dark-600 flex items-center justify-between">
            <h2 class="font-semibold">Recent Licenses</h2>
            <a href="{{ url_for('lic_admin.create_license') }}" class="text-sm text-emerald-400 hover:text-emerald-300">+ Create New</a>
        </div>
        <div class="divide-y divide-dark-600">
            {% for license in recent_licenses %}
            <a href="{{ url_for('lic_admin.view_license', id=license.id) }}" class="flex items-center justify-between p-4 hover:bg-dark-700">
                <div>
                    <p class="font-mono text-sm">{{ license.license_key }}</p>
                    <p class="text-xs text-gray-500 mt-1">{{ license.tier.name }} • {{ license.created_at.strftime('%d %b %Y') }}</p>
                </div>
                <span class="px-2 py-1 text-xs rounded-full {% if license.status == 'active' %}bg-green-500/20 text-green-400{% elif license.status == 'suspended' %}bg-yellow-500/20 text-yellow-400{% else %}bg-red-500/20 text-red-400{% endif %}">
                    {{ license.status }}
                </span>
            </a>
            {% else %}
            <p class="p-4 text-gray-500 text-sm">No licenses yet</p>
            {% endfor %}
        </div>
    </div>
    
    <!-- Recent Activations -->
    <div class="bg-dark-800 border border-dark-600 rounded-xl">
        <div class="p-4 border-b border-dark-600">
            <h2 class="font-semibold">Recent Activations</h2>
        </div>
        <div class="divide-y divide-dark-600">
            {% for activation in recent_activations %}
            <div class="p-4">
                <div class="flex items-center justify-between">
                    <p class="font-mono text-sm">{{ activation.license.license_key[:14] }}...</p>
                    <span class="text-xs text-gray-500">{{ activation.activated_at.strftime('%d %b %H:%M') }}</span>
                </div>
                <p class="text-xs text-gray-500 mt-1">
                    {% if activation.domain %}{{ activation.domain }}{% else %}{{ activation.ip_address }}{% endif %}
                </p>
            </div>
            {% else %}
            <p class="p-4 text-gray-500 text-sm">No activations yet</p>
            {% endfor %}
        </div>
    </div>
</div>

<!-- Quick Actions -->
<div class="mt-6 flex gap-4">
    <a href="{{ url_for('lic_admin.create_license') }}" class="px-4 py-2 bg-emerald-600 hover:bg-emerald-700 text-white rounded-lg transition-colors">
        Create License
    </a>
    <a href="{{ url_for('lic_admin.bulk_create_licenses') }}" class="px-4 py-2 bg-dark-700 hover:bg-dark-600 text-white rounded-lg border border-dark-500 transition-colors">
        Bulk Create
    </a>
    <a href="{{ url_for('lic_admin.create_customer') }}" class="px-4 py-2 bg-dark-700 hover:bg-dark-600 text-white rounded-lg border border-dark-500 transition-colors">
        Add Customer
    </a>
</div>
{% endblock %}
OPSLAB_LIC_EOF__7f2d8a5e

say "Writing app/licenses/templates/admin/edit_customer.html"
write_file 'app/licenses/templates/admin/edit_customer.html' << 'OPSLAB_LIC_EOF__7f2d8a5e'
{% extends "licenses/base.html" %}
{% block title %}Edit Customer - License Manager{% endblock %}

{% block content %}
<div class="mb-6">
    <a href="{{ url_for('lic_admin.view_customer', id=customer.id) }}" class="text-gray-500 hover:text-gray-300 text-sm mb-2 inline-block">← Back</a>
    <h1 class="text-2xl font-bold">Edit Customer</h1>
</div>

<form method="POST" class="max-w-xl space-y-6">
    <div class="bg-dark-800 border border-dark-600 rounded-xl p-6 space-y-4">
        <div>
            <label class="block text-sm font-medium text-gray-300 mb-2">Email</label>
            <input type="email" value="{{ customer.email }}" disabled
                class="w-full px-4 py-2.5 bg-dark-900 border border-dark-600 rounded-lg text-gray-500">
        </div>
        
        <div>
            <label class="block text-sm font-medium text-gray-300 mb-2">Company Name</label>
            <input type="text" name="company_name" value="{{ customer.company_name or '' }}"
                class="w-full px-4 py-2.5 bg-dark-700 border border-dark-500 rounded-lg focus:outline-none focus:border-emerald-500">
        </div>
        
        <div>
            <label class="block text-sm font-medium text-gray-300 mb-2">Contact Name</label>
            <input type="text" name="contact_name" value="{{ customer.contact_name or '' }}"
                class="w-full px-4 py-2.5 bg-dark-700 border border-dark-500 rounded-lg focus:outline-none focus:border-emerald-500">
        </div>
        
        <div>
            <label class="block text-sm font-medium text-gray-300 mb-2">Phone</label>
            <input type="text" name="phone" value="{{ customer.phone or '' }}"
                class="w-full px-4 py-2.5 bg-dark-700 border border-dark-500 rounded-lg focus:outline-none focus:border-emerald-500">
        </div>
        
        <div>
            <label class="block text-sm font-medium text-gray-300 mb-2">Address</label>
            <textarea name="address" rows="2"
                class="w-full px-4 py-2.5 bg-dark-700 border border-dark-500 rounded-lg focus:outline-none focus:border-emerald-500">{{ customer.address or '' }}</textarea>
        </div>
        
        <div>
            <label class="block text-sm font-medium text-gray-300 mb-2">Notes</label>
            <textarea name="notes" rows="2"
                class="w-full px-4 py-2.5 bg-dark-700 border border-dark-500 rounded-lg focus:outline-none focus:border-emerald-500">{{ customer.notes or '' }}</textarea>
        </div>
        
        <div>
            <label class="flex items-center gap-2">
                <input type="checkbox" name="is_active" {% if customer.is_active %}checked{% endif %}
                    class="w-4 h-4 bg-dark-700 border-dark-500 rounded text-emerald-500">
                <span>Active</span>
            </label>
        </div>
    </div>
    
    <div class="flex gap-4">
        <button type="submit" class="px-6 py-2.5 bg-emerald-600 hover:bg-emerald-700 text-white font-medium rounded-lg">
            Save Changes
        </button>
        <a href="{{ url_for('lic_admin.view_customer', id=customer.id) }}" class="px-6 py-2.5 bg-dark-700 hover:bg-dark-600 rounded-lg border border-dark-500">
            Cancel
        </a>
    </div>
</form>
{% endblock %}
OPSLAB_LIC_EOF__7f2d8a5e

say "Writing app/licenses/templates/admin/edit_feature.html"
write_file 'app/licenses/templates/admin/edit_feature.html' << 'OPSLAB_LIC_EOF__7f2d8a5e'
{% extends "licenses/base.html" %}
{% block title %}Edit Feature — {{ site_name }}{% endblock %}

{% block content %}
<div class="p-6 max-w-2xl">

  <!-- Header -->
  <div class="flex items-center gap-3 mb-6">
    <a href="{{ url_for('lic_admin.features') }}"
       class="p-2 text-gray-400 hover:text-white hover:bg-dark-700 rounded-lg transition-colors">
      <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 19l-7-7 7-7"/>
      </svg>
    </a>
    <div>
      <h1 class="text-2xl font-bold text-white">Edit Feature</h1>
      <p class="text-sm text-gray-500">
        <code class="text-emerald-400 font-mono text-xs">{{ feature.code }}</code>
      </p>
    </div>
  </div>

  <form method="POST" class="bg-dark-800 border border-dark-700/50 rounded-2xl p-6 space-y-5">
    <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">

    <!-- Name -->
    <div>
      <label class="block text-sm font-medium text-gray-300 mb-1.5">Feature Name</label>
      <input type="text" name="name" value="{{ feature.name }}" required
             class="w-full bg-dark-700 border border-dark-600 rounded-xl px-4 py-2.5 text-white focus:border-emerald-500/50 focus:ring-1 focus:ring-emerald-500/30 outline-none transition text-sm">
    </div>

    <!-- Code (read-only) -->
    <div>
      <label class="block text-sm font-medium text-gray-300 mb-1.5">Feature Code</label>
      <input type="text" value="{{ feature.code }}" disabled
             class="w-full bg-dark-900 border border-dark-700 rounded-xl px-4 py-2.5 text-gray-500 text-sm font-mono cursor-not-allowed">
      <p class="text-xs text-gray-600 mt-1">Code cannot be changed after creation — it may be referenced by external systems.</p>
    </div>

    <!-- Category -->
    <div>
      <label class="block text-sm font-medium text-gray-300 mb-1.5">Category</label>
      <input type="text" name="category" value="{{ feature.category }}"
             class="w-full bg-dark-700 border border-dark-600 rounded-xl px-4 py-2.5 text-white focus:border-emerald-500/50 focus:ring-1 focus:ring-emerald-500/30 outline-none transition text-sm">
    </div>

    <!-- Description -->
    <div>
      <label class="block text-sm font-medium text-gray-300 mb-1.5">Description</label>
      <textarea name="description" rows="3"
                class="w-full bg-dark-700 border border-dark-600 rounded-xl px-4 py-2.5 text-white focus:border-emerald-500/50 focus:ring-1 focus:ring-emerald-500/30 outline-none transition text-sm resize-none">{{ feature.description or '' }}</textarea>
    </div>

    <!-- Icon -->
    <div>
      <label class="block text-sm font-medium text-gray-300 mb-1.5">Icon</label>
      <input type="text" name="icon" value="{{ feature.icon or 'puzzle' }}"
             class="w-full bg-dark-700 border border-dark-600 rounded-xl px-4 py-2.5 text-white focus:border-emerald-500/50 focus:ring-1 focus:ring-emerald-500/30 outline-none transition text-sm font-mono">
    </div>

    <!-- Active toggle -->
    <div class="flex items-center gap-3 py-1">
      <input type="checkbox" name="is_active" id="isActive" {{ 'checked' if feature.is_active else '' }}
             class="w-4 h-4 accent-emerald-500">
      <label for="isActive" class="text-sm text-gray-300">Feature is active (returned by API)</label>
    </div>

    <!-- Actions -->
    <div class="flex items-center gap-3 pt-2">
      <button type="submit"
              class="px-5 py-2.5 bg-emerald-500 hover:bg-emerald-400 text-white rounded-xl font-semibold text-sm transition-colors shadow-lg shadow-emerald-500/20">
        Save Changes
      </button>
      <a href="{{ url_for('lic_admin.features') }}"
         class="px-5 py-2.5 bg-dark-700 hover:bg-dark-600 text-gray-300 rounded-xl font-semibold text-sm transition-colors">
        Cancel
      </a>
    </div>
  </form>
</div>
{% endblock %}
OPSLAB_LIC_EOF__7f2d8a5e

say "Writing app/licenses/templates/admin/edit_license.html"
write_file 'app/licenses/templates/admin/edit_license.html' << 'OPSLAB_LIC_EOF__7f2d8a5e'
{% extends "licenses/base.html" %}
{% block title %}Edit License — {{ site_name }}{% endblock %}

{% block content %}
<div class="p-6 max-w-2xl">

  <!-- Header -->
  <div class="flex items-center gap-3 mb-6">
    <a href="{{ url_for('lic_admin.view_license', id=license.id) }}"
       class="p-2 text-gray-400 hover:text-white hover:bg-dark-700 rounded-lg transition-colors">
      <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 19l-7-7 7-7"/>
      </svg>
    </a>
    <div>
      <h1 class="text-2xl font-bold text-white">Edit License</h1>
      <p class="text-sm font-mono text-gray-500">{{ license.license_key }}</p>
    </div>
  </div>

  <form method="POST" class="space-y-5">
    <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">

    <!-- Core fields -->
    <div class="bg-dark-800 border border-dark-700/50 rounded-2xl p-6 space-y-5">
      <h2 class="text-sm font-semibold text-gray-400 uppercase tracking-wider">License Details</h2>

      <div>
        <label class="block text-sm font-medium text-gray-300 mb-1.5">Tier</label>
        <select name="tier_id" class="w-full px-4 py-2.5 bg-dark-700 border border-dark-600 rounded-xl text-white focus:outline-none focus:border-emerald-500/50 text-sm">
          {% for tier in tiers %}
          <option value="{{ tier.id }}" {% if tier.id == license.tier_id %}selected{% endif %}>
            {{ tier.name }} — {{ tier.product.name }}
          </option>
          {% endfor %}
        </select>
      </div>

      <div>
        <label class="block text-sm font-medium text-gray-300 mb-1.5">Customer</label>
        <select name="customer_id" class="w-full px-4 py-2.5 bg-dark-700 border border-dark-600 rounded-xl text-white focus:outline-none focus:border-emerald-500/50 text-sm">
          <option value="">— No customer —</option>
          {% for customer in customers %}
          <option value="{{ customer.id }}" {% if license.customer_id == customer.id %}selected{% endif %}>
            {{ customer.company_name or customer.email }}
          </option>
          {% endfor %}
        </select>
      </div>

      <div>
        <label class="block text-sm font-medium text-gray-300 mb-1.5">Expiration Date</label>
        <input type="date" name="expires_at" value="{{ license.expires_at.strftime('%Y-%m-%d') if license.expires_at else '' }}"
               class="w-full px-4 py-2.5 bg-dark-700 border border-dark-600 rounded-xl text-white focus:outline-none focus:border-emerald-500/50 text-sm">
        <p class="text-xs text-gray-600 mt-1">Leave empty for lifetime licence</p>
      </div>

      <div>
        <label class="block text-sm font-medium text-gray-300 mb-1.5">Max Activations</label>
        <input type="number" name="max_activations" value="{{ license.max_activations }}" min="1"
               class="w-full px-4 py-2.5 bg-dark-700 border border-dark-600 rounded-xl text-white focus:outline-none focus:border-emerald-500/50 text-sm">
      </div>

      <div>
        <label class="block text-sm font-medium text-gray-300 mb-1.5">Domain Lock</label>
        <input type="text" name="domain" value="{{ license.domain or '' }}" placeholder="example.com"
               class="w-full px-4 py-2.5 bg-dark-700 border border-dark-600 rounded-xl text-white placeholder-gray-600 focus:outline-none focus:border-emerald-500/50 text-sm">
      </div>

      <div>
        <label class="block text-sm font-medium text-gray-300 mb-1.5">Notes</label>
        <textarea name="notes" rows="3" class="w-full px-4 py-2.5 bg-dark-700 border border-dark-600 rounded-xl text-white focus:outline-none focus:border-emerald-500/50 text-sm resize-none">{{ license.notes or '' }}</textarea>
      </div>
    </div>

    <!-- Feature Assignment -->
    <div class="bg-dark-800 border border-dark-700/50 rounded-2xl p-6 space-y-4">
      <div class="flex items-center justify-between">
        <div>
          <h2 class="text-sm font-semibold text-gray-400 uppercase tracking-wider">Licence Features</h2>
          <p class="text-xs text-gray-600 mt-0.5">These features are returned by the API for this specific licence</p>
        </div>
        <div class="flex gap-2">
          <button type="button" onclick="selectAll(true)" class="text-xs text-emerald-400 hover:text-emerald-300 px-2 py-1 hover:bg-emerald-500/10 rounded-lg transition-colors">Select all</button>
          <button type="button" onclick="selectAll(false)" class="text-xs text-gray-500 hover:text-gray-300 px-2 py-1 hover:bg-dark-600 rounded-lg transition-colors">Clear</button>
        </div>
      </div>

      {% if grouped_features %}
        {% for product_group, categories in grouped_features.items() %}
        <!-- Product group -->
        <div class="border border-dark-700/50 rounded-xl overflow-hidden">
          <div class="px-4 py-2.5 bg-dark-700/40 border-b border-dark-700/30 flex items-center justify-between">
            <div class="flex items-center gap-2">
              <div class="w-5 h-5 rounded bg-emerald-500/10 flex items-center justify-center">
                <svg class="w-3 h-3 text-emerald-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M20 7l-8-4-8 4m16 0l-8 4m8-4v10l-8 4m0-10L4 7m8 4v10M4 7v10l8 4"/>
                </svg>
              </div>
              <span class="text-xs font-bold text-gray-300">{{ product_group }}</span>
            </div>
            <div class="flex gap-1.5">
              <button type="button" onclick="selectGroup('{{ product_group|replace(' ','-') }}', true)"
                      class="text-xs text-emerald-400 hover:text-emerald-300 px-1.5 py-0.5 hover:bg-emerald-500/10 rounded transition-colors">All</button>
              <button type="button" onclick="selectGroup('{{ product_group|replace(' ','-') }}', false)"
                      class="text-xs text-gray-600 hover:text-gray-400 px-1.5 py-0.5 hover:bg-dark-600 rounded transition-colors">None</button>
            </div>
          </div>
          <div class="p-3 space-y-3">
            {% for category, cat_features in categories.items() %}
            <div class="space-y-1">
              <p class="text-xs font-semibold text-gray-600 uppercase tracking-wider px-1">{{ category }}</p>
              {% for feature in cat_features %}
              <label class="flex items-center gap-3 px-3 py-2 rounded-xl border cursor-pointer transition-all feature-label
                            {{ 'bg-emerald-500/10 border-emerald-500/30 text-white' if feature.id in license_feature_ids else 'bg-dark-700/40 border-dark-600/50 text-gray-400 hover:border-dark-500' }}"
                     id="label-{{ feature.id }}">
                <input type="checkbox" name="feature_ids" value="{{ feature.id }}"
                       class="hidden feature-cb" id="cb-{{ feature.id }}"
                       data-pg="{{ product_group|replace(' ','-') }}"
                       {% if feature.id in license_feature_ids %}checked{% endif %}
                       onchange="styleLabel(this)">
                <div class="w-4 h-4 rounded border flex items-center justify-center flex-shrink-0 transition-all
                            {{ 'bg-emerald-500 border-emerald-500' if feature.id in license_feature_ids else 'bg-transparent border-dark-500' }}"
                     id="box-{{ feature.id }}">
                  {% if feature.id in license_feature_ids %}
                  <svg class="w-3 h-3 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="3" d="M5 13l4 4L19 7"/>
                  </svg>
                  {% endif %}
                </div>
                <div class="flex-1 min-w-0">
                  <p class="text-sm font-medium leading-none">{{ feature.name }}</p>
                  {% if feature.description %}<p class="text-xs text-gray-600 mt-0.5 truncate">{{ feature.description }}</p>{% endif %}
                </div>
                <code class="text-xs font-mono text-gray-600 flex-shrink-0">{{ feature.code }}</code>
              </label>
              {% endfor %}
            </div>
            {% endfor %}
          </div>
        </div>
        {% endfor %}
      {% else %}
        <div class="text-center py-6 text-gray-600 text-sm">
          No features defined yet. <a href="{{ url_for('lic_admin.create_feature') }}" class="text-emerald-400 hover:text-emerald-300">Create a feature →</a>
        </div>
      {% endif %}
    </div>

    <!-- Actions -->
    <div class="flex items-center gap-3">
      <button type="submit" class="px-5 py-2.5 bg-emerald-500 hover:bg-emerald-400 text-white rounded-xl font-semibold text-sm transition-colors shadow-lg shadow-emerald-500/20">
        Save Changes
      </button>
      <a href="{{ url_for('lic_admin.view_license', id=license.id) }}" class="px-5 py-2.5 bg-dark-700 hover:bg-dark-600 text-gray-300 rounded-xl font-semibold text-sm transition-colors">
        Cancel
      </a>
    </div>
  </form>
</div>

<script>
const CHECK_SVG = '<svg class="w-3 h-3 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="3" d="M5 13l4 4L19 7"/></svg>';
function styleLabel(cb) {
  const id    = cb.value;
  const label = document.getElementById('label-' + id);
  const box   = document.getElementById('box-' + id);
  const on    = cb.checked;
  label.classList.toggle('bg-emerald-500/10',   on);
  label.classList.toggle('border-emerald-500/30', on);
  label.classList.toggle('text-white',           on);
  label.classList.toggle('bg-dark-700/40',       !on);
  label.classList.toggle('border-dark-600/50',   !on);
  label.classList.toggle('text-gray-400',        !on);
  box.classList.toggle('bg-emerald-500',   on);
  box.classList.toggle('border-emerald-500', on);
  box.classList.toggle('bg-transparent',   !on);
  box.classList.toggle('border-dark-500',  !on);
  box.innerHTML = on ? CHECK_SVG : '';
}
function selectAll(state) {
  document.querySelectorAll('.feature-cb').forEach(cb => { cb.checked = state; styleLabel(cb); });
}
function selectGroup(pg, state) {
  document.querySelectorAll(`.feature-cb[data-pg="${pg}"]`).forEach(cb => { cb.checked = state; styleLabel(cb); });
}
</script>
{% endblock %}
OPSLAB_LIC_EOF__7f2d8a5e

say "Writing app/licenses/templates/admin/edit_product.html"
write_file 'app/licenses/templates/admin/edit_product.html' << 'OPSLAB_LIC_EOF__7f2d8a5e'
{% extends "licenses/base.html" %}
{% block title %}Edit {{ product.name }} - License Manager{% endblock %}

{% block content %}
<div class="mb-6">
    <a href="{{ url_for('lic_admin.products') }}" class="text-gray-500 hover:text-gray-300 text-sm mb-2 inline-block">← Back to Products</a>
    <h1 class="text-2xl font-bold">Edit Product</h1>
    <p class="text-gray-500">{{ product.code }}</p>
</div>

<form method="POST" class="max-w-xl space-y-6">
    <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
    
    <div class="bg-dark-800 border border-dark-600 rounded-xl p-6 space-y-4">
        <div>
            <label class="block text-sm font-medium text-gray-300 mb-2">Product Name *</label>
            <input type="text" name="name" value="{{ product.name }}" required
                class="w-full px-4 py-2.5 bg-dark-700 border border-dark-500 rounded-lg focus:outline-none focus:border-emerald-500">
        </div>
        
        <div>
            <label class="block text-sm font-medium text-gray-300 mb-2">Product Code</label>
            <input type="text" value="{{ product.code }}" disabled
                class="w-full px-4 py-2.5 bg-dark-900 border border-dark-600 rounded-lg text-gray-500">
            <p class="text-xs text-gray-500 mt-1">Cannot be changed</p>
        </div>
        
        <div>
            <label class="block text-sm font-medium text-gray-300 mb-2">Description</label>
            <textarea name="description" rows="3"
                class="w-full px-4 py-2.5 bg-dark-700 border border-dark-500 rounded-lg focus:outline-none focus:border-emerald-500">{{ product.description or '' }}</textarea>
        </div>
        
        <div>
            <label class="flex items-center gap-2">
                <input type="checkbox" name="is_active" {% if product.is_active %}checked{% endif %}
                    class="w-4 h-4 bg-dark-700 border-dark-500 rounded text-emerald-500">
                <span>Active</span>
            </label>
        </div>
    </div>
    
    <div class="bg-dark-800 border border-dark-600 rounded-xl p-6 space-y-4">
        <h2 class="font-semibold">IP Lock Settings</h2>
        
        <div>
            <label class="flex items-center gap-2">
                <input type="checkbox" name="require_ip_lock" {% if product.require_ip_lock %}checked{% endif %}
                    class="w-4 h-4 bg-dark-700 border-dark-500 rounded text-emerald-500">
                <span>Require IP Lock</span>
            </label>
        </div>
        
        <div>
            <label class="block text-sm font-medium text-gray-300 mb-2">Max IP Addresses</label>
            <input type="number" name="max_ip_addresses" value="{{ product.max_ip_addresses }}" min="1" max="100"
                class="w-full px-4 py-2.5 bg-dark-700 border border-dark-500 rounded-lg focus:outline-none focus:border-emerald-500">
        </div>
        
        <div>
            <label class="flex items-center gap-2">
                <input type="checkbox" name="allow_ip_change" {% if product.allow_ip_change %}checked{% endif %}
                    class="w-4 h-4 bg-dark-700 border-dark-500 rounded text-emerald-500">
                <span>Allow IP Changes</span>
            </label>
        </div>
        
        <div>
            <label class="block text-sm font-medium text-gray-300 mb-2">IP Change Cooldown (hours)</label>
            <input type="number" name="ip_change_cooldown" value="{{ product.ip_change_cooldown }}" min="0"
                class="w-full px-4 py-2.5 bg-dark-700 border border-dark-500 rounded-lg focus:outline-none focus:border-emerald-500">
        </div>
    </div>
    
    <div class="flex gap-4">
        <button type="submit" class="px-6 py-2.5 bg-emerald-600 hover:bg-emerald-700 text-white font-medium rounded-lg">
            Save Changes
        </button>
        <a href="{{ url_for('lic_admin.products') }}" class="px-6 py-2.5 bg-dark-700 hover:bg-dark-600 rounded-lg border border-dark-500">
            Cancel
        </a>
    </div>
</form>
{% endblock %}
OPSLAB_LIC_EOF__7f2d8a5e

say "Writing app/licenses/templates/admin/edit_tiers.html"
write_file 'app/licenses/templates/admin/edit_tiers.html' << 'OPSLAB_LIC_EOF__7f2d8a5e'
{% extends "licenses/base.html" %}
{% block title %}Edit Tiers - {{ product.name }} - License Manager{% endblock %}

{% block content %}
<div class="flex items-center justify-between mb-6">
    <div>
        <a href="{{ url_for('lic_admin.products') }}" class="text-gray-500 hover:text-gray-300 text-sm mb-2 inline-block">← Back to Products</a>
        <h1 class="text-2xl font-bold">Edit Tiers - {{ product.name }}</h1>
    </div>
    <a href="{{ url_for('lic_admin.create_tier', product_id=product.id) }}" class="px-4 py-2 bg-emerald-600 hover:bg-emerald-700 text-white rounded-lg">
        + Add Tier
    </a>
</div>

<div class="space-y-6">
    {% for tier in product.tiers %}
    <div class="bg-dark-800 border border-dark-600 rounded-xl p-6">
        <div class="flex items-center justify-between mb-4">
            <h2 class="font-semibold">{{ tier.name }}</h2>
            <div class="flex items-center gap-4">
                <span class="text-sm text-gray-500">{{ tier.code }} • {{ tier.licenses.count() }} licenses</span>
                <form method="POST" action="{{ url_for('lic_admin.delete_tier', id=tier.id) }}" class="inline"
                      onsubmit="return confirm('Delete this tier?');">
                    <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
                    <button type="submit" class="text-red-400 hover:text-red-300 text-sm">Delete</button>
                </form>
            </div>
        </div>
        
        <form method="POST">
            <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
            <input type="hidden" name="tier_id" value="{{ tier.id }}">
            
            <div class="grid grid-cols-1 md:grid-cols-4 gap-4 mb-4">
                <div>
                    <label class="block text-sm text-gray-400 mb-1">Name</label>
                    <input type="text" name="name" value="{{ tier.name }}"
                        class="w-full px-3 py-2 bg-dark-700 border border-dark-500 rounded-lg text-sm">
                </div>
                <div>
                    <label class="block text-sm text-gray-400 mb-1">Monthly Price ($)</label>
                    <input type="number" name="price_monthly" value="{{ tier.price_monthly }}" step="0.01"
                        class="w-full px-3 py-2 bg-dark-700 border border-dark-500 rounded-lg text-sm">
                </div>
                <div>
                    <label class="block text-sm text-gray-400 mb-1">Yearly Price ($)</label>
                    <input type="number" name="price_yearly" value="{{ tier.price_yearly }}" step="0.01"
                        class="w-full px-3 py-2 bg-dark-700 border border-dark-500 rounded-lg text-sm">
                </div>
                <div>
                    <label class="block text-sm text-gray-400 mb-1">Max Users (0=unlimited)</label>
                    <input type="number" name="max_users" value="{{ tier.max_users }}"
                        class="w-full px-3 py-2 bg-dark-700 border border-dark-500 rounded-lg text-sm">
                </div>
            </div>
            
            <div class="mb-4">
                <label class="block text-sm text-gray-400 mb-2">Features</label>
                <div class="flex flex-wrap gap-4">
                    {% for feature in ['schedule', 'leave', 'tasks', 'board', 'finance', 'reports', 'api_access', 'white_label'] %}
                    <label class="flex items-center gap-2">
                        <input type="checkbox" name="{{ feature }}" {% if tier.features and tier.features.get(feature) %}checked{% endif %}
                            class="w-4 h-4 bg-dark-700 border-dark-500 rounded text-emerald-500">
                        <span class="text-sm capitalize">{{ feature.replace('_', ' ') }}</span>
                    </label>
                    {% endfor %}
                </div>
            </div>
            
            <button type="submit" class="px-4 py-2 bg-emerald-600 hover:bg-emerald-700 text-white text-sm rounded-lg">
                Save Changes
            </button>
        </form>
    </div>
    {% else %}
    <div class="bg-dark-800 border border-dark-600 rounded-xl p-12 text-center">
        <p class="text-gray-500 mb-4">No tiers for this product</p>
        <a href="{{ url_for('lic_admin.create_tier', product_id=product.id) }}" class="px-4 py-2 bg-emerald-600 hover:bg-emerald-700 text-white rounded-lg">
            Create First Tier
        </a>
    </div>
    {% endfor %}
</div>
{% endblock %}
OPSLAB_LIC_EOF__7f2d8a5e

say "Writing app/licenses/templates/admin/edit_user.html"
write_file 'app/licenses/templates/admin/edit_user.html' << 'OPSLAB_LIC_EOF__7f2d8a5e'
{% extends "licenses/base.html" %}
{% block title %}Edit User - {{ site_name }}{% endblock %}

{% block content %}
<div class="mb-8">
    <a href="{{ url_for('lic_admin.admin_users') }}" class="text-gray-500 hover:text-gray-300 text-sm mb-2 inline-flex items-center gap-1">
        <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 19l-7-7 7-7"/></svg>
        Back to Users
    </a>
    <h1 class="text-3xl font-bold bg-gradient-to-r from-white to-gray-400 bg-clip-text text-transparent">Edit User: {{ user.name }}</h1>
</div>

<form method="POST" class="max-w-2xl">
    <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
    
    <div class="bg-dark-800/50 backdrop-blur border border-dark-700/50 rounded-2xl p-6 space-y-5">
        <div class="grid md:grid-cols-2 gap-5">
            <div>
                <label class="block text-sm font-medium text-gray-300 mb-2">Name</label>
                <input type="text" name="name" value="{{ user.name }}" required
                    class="w-full px-4 py-2.5 bg-dark-700 border border-dark-600 rounded-xl focus:outline-none focus:border-{{ primary_color }}-500">
            </div>
            <div>
                <label class="block text-sm font-medium text-gray-300 mb-2">Email</label>
                <input type="email" value="{{ user.email }}" disabled
                    class="w-full px-4 py-2.5 bg-dark-800 border border-dark-700 rounded-xl text-gray-500">
            </div>
        </div>
        
        <div>
            <label class="block text-sm font-medium text-gray-300 mb-2">New Password <span class="text-gray-500">(leave empty to keep current)</span></label>
            <input type="password" name="password" minlength="6"
                class="w-full px-4 py-2.5 bg-dark-700 border border-dark-600 rounded-xl focus:outline-none focus:border-{{ primary_color }}-500">
        </div>
        
        <div>
            <label class="block text-sm font-medium text-gray-300 mb-2">Avatar Color</label>
            <select name="avatar_color" class="w-full px-4 py-2.5 bg-dark-700 border border-dark-600 rounded-xl focus:outline-none focus:border-{{ primary_color }}-500">
                {% for color in ['emerald', 'blue', 'purple', 'rose', 'amber', 'cyan', 'indigo', 'pink', 'red', 'orange'] %}
                <option value="{{ color }}" {% if user.avatar_color == color %}selected{% endif %}>{{ color|title }}</option>
                {% endfor %}
            </select>
        </div>
        
        <div>
            <label class="block text-sm font-medium text-gray-300 mb-2">Roles</label>
            <div class="grid md:grid-cols-2 gap-3">
                {% for role in roles %}
                <label class="flex items-center gap-3 p-3 bg-dark-700/50 rounded-xl hover:bg-dark-700 cursor-pointer transition-colors">
                    <input type="checkbox" name="roles" value="{{ role.id }}" {% if role in user.roles %}checked{% endif %}
                        class="w-4 h-4 rounded bg-dark-600 border-dark-500 text-{{ primary_color }}-500">
                    <div>
                        <p class="text-sm font-medium">{{ role.name }}</p>
                        <p class="text-xs text-gray-500">{{ role.description }}</p>
                    </div>
                </label>
                {% endfor %}
            </div>
        </div>
        
        <div class="flex gap-4">
            <label class="flex items-center gap-3 p-3 bg-red-500/10 rounded-xl border border-red-500/20 flex-1">
                <input type="checkbox" name="is_superadmin" {% if user.is_superadmin %}checked{% endif %}
                    class="w-4 h-4 rounded bg-dark-600 border-dark-500 text-red-500">
                <div>
                    <p class="text-sm font-medium text-red-400">Super Admin</p>
                    <p class="text-xs text-gray-500">Bypass all permission checks</p>
                </div>
            </label>
            
            <label class="flex items-center gap-3 p-3 bg-dark-700/50 rounded-xl flex-1">
                <input type="checkbox" name="is_active" {% if user.is_active %}checked{% endif %}
                    class="w-4 h-4 rounded bg-dark-600 border-dark-500 text-{{ primary_color }}-500">
                <div>
                    <p class="text-sm font-medium">Active</p>
                    <p class="text-xs text-gray-500">Can login to admin</p>
                </div>
            </label>
        </div>
    </div>
    
    <div class="mt-6 flex gap-3">
        <button type="submit" class="px-6 py-2.5 bg-gradient-to-r from-{{ primary_color }}-500 to-{{ primary_color }}-600 hover:from-{{ primary_color }}-400 hover:to-{{ primary_color }}-500 text-white font-medium rounded-xl shadow-lg shadow-{{ primary_color }}-500/25 transition-all">
            Save Changes
        </button>
        <a href="{{ url_for('lic_admin.admin_users') }}" class="px-6 py-2.5 bg-dark-700 hover:bg-dark-600 rounded-xl font-medium transition-colors">Cancel</a>
    </div>
</form>
{% endblock %}
OPSLAB_LIC_EOF__7f2d8a5e

say "Writing app/licenses/templates/admin/features.html"
write_file 'app/licenses/templates/admin/features.html' << 'OPSLAB_LIC_EOF__7f2d8a5e'
{% extends "licenses/base.html" %}
{% block title %}Features — {{ site_name }}{% endblock %}

{% block content %}
<div class="p-6 space-y-6">

  <!-- Header -->
  <div class="flex items-center justify-between">
    <div>
      <h1 class="text-2xl font-bold text-white">Features</h1>
      <p class="text-sm text-gray-500 mt-1">Define licence features that can be assigned to products and individual licences</p>
    </div>
    <a href="{{ url_for('lic_admin.create_feature') }}"
       class="flex items-center gap-2 px-4 py-2.5 bg-emerald-500 hover:bg-emerald-400 text-white rounded-xl font-semibold text-sm transition-colors shadow-lg shadow-emerald-500/20">
      <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4v16m8-8H4"/>
      </svg>
      New Feature
    </a>
  </div>

  <!-- Stats bar -->
  <div class="grid grid-cols-3 gap-4">
    <div class="bg-dark-800 border border-dark-700/50 rounded-xl p-4 flex items-center gap-3">
      <div class="w-9 h-9 rounded-lg bg-emerald-500/10 flex items-center justify-center">
        <svg class="w-5 h-5 text-emerald-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 12l2 2 4-4M7.835 4.697a3.42 3.42 0 001.946-.806 3.42 3.42 0 014.438 0 3.42 3.42 0 001.946.806 3.42 3.42 0 013.138 3.138 3.42 3.42 0 00.806 1.946 3.42 3.42 0 010 4.438 3.42 3.42 0 00-.806 1.946 3.42 3.42 0 01-3.138 3.138 3.42 3.42 0 00-1.946.806 3.42 3.42 0 01-4.438 0 3.42 3.42 0 00-1.946-.806 3.42 3.42 0 01-3.138-3.138 3.42 3.42 0 00-.806-1.946 3.42 3.42 0 010-4.438 3.42 3.42 0 00.806-1.946 3.42 3.42 0 013.138-3.138z"/>
        </svg>
      </div>
      <div>
        <p class="text-xs text-gray-500">Total Features</p>
        <p class="text-xl font-bold text-white">{{ features|length }}</p>
      </div>
    </div>
    <div class="bg-dark-800 border border-dark-700/50 rounded-xl p-4 flex items-center gap-3">
      <div class="w-9 h-9 rounded-lg bg-blue-500/10 flex items-center justify-center">
        <svg class="w-5 h-5 text-blue-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7"/>
        </svg>
      </div>
      <div>
        <p class="text-xs text-gray-500">Active</p>
        <p class="text-xl font-bold text-white">{{ features|selectattr('is_active')|list|length }}</p>
      </div>
    </div>
    <div class="bg-dark-800 border border-dark-700/50 rounded-xl p-4 flex items-center gap-3">
      <div class="w-9 h-9 rounded-lg bg-purple-500/10 flex items-center justify-center">
        <svg class="w-5 h-5 text-purple-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 11H5m14 0a2 2 0 012 2v6a2 2 0 01-2 2H5a2 2 0 01-2-2v-6a2 2 0 012-2m14 0V9a2 2 0 00-2-2M5 11V9a2 2 0 012-2m0 0V5a2 2 0 012-2h6a2 2 0 012 2v2M7 7h10"/>
        </svg>
      </div>
      <div>
        <p class="text-xs text-gray-500">Categories</p>
        <p class="text-xl font-bold text-white">{{ grouped.keys()|list|length }}</p>
      </div>
    </div>
  </div>

  {% if features %}
    {% for category, cat_features in grouped.items() %}
    <div class="bg-dark-800 border border-dark-700/50 rounded-2xl overflow-hidden">
      <!-- Category header -->
      <div class="px-5 py-3 border-b border-dark-700/50 flex items-center gap-2 bg-dark-700/30">
        <span class="text-xs font-bold text-gray-400 uppercase tracking-wider">{{ category }}</span>
        <span class="text-xs bg-dark-600 text-gray-500 rounded-full px-2 py-0.5">{{ cat_features|length }}</span>
      </div>

      <table class="w-full">
        <thead>
          <tr class="text-xs text-gray-500 uppercase tracking-wider border-b border-dark-700/30">
            <th class="text-left px-5 py-3 font-semibold">Feature</th>
            <th class="text-left px-5 py-3 font-semibold">Code</th>
            <th class="text-left px-5 py-3 font-semibold">Description</th>
            <th class="text-center px-5 py-3 font-semibold">Status</th>
            <th class="text-right px-5 py-3 font-semibold">Actions</th>
          </tr>
        </thead>
        <tbody class="divide-y divide-dark-700/30">
          {% for feature in cat_features %}
          <tr class="hover:bg-dark-700/20 transition-colors">
            <td class="px-5 py-3.5">
              <div class="flex items-center gap-3">
                <div class="w-8 h-8 rounded-lg bg-emerald-500/10 border border-emerald-500/20 flex items-center justify-center flex-shrink-0">
                  <svg class="w-4 h-4 text-emerald-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M11 4a2 2 0 114 0v1a1 1 0 001 1h3a1 1 0 011 1v3a1 1 0 01-1 1h-1a2 2 0 100 4h1a1 1 0 011 1v3a1 1 0 01-1 1h-3a1 1 0 01-1-1v-1a2 2 0 10-4 0v1a1 1 0 01-1 1H7a1 1 0 01-1-1v-3a1 1 0 00-1-1H4a2 2 0 110-4h1a1 1 0 001-1V7a1 1 0 011-1h3a1 1 0 001-1V4z"/>
                  </svg>
                </div>
                <span class="font-semibold text-white text-sm">{{ feature.name }}</span>
              </div>
            </td>
            <td class="px-5 py-3.5">
              <code class="text-xs font-mono bg-dark-700 text-emerald-400 px-2 py-1 rounded">{{ feature.code }}</code>
            </td>
            <td class="px-5 py-3.5 text-sm text-gray-400 max-w-xs truncate">
              {{ feature.description or '—' }}
            </td>
            <td class="px-5 py-3.5 text-center">
              <button onclick="toggleFeature({{ feature.id }}, this)"
                      class="relative inline-flex h-5 w-9 items-center rounded-full transition-colors focus:outline-none
                             {{ 'bg-emerald-500' if feature.is_active else 'bg-dark-600' }}"
                      data-active="{{ 'true' if feature.is_active else 'false' }}">
                <span class="inline-block h-3.5 w-3.5 transform rounded-full bg-white transition-transform
                             {{ 'translate-x-4' if feature.is_active else 'translate-x-1' }}"></span>
              </button>
            </td>
            <td class="px-5 py-3.5 text-right">
              <div class="flex items-center justify-end gap-2">
                <a href="{{ url_for('lic_admin.edit_feature', id=feature.id) }}"
                   class="p-1.5 text-gray-400 hover:text-white hover:bg-dark-600 rounded-lg transition-colors">
                  <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z"/>
                  </svg>
                </a>
                <form method="POST" action="{{ url_for('lic_admin.delete_feature', id=feature.id) }}"
                      onsubmit="return confirm('Delete feature {{ feature.name }}?')">
                  <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
                  <button type="submit" class="p-1.5 text-gray-400 hover:text-red-400 hover:bg-red-500/10 rounded-lg transition-colors">
                    <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"/>
                    </svg>
                  </button>
                </form>
              </div>
            </td>
          </tr>
          {% endfor %}
        </tbody>
      </table>
    </div>
    {% endfor %}

  {% else %}
  <div class="bg-dark-800 border border-dark-700/50 rounded-2xl p-12 text-center">
    <div class="w-16 h-16 rounded-2xl bg-dark-700 flex items-center justify-center mx-auto mb-4">
      <svg class="w-8 h-8 text-gray-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M11 4a2 2 0 114 0v1a1 1 0 001 1h3a1 1 0 011 1v3a1 1 0 01-1 1h-1a2 2 0 100 4h1a1 1 0 011 1v3a1 1 0 01-1 1h-3a1 1 0 01-1-1v-1a2 2 0 10-4 0v1a1 1 0 01-1 1H7a1 1 0 01-1-1v-3a1 1 0 00-1-1H4a2 2 0 110-4h1a1 1 0 001-1V7a1 1 0 011-1h3a1 1 0 001-1V4z"/>
      </svg>
    </div>
    <p class="text-gray-400 font-semibold">No features yet</p>
    <p class="text-gray-600 text-sm mt-1">Create your first feature to start assigning it to licences</p>
    <a href="{{ url_for('lic_admin.create_feature') }}"
       class="inline-flex items-center gap-2 mt-4 px-4 py-2 bg-emerald-500 hover:bg-emerald-400 text-white rounded-xl text-sm font-semibold transition-colors">
      <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4v16m8-8H4"/>
      </svg>
      Create Feature
    </a>
  </div>
  {% endif %}

</div>

<script>
function toggleFeature(id, btn) {
  fetch(`/admin/features/${id}/toggle`, {
    method: 'POST',
    headers: { 'X-CSRFToken': document.querySelector('meta[name=csrf-token]').content }
  })
  .then(r => r.json())
  .then(data => {
    const isActive = data.active;
    btn.dataset.active = isActive;
    btn.className = btn.className.replace(/bg-(emerald|dark)-\d+/, isActive ? 'bg-emerald-500' : 'bg-dark-600');
    const knob = btn.querySelector('span');
    knob.className = knob.className.replace(/translate-x-\d/, isActive ? 'translate-x-4' : 'translate-x-1');
  });
}
</script>
{% endblock %}
OPSLAB_LIC_EOF__7f2d8a5e

say "Writing app/licenses/templates/admin/licenses.html"
write_file 'app/licenses/templates/admin/licenses.html' << 'OPSLAB_LIC_EOF__7f2d8a5e'
{% extends "licenses/base.html" %}
{% block title %}Licenses - License Manager{% endblock %}

{% block content %}
<div class="flex items-center justify-between mb-6">
    <div>
        <h1 class="text-2xl font-bold">Licenses</h1>
        <p class="text-gray-500">Manage all license keys</p>
    </div>
    <div class="flex gap-3">
        <a href="{{ url_for('lic_admin.bulk_create_licenses') }}" class="px-4 py-2 bg-dark-700 hover:bg-dark-600 border border-dark-500 rounded-lg transition-colors">
            Bulk Create
        </a>
        <a href="{{ url_for('lic_admin.create_license') }}" class="px-4 py-2 bg-emerald-600 hover:bg-emerald-700 text-white rounded-lg transition-colors">
            + Create License
        </a>
    </div>
</div>

<!-- Filters -->
<div class="bg-dark-800 border border-dark-600 rounded-xl p-4 mb-6">
    <div class="flex flex-wrap items-center gap-4">
        <div class="flex gap-2">
            <a href="{{ url_for('lic_admin.licenses', status='all') }}" 
               class="px-3 py-1.5 rounded-lg text-sm {% if current_status == 'all' %}bg-dark-600 text-white{% else %}text-gray-400 hover:bg-dark-700{% endif %}">
                All ({{ counts.all }})
            </a>
            <a href="{{ url_for('lic_admin.licenses', status='active') }}"
               class="px-3 py-1.5 rounded-lg text-sm {% if current_status == 'active' %}bg-green-500/20 text-green-400{% else %}text-gray-400 hover:bg-dark-700{% endif %}">
                Active ({{ counts.active }})
            </a>
            <a href="{{ url_for('lic_admin.licenses', status='suspended') }}"
               class="px-3 py-1.5 rounded-lg text-sm {% if current_status == 'suspended' %}bg-yellow-500/20 text-yellow-400{% else %}text-gray-400 hover:bg-dark-700{% endif %}">
                Suspended ({{ counts.suspended }})
            </a>
            <a href="{{ url_for('lic_admin.licenses', status='revoked') }}"
               class="px-3 py-1.5 rounded-lg text-sm {% if current_status == 'revoked' %}bg-red-500/20 text-red-400{% else %}text-gray-400 hover:bg-dark-700{% endif %}">
                Revoked ({{ counts.revoked }})
            </a>
        </div>
        
        <form class="flex-1 flex justify-end">
            <input type="text" name="search" value="{{ search }}" placeholder="Search license key or domain..."
                class="w-64 px-4 py-2 bg-dark-700 border border-dark-500 rounded-lg text-sm focus:outline-none focus:border-emerald-500">
        </form>
    </div>
</div>

<!-- Bulk Actions Bar -->
<div class="bg-dark-800 border border-dark-600 rounded-xl p-4 mb-4">
    <div class="flex flex-wrap items-center gap-4">
        <span class="text-sm text-gray-400">Bulk Actions:</span>
        <form id="bulkForm" method="POST" action="{{ url_for('lic_admin.bulk_license_action') }}" class="flex flex-wrap items-center gap-2">
            <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
            <input type="hidden" name="action" id="bulkAction" value="">
            <div id="selectedIds"></div>
            
            <button type="button" onclick="doBulkAction('activate')" class="px-3 py-1.5 bg-green-500/20 text-green-400 hover:bg-green-500/30 rounded text-sm">Activate</button>
            <button type="button" onclick="doBulkAction('suspend')" class="px-3 py-1.5 bg-yellow-500/20 text-yellow-400 hover:bg-yellow-500/30 rounded text-sm">Suspend</button>
            <button type="button" onclick="doBulkAction('revoke')" class="px-3 py-1.5 bg-red-500/20 text-red-400 hover:bg-red-500/30 rounded text-sm">Revoke</button>
            <button type="button" onclick="doBulkAction('clear_ips')" class="px-3 py-1.5 bg-blue-500/20 text-blue-400 hover:bg-blue-500/30 rounded text-sm">Clear IPs</button>
            <button type="button" onclick="doBulkAction('purge')" class="px-3 py-1.5 bg-orange-500/20 text-orange-400 hover:bg-orange-500/30 rounded text-sm">Purge Data</button>
            <button type="button" onclick="doBulkAction('delete')" class="px-3 py-1.5 bg-red-600 text-white hover:bg-red-700 rounded text-sm">Delete Selected</button>
        </form>
        
        <div class="flex-1"></div>
        
        <!-- Delete All -->
        <button type="button" onclick="document.getElementById('deleteAllModal').classList.remove('hidden')" 
            class="px-3 py-1.5 bg-red-900 text-red-300 hover:bg-red-800 rounded text-sm border border-red-700">
            ⚠ Delete ALL Licenses
        </button>
    </div>
</div>

<!-- Licenses Table -->
<form id="licenseTableForm">
<div class="bg-dark-800 border border-dark-600 rounded-xl overflow-hidden">
    <table class="w-full">
        <thead class="bg-dark-700">
            <tr>
                <th class="px-4 py-3 text-left">
                    <input type="checkbox" id="selectAll" onchange="toggleSelectAll()" class="w-4 h-4 bg-dark-600 border-dark-500 rounded">
                </th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-400 uppercase">License Key</th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-400 uppercase">Tier</th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-400 uppercase">Customer</th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-400 uppercase">Status</th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-400 uppercase">Expires</th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-400 uppercase">IPs</th>
                <th class="px-4 py-3 text-right text-xs font-medium text-gray-400 uppercase">Actions</th>
            </tr>
        </thead>
        <tbody class="divide-y divide-dark-600">
            {% for license in licenses.items %}
            <tr class="hover:bg-dark-700">
                <td class="px-4 py-3">
                    <input type="checkbox" name="license_check" value="{{ license.id }}" class="license-checkbox w-4 h-4 bg-dark-600 border-dark-500 rounded">
                </td>
                <td class="px-4 py-3">
                    <a href="{{ url_for('lic_admin.view_license', id=license.id) }}" class="font-mono text-sm text-emerald-400 hover:text-emerald-300">
                        {{ license.license_key }}
                    </a>
                </td>
                <td class="px-4 py-3">
                    <span class="text-sm">{{ license.tier.name }}</span>
                </td>
                <td class="px-4 py-3">
                    {% if license.customer %}
                    <span class="text-sm">{{ license.customer.company_name or license.customer.email }}</span>
                    {% else %}
                    <span class="text-sm text-gray-500">—</span>
                    {% endif %}
                </td>
                <td class="px-4 py-3">
                    <span class="px-2 py-1 text-xs rounded-full 
                        {% if license.status == 'active' %}bg-green-500/20 text-green-400
                        {% elif license.status == 'suspended' %}bg-yellow-500/20 text-yellow-400
                        {% else %}bg-red-500/20 text-red-400{% endif %}">
                        {{ license.status }}
                    </span>
                </td>
                <td class="px-4 py-3">
                    {% if license.expires_at %}
                        {% if license.is_expired %}
                        <span class="text-sm text-red-400">Expired</span>
                        {% elif license.days_until_expiry <= 30 %}
                        <span class="text-sm text-yellow-400">{{ license.days_until_expiry }} days</span>
                        {% else %}
                        <span class="text-sm text-gray-400">{{ license.expires_at.strftime('%d %b %Y') }}</span>
                        {% endif %}
                    {% else %}
                    <span class="text-sm text-gray-500">Lifetime</span>
                    {% endif %}
                </td>
                <td class="px-4 py-3">
                    <span class="text-sm {% if license.allowed_ips %}text-blue-400{% else %}text-gray-500{% endif %}">
                        {{ (license.allowed_ips or [])|length }}/{{ license.product.max_ip_addresses }}
                    </span>
                </td>
                <td class="px-4 py-3 text-right">
                    <div class="flex items-center justify-end gap-2">
                        <a href="{{ url_for('lic_admin.view_license', id=license.id) }}" class="text-gray-400 hover:text-white" title="View">
                            <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"/>
                                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M2.458 12C3.732 7.943 7.523 5 12 5c4.478 0 8.268 2.943 9.542 7-1.274 4.057-5.064 7-9.542 7-4.477 0-8.268-2.943-9.542-7z"/>
                            </svg>
                        </a>
                        <a href="{{ url_for('lic_admin.edit_license', id=license.id) }}" class="text-gray-400 hover:text-blue-400" title="Edit">
                            <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z"/>
                            </svg>
                        </a>
                        <a href="{{ url_for('lic_admin.manage_license_ips', id=license.id) }}" class="text-gray-400 hover:text-blue-400" title="Manage IPs">
                            <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M21 12a9 9 0 01-9 9m9-9a9 9 0 00-9-9m9 9H3m9 9a9 9 0 01-9-9m9 9c1.657 0 3-4.03 3-9s-1.343-9-3-9m0 18c-1.657 0-3-4.03-3-9s1.343-9 3-9"/>
                            </svg>
                        </a>
                    </div>
                </td>
            </tr>
            {% else %}
            <tr>
                <td colspan="8" class="px-4 py-8 text-center text-gray-500">No licenses found</td>
            </tr>
            {% endfor %}
        </tbody>
    </table>
</div>
</form>

<!-- Pagination -->
{% if licenses.pages > 1 %}
<div class="flex justify-center mt-6 gap-2">
    {% for page in licenses.iter_pages() %}
        {% if page %}
        <a href="{{ url_for('lic_admin.licenses', page=page, status=current_status, search=search) }}"
           class="px-3 py-1 rounded {% if page == licenses.page %}bg-emerald-600 text-white{% else %}bg-dark-700 text-gray-400 hover:bg-dark-600{% endif %}">
            {{ page }}
        </a>
        {% else %}
        <span class="px-3 py-1 text-gray-500">...</span>
        {% endif %}
    {% endfor %}
</div>
{% endif %}

<!-- Delete All Modal -->
<div id="deleteAllModal" class="hidden fixed inset-0 bg-black/50 flex items-center justify-center z-50">
    <div class="bg-dark-800 border border-dark-600 rounded-xl p-6 max-w-md mx-4">
        <h2 class="text-xl font-bold text-red-400 mb-4">⚠ Delete ALL Licenses</h2>
        <p class="text-gray-400 mb-4">This will permanently delete <strong>ALL {{ counts.all }} licenses</strong> and their data. This cannot be undone!</p>
        <form method="POST" action="{{ url_for('lic_admin.delete_all_licenses') }}">
            <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
            <div class="mb-4">
                <label class="block text-sm text-gray-400 mb-2">Type <span class="text-red-400 font-mono">DELETE ALL</span> to confirm:</label>
                <input type="text" name="confirm" placeholder="DELETE ALL" required
                    class="w-full px-4 py-2 bg-dark-700 border border-dark-500 rounded-lg focus:outline-none focus:border-red-500">
            </div>
            <div class="flex gap-3">
                <button type="button" onclick="document.getElementById('deleteAllModal').classList.add('hidden')" 
                    class="flex-1 px-4 py-2 bg-dark-700 hover:bg-dark-600 rounded-lg">Cancel</button>
                <button type="submit" class="flex-1 px-4 py-2 bg-red-600 hover:bg-red-700 text-white rounded-lg">Delete All</button>
            </div>
        </form>
    </div>
</div>

<script>
function toggleSelectAll() {
    const selectAll = document.getElementById('selectAll');
    const checkboxes = document.querySelectorAll('.license-checkbox');
    checkboxes.forEach(cb => cb.checked = selectAll.checked);
}

function doBulkAction(action) {
    const checkboxes = document.querySelectorAll('.license-checkbox:checked');
    if (checkboxes.length === 0) {
        alert('Please select at least one license');
        return;
    }
    
    const actionNames = {
        'delete': 'DELETE',
        'purge': 'PURGE all data from',
        'suspend': 'SUSPEND',
        'activate': 'ACTIVATE',
        'revoke': 'REVOKE',
        'clear_ips': 'CLEAR IPs for'
    };
    
    if (!confirm(`${actionNames[action]} ${checkboxes.length} selected license(s)?`)) {
        return;
    }
    
    document.getElementById('bulkAction').value = action;
    
    // Clear and repopulate selected IDs
    const container = document.getElementById('selectedIds');
    container.innerHTML = '';
    checkboxes.forEach(cb => {
        const input = document.createElement('input');
        input.type = 'hidden';
        input.name = 'license_ids';
        input.value = cb.value;
        container.appendChild(input);
    });
    
    document.getElementById('bulkForm').submit();
}
</script>
{% endblock %}
OPSLAB_LIC_EOF__7f2d8a5e

say "Writing app/licenses/templates/admin/manage_ips.html"
write_file 'app/licenses/templates/admin/manage_ips.html' << 'OPSLAB_LIC_EOF__7f2d8a5e'
{% extends "licenses/base.html" %}
{% block title %}Manage IPs - {{ license.license_key }}{% endblock %}
{% block content %}
<div class="mb-6">
    <a href="{{ url_for('lic_admin.view_license', id=license.id) }}" class="text-gray-500 hover:text-gray-300 text-sm mb-2 inline-block">← Back to License</a>
    <h1 class="text-2xl font-bold">Manage Allowed IPs</h1>
    <p class="text-gray-500 font-mono">{{ license.license_key }}</p>
</div>

<div class="grid md:grid-cols-2 gap-6">
    <!-- Current IPs -->
    <div class="bg-dark-800 border border-dark-600 rounded-xl p-6">
        <h2 class="text-lg font-semibold mb-4">Allowed IPs ({{ (license.allowed_ips or [])|length }} / {{ license.product.max_ip_addresses }})</h2>
        
        {% if license.allowed_ips %}
        <div class="space-y-2">
            {% for ip in license.allowed_ips %}
            <div class="flex items-center justify-between bg-dark-700 rounded-lg px-4 py-2">
                <span class="font-mono">{{ ip }}</span>
                <form method="POST" class="inline">
                    <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
                    <input type="hidden" name="action" value="remove">
                    <input type="hidden" name="ip" value="{{ ip }}">
                    <button type="submit" class="text-red-400 hover:text-red-300 text-sm">Remove</button>
                </form>
            </div>
            {% endfor %}
        </div>
        
        <form method="POST" class="mt-4">
            <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
            <input type="hidden" name="action" value="clear">
            <button type="submit" onclick="return confirm('Clear all IPs?')" 
                class="w-full px-4 py-2 bg-red-600/20 hover:bg-red-600/30 text-red-400 rounded-lg border border-red-600/50">
                Clear All IPs
            </button>
        </form>
        {% else %}
        <p class="text-gray-500">No IPs registered</p>
        {% endif %}
    </div>
    
    <!-- Add IP -->
    <div class="bg-dark-800 border border-dark-600 rounded-xl p-6">
        <h2 class="text-lg font-semibold mb-4">Add IP Address</h2>
        
        <form method="POST" class="space-y-4">
            <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
            <input type="hidden" name="action" value="add">
            <div>
                <input type="text" name="ip" placeholder="192.168.1.1" required
                    class="w-full px-4 py-2.5 bg-dark-700 border border-dark-500 rounded-lg focus:outline-none focus:border-emerald-500 font-mono">
            </div>
            <button type="submit" class="w-full px-4 py-2.5 bg-emerald-600 hover:bg-emerald-700 rounded-lg font-medium">
                Add IP
            </button>
        </form>
        
        <div class="mt-6 p-4 bg-dark-700 rounded-lg">
            <h3 class="text-sm font-medium text-gray-400 mb-2">IP Lock Settings</h3>
            <p class="text-sm text-gray-500">
                <strong>Required:</strong> {{ 'Yes' if license.product.require_ip_lock else 'No' }}<br>
                <strong>Max IPs:</strong> {{ license.product.max_ip_addresses }}<br>
                <strong>Customer can change:</strong> {{ 'Yes' if license.product.allow_ip_change else 'No' }}<br>
                <strong>Cooldown:</strong> {{ license.product.ip_change_cooldown }} hours
            </p>
        </div>
    </div>
</div>
{% endblock %}
OPSLAB_LIC_EOF__7f2d8a5e

say "Writing app/licenses/templates/admin/products.html"
write_file 'app/licenses/templates/admin/products.html' << 'OPSLAB_LIC_EOF__7f2d8a5e'
{% extends "licenses/base.html" %}
{% block title %}Products - License Manager{% endblock %}

{% block content %}
<div class="flex items-center justify-between mb-6">
    <div>
        <h1 class="text-2xl font-bold">Products & Tiers</h1>
        <p class="text-gray-500">Manage products and pricing tiers</p>
    </div>
    <a href="{{ url_for('lic_admin.create_product') }}" class="px-4 py-2 bg-emerald-600 hover:bg-emerald-700 text-white rounded-lg">
        + Create Product
    </a>
</div>

{% for product in products %}
<div class="bg-dark-800 border border-dark-600 rounded-xl mb-6">
    <div class="p-4 border-b border-dark-600 flex items-center justify-between">
        <div>
            <div class="flex items-center gap-3">
                <h2 class="font-semibold">{{ product.name }}</h2>
                {% if not product.is_active %}
                <span class="px-2 py-0.5 text-xs bg-gray-500/20 text-gray-400 rounded">Inactive</span>
                {% endif %}
                {% if product.require_ip_lock %}
                <span class="px-2 py-0.5 text-xs bg-blue-500/20 text-blue-400 rounded">IP Lock</span>
                {% endif %}
            </div>
            <p class="text-sm text-gray-500">Code: {{ product.code }} • {{ product.licenses.count() }} licenses</p>
        </div>
        <div class="flex gap-2">
            <a href="{{ url_for('lic_admin.edit_tiers', id=product.id) }}" class="px-3 py-1.5 text-sm bg-dark-700 hover:bg-dark-600 rounded-lg">
                Edit Tiers
            </a>
            <a href="{{ url_for('lic_admin.edit_product', id=product.id) }}" class="px-3 py-1.5 text-sm bg-dark-700 hover:bg-dark-600 rounded-lg">
                Edit
            </a>
            <form method="POST" action="{{ url_for('lic_admin.delete_product', id=product.id) }}" class="inline" 
                  onsubmit="return confirm('Delete this product and all its tiers?');">
                <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
                <button type="submit" class="px-3 py-1.5 text-sm bg-red-500/20 text-red-400 hover:bg-red-500/30 rounded-lg">
                    Delete
                </button>
            </form>
        </div>
    </div>
    
    <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4 p-4">
        {% for tier in product.tiers %}
        <div class="bg-dark-700 rounded-lg p-4 border border-dark-600">
            <div class="flex items-center justify-between mb-2">
                <h3 class="font-medium">{{ tier.name }}</h3>
                <span class="text-xs text-gray-500">{{ tier.licenses.count() }} licenses</span>
            </div>
            <p class="text-sm text-gray-500 mb-3">{{ tier.code }}</p>
            
            <div class="space-y-2 text-sm">
                <div class="flex justify-between">
                    <span class="text-gray-500">Monthly</span>
                    <span>${{ tier.price_monthly }}</span>
                </div>
                <div class="flex justify-between">
                    <span class="text-gray-500">Yearly</span>
                    <span>${{ tier.price_yearly }}</span>
                </div>
                <div class="flex justify-between">
                    <span class="text-gray-500">Max Users</span>
                    <span>{{ tier.max_users or 'Unlimited' }}</span>
                </div>
            </div>
            
            <div class="mt-3 pt-3 border-t border-dark-600">
                <p class="text-xs text-gray-500 mb-2">Features:</p>
                <div class="flex flex-wrap gap-1">
                    {% for feature, enabled in (tier.features or {}).items() if enabled %}
                    <span class="px-2 py-0.5 bg-emerald-500/20 text-emerald-400 text-xs rounded">{{ feature }}</span>
                    {% endfor %}
                </div>
            </div>
        </div>
        {% else %}
        <div class="col-span-full text-center py-8 text-gray-500">
            <p>No tiers yet</p>
            <a href="{{ url_for('lic_admin.create_tier', product_id=product.id) }}" class="text-emerald-400 hover:text-emerald-300 text-sm">+ Add Tier</a>
        </div>
        {% endfor %}
    </div>
</div>
{% else %}
<div class="bg-dark-800 border border-dark-600 rounded-xl p-12 text-center">
    <p class="text-gray-500 mb-4">No products yet</p>
    <a href="{{ url_for('lic_admin.create_product') }}" class="px-4 py-2 bg-emerald-600 hover:bg-emerald-700 text-white rounded-lg">
        Create First Product
    </a>
</div>
{% endfor %}
{% endblock %}
OPSLAB_LIC_EOF__7f2d8a5e

say "Writing app/licenses/templates/admin/roles.html"
write_file 'app/licenses/templates/admin/roles.html' << 'OPSLAB_LIC_EOF__7f2d8a5e'
{% extends "licenses/base.html" %}
{% block title %}Roles - {{ site_name }}{% endblock %}

{% block content %}
<div class="flex items-center justify-between mb-8">
    <div>
        <h1 class="text-3xl font-bold bg-gradient-to-r from-white to-gray-400 bg-clip-text text-transparent">Roles & Permissions</h1>
        <p class="text-gray-500 mt-1">Manage access control for admin users</p>
    </div>
    <a href="{{ url_for('lic_admin.create_role') }}" class="px-5 py-2.5 bg-gradient-to-r from-{{ primary_color }}-500 to-{{ primary_color }}-600 hover:from-{{ primary_color }}-400 hover:to-{{ primary_color }}-500 text-white font-medium rounded-xl shadow-lg shadow-{{ primary_color }}-500/25 transition-all duration-200 flex items-center gap-2">
        <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4v16m8-8H4"/></svg>
        Create Role
    </a>
</div>

<div class="grid md:grid-cols-2 lg:grid-cols-3 gap-6">
    {% for role in roles %}
    <div class="bg-dark-800/50 backdrop-blur border border-dark-700/50 rounded-2xl overflow-hidden hover:border-dark-600 transition-colors group">
        <div class="p-6">
            <div class="flex items-start justify-between mb-4">
                <div class="flex items-center gap-3">
                    <div class="w-12 h-12 bg-{{ role.color }}-500/20 rounded-xl flex items-center justify-center">
                        <svg class="w-6 h-6 text-{{ role.color }}-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 12l2 2 4-4m5.618-4.016A11.955 11.955 0 0112 2.944a11.955 11.955 0 01-8.618 3.04A12.02 12.02 0 003 9c0 5.591 3.824 10.29 9 11.622 5.176-1.332 9-6.03 9-11.622 0-1.042-.133-2.052-.382-3.016z"/>
                        </svg>
                    </div>
                    <div>
                        <h3 class="font-semibold text-lg">{{ role.name }}</h3>
                        <p class="text-sm text-gray-500">{{ role.users|length }} users</p>
                    </div>
                </div>
                {% if role.is_system %}
                <span class="px-2 py-1 bg-gray-500/20 text-gray-400 text-xs rounded-lg">System</span>
                {% endif %}
            </div>
            
            {% if role.description %}
            <p class="text-sm text-gray-400 mb-4">{{ role.description }}</p>
            {% endif %}
            
            <div class="flex flex-wrap gap-1.5 mb-4">
                {% for perm in role.permissions[:5] %}
                <span class="px-2 py-1 bg-dark-700 text-gray-400 text-xs rounded-lg">{{ perm.name }}</span>
                {% endfor %}
                {% if role.permissions|length > 5 %}
                <span class="px-2 py-1 bg-dark-700 text-gray-400 text-xs rounded-lg">+{{ role.permissions|length - 5 }} more</span>
                {% endif %}
            </div>
            
            <div class="flex gap-2 pt-4 border-t border-dark-700/50">
                <a href="{{ url_for('lic_admin.edit_role', id=role.id) }}" class="flex-1 px-3 py-2 bg-dark-700 hover:bg-dark-600 text-center rounded-xl text-sm font-medium transition-colors">Edit</a>
                {% if not role.is_system %}
                <form method="POST" action="{{ url_for('lic_admin.delete_role', id=role.id) }}" onsubmit="return confirm('Delete this role?');">
                    <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
                    <button type="submit" class="px-3 py-2 bg-red-500/20 hover:bg-red-500/30 text-red-400 rounded-xl text-sm font-medium transition-colors">Delete</button>
                </form>
                {% endif %}
            </div>
        </div>
    </div>
    {% endfor %}
</div>
{% endblock %}
OPSLAB_LIC_EOF__7f2d8a5e

say "Writing app/licenses/templates/admin/settings.html"
write_file 'app/licenses/templates/admin/settings.html' << 'OPSLAB_LIC_EOF__7f2d8a5e'
{% extends "licenses/base.html" %}
{% block title %}Settings - {{ site_name }}{% endblock %}

{% block content %}
<div class="mb-8">
    <h1 class="text-3xl font-bold bg-gradient-to-r from-white to-gray-400 bg-clip-text text-transparent">Settings</h1>
    <p class="text-gray-500 mt-1">Configure your license manager</p>
</div>

<form method="POST">
    <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
    
    <div class="grid gap-6">
        {% for category, settings in settings_by_category.items() %}
        <div class="bg-dark-800/50 backdrop-blur border border-dark-700/50 rounded-2xl overflow-hidden">
            <div class="px-6 py-4 border-b border-dark-700/50 bg-dark-800/50">
                <h2 class="text-lg font-semibold capitalize">{{ category }}</h2>
            </div>
            <div class="p-6 space-y-5">
                {% for setting in settings %}
                <div class="grid md:grid-cols-3 gap-4 items-start">
                    <div>
                        <label class="text-sm font-medium text-gray-300">{{ setting.key.replace('_', ' ')|title }}</label>
                        {% if setting.description %}
                        <p class="text-xs text-gray-500 mt-1">{{ setting.description }}</p>
                        {% endif %}
                    </div>
                    <div class="md:col-span-2">
                        {% if setting.key == 'primary_color' %}
                        <select name="{{ setting.key }}" class="w-full px-4 py-2.5 bg-dark-700 border border-dark-600 rounded-xl focus:outline-none focus:border-{{ primary_color }}-500 focus:ring-1 focus:ring-{{ primary_color }}-500/50 transition-colors">
                            {% for color in ['emerald', 'blue', 'purple', 'rose', 'amber', 'cyan', 'indigo'] %}
                            <option value="{{ color }}" {% if setting.value == color %}selected{% endif %}>{{ color|title }}</option>
                            {% endfor %}
                        </select>
                        {% elif setting.value in ['true', 'false'] %}
                        <select name="{{ setting.key }}" class="w-full px-4 py-2.5 bg-dark-700 border border-dark-600 rounded-xl focus:outline-none focus:border-{{ primary_color }}-500 focus:ring-1 focus:ring-{{ primary_color }}-500/50 transition-colors">
                            <option value="true" {% if setting.value == 'true' %}selected{% endif %}>Yes</option>
                            <option value="false" {% if setting.value == 'false' %}selected{% endif %}>No</option>
                        </select>
                        {% else %}
                        <input type="text" name="{{ setting.key }}" value="{{ setting.value }}"
                            class="w-full px-4 py-2.5 bg-dark-700 border border-dark-600 rounded-xl focus:outline-none focus:border-{{ primary_color }}-500 focus:ring-1 focus:ring-{{ primary_color }}-500/50 transition-colors">
                        {% endif %}
                    </div>
                </div>
                {% endfor %}
            </div>
        </div>
        {% endfor %}
    </div>
    
    <div class="mt-6 flex justify-end">
        <button type="submit" class="px-6 py-2.5 bg-gradient-to-r from-{{ primary_color }}-500 to-{{ primary_color }}-600 hover:from-{{ primary_color }}-400 hover:to-{{ primary_color }}-500 text-white font-medium rounded-xl shadow-lg shadow-{{ primary_color }}-500/25 transition-all duration-200">
            Save Settings
        </button>
    </div>
</form>
{% endblock %}
OPSLAB_LIC_EOF__7f2d8a5e

say "Writing app/licenses/templates/admin/users.html"
write_file 'app/licenses/templates/admin/users.html' << 'OPSLAB_LIC_EOF__7f2d8a5e'
{% extends "licenses/base.html" %}
{% block title %}Admin Users - {{ site_name }}{% endblock %}

{% block content %}
<div class="flex items-center justify-between mb-8">
    <div>
        <h1 class="text-3xl font-bold bg-gradient-to-r from-white to-gray-400 bg-clip-text text-transparent">Admin Users</h1>
        <p class="text-gray-500 mt-1">Manage administrator accounts</p>
    </div>
    <a href="{{ url_for('lic_admin.create_admin_user') }}" class="px-5 py-2.5 bg-gradient-to-r from-{{ primary_color }}-500 to-{{ primary_color }}-600 hover:from-{{ primary_color }}-400 hover:to-{{ primary_color }}-500 text-white font-medium rounded-xl shadow-lg shadow-{{ primary_color }}-500/25 transition-all duration-200 flex items-center gap-2">
        <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4v16m8-8H4"/></svg>
        Add User
    </a>
</div>

<div class="bg-dark-800/50 backdrop-blur border border-dark-700/50 rounded-2xl overflow-hidden">
    <table class="w-full">
        <thead class="bg-dark-700/50">
            <tr>
                <th class="px-6 py-4 text-left text-xs font-semibold text-gray-400 uppercase tracking-wider">User</th>
                <th class="px-6 py-4 text-left text-xs font-semibold text-gray-400 uppercase tracking-wider">Roles</th>
                <th class="px-6 py-4 text-left text-xs font-semibold text-gray-400 uppercase tracking-wider">Status</th>
                <th class="px-6 py-4 text-left text-xs font-semibold text-gray-400 uppercase tracking-wider">Last Login</th>
                <th class="px-6 py-4 text-right text-xs font-semibold text-gray-400 uppercase tracking-wider">Actions</th>
            </tr>
        </thead>
        <tbody class="divide-y divide-dark-700/50">
            {% for user in users %}
            <tr class="hover:bg-dark-700/30 transition-colors">
                <td class="px-6 py-4">
                    <div class="flex items-center gap-3">
                        <div class="w-10 h-10 bg-gradient-to-br from-{{ user.avatar_color }}-400 to-{{ user.avatar_color }}-600 rounded-xl flex items-center justify-center text-sm font-bold text-white">
                            {{ user.name[0] }}
                        </div>
                        <div>
                            <p class="font-medium">{{ user.name }}</p>
                            <p class="text-sm text-gray-500">{{ user.email }}</p>
                        </div>
                    </div>
                </td>
                <td class="px-6 py-4">
                    <div class="flex flex-wrap gap-1.5">
                        {% if user.is_superadmin %}
                        <span class="px-2 py-1 bg-red-500/20 text-red-400 text-xs rounded-lg font-medium">Super Admin</span>
                        {% endif %}
                        {% for role in user.roles %}
                        <span class="px-2 py-1 bg-{{ role.color }}-500/20 text-{{ role.color }}-400 text-xs rounded-lg">{{ role.name }}</span>
                        {% endfor %}
                    </div>
                </td>
                <td class="px-6 py-4">
                    {% if user.is_active %}
                    <span class="px-2.5 py-1 bg-{{ primary_color }}-500/20 text-{{ primary_color }}-400 text-xs rounded-full font-medium">Active</span>
                    {% else %}
                    <span class="px-2.5 py-1 bg-gray-500/20 text-gray-400 text-xs rounded-full font-medium">Inactive</span>
                    {% endif %}
                </td>
                <td class="px-6 py-4 text-sm text-gray-400">
                    {{ user.last_login.strftime('%d %b %Y %H:%M') if user.last_login else 'Never' }}
                </td>
                <td class="px-6 py-4 text-right">
                    <div class="flex items-center justify-end gap-2">
                        <a href="{{ url_for('lic_admin.edit_admin_user', id=user.id) }}" class="p-2 text-gray-400 hover:text-{{ primary_color }}-400 hover:bg-{{ primary_color }}-500/10 rounded-lg transition-colors">
                            <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z"/></svg>
                        </a>
                        {% if user.id != current_user.id %}
                        <form method="POST" action="{{ url_for('lic_admin.delete_admin_user', id=user.id) }}" onsubmit="return confirm('Delete this user?');">
                            <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
                            <button type="submit" class="p-2 text-gray-400 hover:text-red-400 hover:bg-red-500/10 rounded-lg transition-colors">
                                <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"/></svg>
                            </button>
                        </form>
                        {% endif %}
                    </div>
                </td>
            </tr>
            {% endfor %}
        </tbody>
    </table>
</div>
{% endblock %}
OPSLAB_LIC_EOF__7f2d8a5e

say "Writing app/licenses/templates/admin/view_customer.html"
write_file 'app/licenses/templates/admin/view_customer.html' << 'OPSLAB_LIC_EOF__7f2d8a5e'
{% extends "licenses/base.html" %}
{% block title %}{{ customer.company_name or customer.email }} - License Manager{% endblock %}

{% block content %}
<div class="flex items-center justify-between mb-6">
    <div>
        <a href="{{ url_for('lic_admin.customers') }}" class="text-gray-500 hover:text-gray-300 text-sm mb-2 inline-block">← Back to Customers</a>
        <h1 class="text-2xl font-bold">{{ customer.company_name or customer.email }}</h1>
    </div>
    <a href="{{ url_for('lic_admin.edit_customer', id=customer.id) }}" class="px-4 py-2 bg-dark-700 hover:bg-dark-600 border border-dark-500 rounded-lg">
        Edit
    </a>
</div>

<div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
    <div class="lg:col-span-2">
        <!-- Licenses -->
        <div class="bg-dark-800 border border-dark-600 rounded-xl">
            <div class="p-4 border-b border-dark-600 flex items-center justify-between">
                <h2 class="font-semibold">Licenses ({{ licenses|length }})</h2>
                <a href="{{ url_for('lic_admin.create_license') }}" class="text-sm text-emerald-400 hover:text-emerald-300">+ Create License</a>
            </div>
            <div class="divide-y divide-dark-600">
                {% for license in licenses %}
                <a href="{{ url_for('lic_admin.view_license', id=license.id) }}" class="flex items-center justify-between p-4 hover:bg-dark-700">
                    <div>
                        <p class="font-mono text-sm">{{ license.license_key }}</p>
                        <p class="text-xs text-gray-500 mt-1">{{ license.tier.name }} • {{ license.created_at.strftime('%d %b %Y') }}</p>
                    </div>
                    <span class="px-2 py-1 text-xs rounded-full {% if license.status == 'active' %}bg-green-500/20 text-green-400{% else %}bg-red-500/20 text-red-400{% endif %}">
                        {{ license.status }}
                    </span>
                </a>
                {% else %}
                <p class="p-4 text-gray-500 text-sm">No licenses yet</p>
                {% endfor %}
            </div>
        </div>
    </div>
    
    <div class="space-y-6">
        <!-- Contact Info -->
        <div class="bg-dark-800 border border-dark-600 rounded-xl p-6">
            <h2 class="font-semibold mb-4">Contact Information</h2>
            <dl class="space-y-3 text-sm">
                <div>
                    <dt class="text-gray-500">Email</dt>
                    <dd>{{ customer.email }}</dd>
                </div>
                {% if customer.contact_name %}
                <div>
                    <dt class="text-gray-500">Contact</dt>
                    <dd>{{ customer.contact_name }}</dd>
                </div>
                {% endif %}
                {% if customer.phone %}
                <div>
                    <dt class="text-gray-500">Phone</dt>
                    <dd>{{ customer.phone }}</dd>
                </div>
                {% endif %}
                {% if customer.address %}
                <div>
                    <dt class="text-gray-500">Address</dt>
                    <dd class="whitespace-pre-line">{{ customer.address }}</dd>
                </div>
                {% endif %}
            </dl>
        </div>
        
        <!-- Status -->
        <div class="bg-dark-800 border border-dark-600 rounded-xl p-6">
            <h2 class="font-semibold mb-4">Status</h2>
            <span class="px-3 py-1 rounded-full text-sm {% if customer.is_active %}bg-green-500/20 text-green-400{% else %}bg-gray-500/20 text-gray-400{% endif %}">
                {{ 'Active' if customer.is_active else 'Inactive' }}
            </span>
            <p class="text-xs text-gray-500 mt-4">Created {{ customer.created_at.strftime('%d %b %Y') }}</p>
        </div>
        
        {% if customer.notes %}
        <div class="bg-dark-800 border border-dark-600 rounded-xl p-6">
            <h2 class="font-semibold mb-4">Notes</h2>
            <p class="text-sm text-gray-300">{{ customer.notes }}</p>
        </div>
        {% endif %}
    </div>
</div>
{% endblock %}
OPSLAB_LIC_EOF__7f2d8a5e

say "Writing app/licenses/templates/admin/view_license.html"
write_file 'app/licenses/templates/admin/view_license.html' << 'OPSLAB_LIC_EOF__7f2d8a5e'
{% extends "licenses/base.html" %}
{% block title %}License {{ license.license_key }} - License Manager{% endblock %}

{% block content %}
<div class="flex items-center justify-between mb-6">
    <div>
        <a href="{{ url_for('lic_admin.licenses') }}" class="text-gray-500 hover:text-gray-300 text-sm mb-2 inline-block">← Back to Licenses</a>
        <h1 class="text-2xl font-bold font-mono">{{ license.license_key }}</h1>
    </div>
    <a href="{{ url_for('lic_admin.edit_license', id=license.id) }}" class="px-4 py-2 bg-dark-700 hover:bg-dark-600 border border-dark-500 rounded-lg">Edit</a>
</div>

<div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
    <div class="lg:col-span-2 space-y-6">
        <!-- Status Card -->
        <div class="bg-dark-800 border border-dark-600 rounded-xl p-6">
            <div class="flex items-center justify-between mb-6">
                <h2 class="font-semibold">License Status</h2>
                <span class="px-3 py-1 rounded-full text-sm font-medium
                    {% if license.status == 'active' %}bg-green-500/20 text-green-400
                    {% elif license.status == 'suspended' %}bg-yellow-500/20 text-yellow-400
                    {% else %}bg-red-500/20 text-red-400{% endif %}">
                    {{ license.status|upper }}
                </span>
            </div>
            
            <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
                <div>
                    <p class="text-xs text-gray-500 uppercase">Product</p>
                    <p class="font-medium mt-1">{{ license.product.name }}</p>
                </div>
                <div>
                    <p class="text-xs text-gray-500 uppercase">Tier</p>
                    <p class="font-medium mt-1">{{ license.tier.name }}</p>
                </div>
                <div>
                    <p class="text-xs text-gray-500 uppercase">Max Users</p>
                    <p class="font-medium mt-1">{{ license.tier.max_users or 'Unlimited' }}</p>
                </div>
                <div>
                    <p class="text-xs text-gray-500 uppercase">Activations</p>
                    <p class="font-medium mt-1">{{ license.current_activations }}/{{ license.max_activations }}</p>
                </div>
            </div>
            
            <!-- Status Actions -->
            <div class="mt-6 pt-6 border-t border-dark-600 flex flex-wrap gap-3">
                {% if license.status == 'active' %}
                <form method="POST" action="{{ url_for('lic_admin.change_license_status', id=license.id) }}">
                    <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
                    <input type="hidden" name="status" value="suspended">
                    <button type="submit" class="px-4 py-2 bg-yellow-500/20 text-yellow-400 hover:bg-yellow-500/30 rounded-lg text-sm">Suspend</button>
                </form>
                <form method="POST" action="{{ url_for('lic_admin.change_license_status', id=license.id) }}" onsubmit="return confirm('Revoke this license?');">
                    <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
                    <input type="hidden" name="status" value="revoked">
                    <button type="submit" class="px-4 py-2 bg-red-500/20 text-red-400 hover:bg-red-500/30 rounded-lg text-sm">Revoke</button>
                </form>
                {% elif license.status == 'suspended' %}
                <form method="POST" action="{{ url_for('lic_admin.change_license_status', id=license.id) }}">
                    <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
                    <input type="hidden" name="status" value="active">
                    <button type="submit" class="px-4 py-2 bg-green-500/20 text-green-400 hover:bg-green-500/30 rounded-lg text-sm">Reactivate</button>
                </form>
                {% elif license.status == 'revoked' %}
                <form method="POST" action="{{ url_for('lic_admin.change_license_status', id=license.id) }}">
                    <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
                    <input type="hidden" name="status" value="active">
                    <button type="submit" class="px-4 py-2 bg-green-500/20 text-green-400 hover:bg-green-500/30 rounded-lg text-sm">Reactivate</button>
                </form>
                {% endif %}
                
                <form method="POST" action="{{ url_for('lic_admin.reset_activations', id=license.id) }}" onsubmit="return confirm('Reset all activations?');">
                    <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
                    <button type="submit" class="px-4 py-2 bg-dark-700 hover:bg-dark-600 rounded-lg text-sm">Reset Activations</button>
                </form>
                
                <a href="{{ url_for('lic_admin.manage_license_ips', id=license.id) }}" class="px-4 py-2 bg-blue-500/20 text-blue-400 hover:bg-blue-500/30 rounded-lg text-sm">Manage IPs</a>
                
                <form method="POST" action="{{ url_for('lic_admin.purge_license', id=license.id) }}" onsubmit="return confirm('Purge ALL data (IPs, activations, history)? License will be kept.');">
                    <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
                    <button type="submit" class="px-4 py-2 bg-orange-500/20 text-orange-400 hover:bg-orange-500/30 rounded-lg text-sm">Purge Data</button>
                </form>
                
                <form method="POST" action="{{ url_for('lic_admin.delete_license', id=license.id) }}" onsubmit="return confirm('PERMANENTLY DELETE this license? This cannot be undone!');">
                    <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
                    <button type="submit" class="px-4 py-2 bg-red-600 text-white hover:bg-red-700 rounded-lg text-sm">Delete License</button>
                </form>
            </div>
        </div>
        
        <!-- Features -->
        <div class="bg-dark-800 border border-dark-600 rounded-xl p-6">
            <h2 class="font-semibold mb-4">Features</h2>
            <div class="grid grid-cols-2 md:grid-cols-3 gap-3">
                {% for feature, enabled in (license.tier.features or {}).items() %}
                <div class="flex items-center gap-2">
                    {% if enabled %}
                    <svg class="w-5 h-5 text-green-400" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7"/></svg>
                    <span class="text-sm capitalize">{{ feature.replace('_', ' ') }}</span>
                    {% else %}
                    <svg class="w-5 h-5 text-gray-600" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"/></svg>
                    <span class="text-sm text-gray-500 capitalize">{{ feature.replace('_', ' ') }}</span>
                    {% endif %}
                </div>
                {% endfor %}
            </div>
        </div>
        
        <!-- Activations -->
        <div class="bg-dark-800 border border-dark-600 rounded-xl">
            <div class="p-4 border-b border-dark-600"><h2 class="font-semibold">Activations ({{ activations|length }})</h2></div>
            <div class="divide-y divide-dark-600">
                {% for activation in activations %}
                <div class="p-4 flex items-center justify-between">
                    <div>
                        <p class="font-medium">{{ activation.domain or activation.ip_address }}</p>
                        <p class="text-xs text-gray-500 mt-1">{{ activation.activated_at.strftime('%d %b %Y %H:%M') }}</p>
                    </div>
                    <span class="px-2 py-1 text-xs rounded-full {% if activation.is_active %}bg-green-500/20 text-green-400{% else %}bg-gray-500/20 text-gray-400{% endif %}">
                        {{ 'Active' if activation.is_active else 'Inactive' }}
                    </span>
                </div>
                {% else %}
                <p class="p-4 text-gray-500 text-sm">No activations yet</p>
                {% endfor %}
            </div>
        </div>
    </div>
    
    <!-- Sidebar -->
    <div class="space-y-6">
        <!-- Expiration -->
        <div class="bg-dark-800 border border-dark-600 rounded-xl p-6">
            <h2 class="font-semibold mb-4">Expiration</h2>
            {% if license.expires_at %}
                {% if license.is_expired %}
                <div class="text-center py-4">
                    <p class="text-red-400 text-2xl font-bold">EXPIRED</p>
                    <p class="text-gray-500 text-sm mt-1">{{ license.expires_at.strftime('%d %b %Y') }}</p>
                </div>
                {% else %}
                <div class="text-center py-4">
                    <p class="text-3xl font-bold text-green-400">{{ license.days_until_expiry }}</p>
                    <p class="text-gray-500 text-sm">days remaining</p>
                </div>
                {% endif %}
            {% else %}
            <div class="text-center py-4">
                <p class="text-2xl font-bold text-emerald-400">LIFETIME</p>
            </div>
            {% endif %}
            
            <form method="POST" action="{{ url_for('lic_admin.extend_license', id=license.id) }}" class="mt-4 flex gap-2">
                <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
                <select name="days" class="flex-1 px-3 py-2 bg-dark-700 border border-dark-500 rounded-lg text-sm">
                    <option value="30">+30 days</option>
                    <option value="90">+90 days</option>
                    <option value="365">+1 year</option>
                </select>
                <button type="submit" class="px-4 py-2 bg-emerald-600 hover:bg-emerald-700 text-white rounded-lg text-sm">Extend</button>
            </form>
        </div>
        
        <!-- Customer -->
        <div class="bg-dark-800 border border-dark-600 rounded-xl p-6">
            <h2 class="font-semibold mb-4">Customer</h2>
            {% if license.customer %}
            <p class="font-medium">{{ license.customer.company_name or 'No company' }}</p>
            <p class="text-sm text-gray-400">{{ license.customer.email }}</p>
            {% else %}
            <p class="text-gray-500 text-sm">No customer assigned</p>
            {% endif %}
        </div>
        
        <!-- Copy Key -->
        <div class="bg-dark-800 border border-dark-600 rounded-xl p-6">
            <h2 class="font-semibold mb-4">License Key</h2>
            <div class="bg-dark-900 rounded-lg p-3 font-mono text-sm break-all">{{ license.license_key }}</div>
            <button onclick="navigator.clipboard.writeText('{{ license.license_key }}')" class="w-full mt-3 px-4 py-2 bg-dark-700 hover:bg-dark-600 rounded-lg text-sm">Copy</button>
        </div>
    </div>
</div>
{% endblock %}
OPSLAB_LIC_EOF__7f2d8a5e

say "Writing app/licenses/templates/auth/login.html"
write_file 'app/licenses/templates/auth/login.html' << 'OPSLAB_LIC_EOF__7f2d8a5e'
{% extends "licenses/base.html" %}
{% block title %}Login - {{ site_name }}{% endblock %}
{% block auth_content %}
<div class="w-full max-w-md relative z-10">
    <div class="bg-dark-800/80 backdrop-blur-xl border border-dark-700/50 rounded-2xl p-8 shadow-2xl">
        <div class="text-center mb-8">
            <div class="w-16 h-16 bg-gradient-to-br from-{{ primary_color }}-400 to-{{ primary_color }}-600 rounded-2xl flex items-center justify-center mx-auto mb-4 shadow-lg shadow-{{ primary_color }}-500/25">
                <svg class="w-8 h-8 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 7a2 2 0 012 2m4 0a6 6 0 01-7.743 5.743L11 17H9v2H7v2H4a1 1 0 01-1-1v-2.586a1 1 0 01.293-.707l5.964-5.964A6 6 0 1121 9z"/>
                </svg>
            </div>
            <h1 class="text-2xl font-bold bg-gradient-to-r from-white to-gray-400 bg-clip-text text-transparent">{{ site_name }}</h1>
            <p class="text-gray-500 mt-1">{{ site_tagline }}</p>
        </div>
        
        {% with messages = get_flashed_messages(with_categories=true) %}
            {% if messages %}
                {% for category, message in messages %}
                <div class="mb-4 p-3 rounded-xl text-sm {% if category == 'error' %}bg-red-500/10 text-red-400 border border-red-500/20{% else %}bg-blue-500/10 text-blue-400 border border-blue-500/20{% endif %}">
                    {{ message }}
                </div>
                {% endfor %}
            {% endif %}
        {% endwith %}
        
        <form method="POST" class="space-y-5">
            <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
            
            <div>
                <label class="block text-sm font-medium text-gray-300 mb-2">Email</label>
                <input type="email" name="email" required autofocus
                    class="w-full px-4 py-3 bg-dark-700 border border-dark-600 rounded-xl text-white focus:outline-none focus:border-{{ primary_color }}-500 focus:ring-1 focus:ring-{{ primary_color }}-500/50 transition-colors"
                    placeholder="admin@example.com">
            </div>
            
            <div>
                <label class="block text-sm font-medium text-gray-300 mb-2">Password</label>
                <input type="password" name="password" required
                    class="w-full px-4 py-3 bg-dark-700 border border-dark-600 rounded-xl text-white focus:outline-none focus:border-{{ primary_color }}-500 focus:ring-1 focus:ring-{{ primary_color }}-500/50 transition-colors"
                    placeholder="••••••••">
            </div>
            
            <div class="flex items-center">
                <input type="checkbox" name="remember" id="remember" class="w-4 h-4 bg-dark-700 border-dark-600 rounded text-{{ primary_color }}-500 focus:ring-{{ primary_color }}-500">
                <label for="remember" class="ml-2 text-sm text-gray-400">Remember me</label>
            </div>
            
            <button type="submit" class="w-full py-3 bg-gradient-to-r from-{{ primary_color }}-500 to-{{ primary_color }}-600 hover:from-{{ primary_color }}-400 hover:to-{{ primary_color }}-500 text-white font-semibold rounded-xl shadow-lg shadow-{{ primary_color }}-500/25 transition-all duration-200">
                Sign In
            </button>
        </form>
        
        <p class="text-center text-gray-500 text-sm mt-6">
            {{ company_name }} &copy; 2026
        </p>
    </div>
</div>
{% endblock %}
OPSLAB_LIC_EOF__7f2d8a5e

say "Writing app/licenses/templates/customer/activate.html"
write_file 'app/licenses/templates/customer/activate.html' << 'OPSLAB_LIC_EOF__7f2d8a5e'
{% extends "customer/base.html" %}
{% block title %}Activate License - Customer Portal{% endblock %}

{% block body %}
<div class="min-h-screen">
    <header class="bg-dark-800 border-b border-dark-600">
        <div class="max-w-6xl mx-auto px-4 py-4 flex items-center gap-3">
            <a href="{{ url_for('lic_customer.dashboard') }}" class="text-gray-400 hover:text-white">
                <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 19l-7-7 7-7"/>
                </svg>
            </a>
            <span class="font-bold">Activate License</span>
        </div>
    </header>
    
    <main class="max-w-xl mx-auto px-4 py-12">
        {% with messages = get_flashed_messages(with_categories=true) %}
            {% if messages %}
                {% for category, message in messages %}
                <div class="mb-4 p-4 rounded-lg {% if category == 'error' %}bg-red-500/10 text-red-400{% else %}bg-green-500/10 text-green-400{% endif %}">
                    {{ message }}
                </div>
                {% endfor %}
            {% endif %}
        {% endwith %}
        
        <div class="bg-dark-800 border border-dark-600 rounded-xl p-8">
            <div class="text-center mb-6">
                <div class="w-16 h-16 bg-emerald-500/20 rounded-full flex items-center justify-center mx-auto mb-4">
                    <svg class="w-8 h-8 text-emerald-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 7a2 2 0 012 2m4 0a6 6 0 01-7.743 5.743L11 17H9v2H7v2H4a1 1 0 01-1-1v-2.586a1 1 0 01.293-.707l5.964-5.964A6 6 0 1121 9z"/>
                    </svg>
                </div>
                <h1 class="text-xl font-bold">Activate a License Key</h1>
                <p class="text-gray-500 mt-1">Enter your license key to add it to your account</p>
            </div>
            
            <form method="POST" class="space-y-4">
                <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
                <div>
                    <label class="block text-sm font-medium text-gray-300 mb-2">License Key</label>
                    <input type="text" name="license_key" required
                        class="w-full px-4 py-3 bg-dark-700 border border-dark-500 rounded-lg font-mono text-center text-lg tracking-wider focus:outline-none focus:border-emerald-500"
                        placeholder="XXXX-XXXX-XXXX-XXXX"
                        style="text-transform: uppercase;">
                </div>
                <button type="submit" class="w-full py-3 bg-emerald-600 hover:bg-emerald-700 text-white font-semibold rounded-lg">
                    Activate License
                </button>
            </form>
        </div>
    </main>
</div>
{% endblock %}
OPSLAB_LIC_EOF__7f2d8a5e

say "Writing app/licenses/templates/customer/base.html"
write_file 'app/licenses/templates/customer/base.html' << 'OPSLAB_LIC_EOF__7f2d8a5e'
<!DOCTYPE html>
<html lang="en" class="dark">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta name="csrf-token" content="{{ csrf_token() }}">
    <title>{% block title %}Customer Portal{% endblock %}</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <script>
        tailwind.config = {
            darkMode: 'class',
            theme: {
                extend: {
                    colors: {
                        dark: { 900: '#0a0a0a', 800: '#141414', 700: '#1f1f1f', 600: '#2a2a2a', 500: '#3a3a3a' }
                    }
                }
            }
        }
    </script>
</head>
<body class="bg-dark-900 text-gray-100 min-h-screen">
    {% block body %}{% endblock %}
</body>
</html>
OPSLAB_LIC_EOF__7f2d8a5e

say "Writing app/licenses/templates/customer/dashboard.html"
write_file 'app/licenses/templates/customer/dashboard.html' << 'OPSLAB_LIC_EOF__7f2d8a5e'
{% extends "customer/base.html" %}
{% block title %}My Licenses - Customer Portal{% endblock %}

{% block body %}
<div class="min-h-screen">
    <!-- Header -->
    <header class="bg-dark-800 border-b border-dark-600">
        <div class="max-w-6xl mx-auto px-4 py-4 flex items-center justify-between">
            <div class="flex items-center gap-3">
                <div class="w-10 h-10 bg-gradient-to-br from-emerald-500 to-teal-600 rounded-lg flex items-center justify-center">
                    <svg class="w-5 h-5 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 7a2 2 0 012 2m4 0a6 6 0 01-7.743 5.743L11 17H9v2H7v2H4a1 1 0 01-1-1v-2.586a1 1 0 01.293-.707l5.964-5.964A6 6 0 1121 9z"/>
                    </svg>
                </div>
                <span class="font-bold text-lg">License Manager</span>
            </div>
            <div class="flex items-center gap-4">
                <span class="text-sm text-gray-400">{{ customer.email }}</span>
                <a href="{{ url_for('lic_customer.profile') }}" class="text-sm text-gray-400 hover:text-white">Profile</a>
                <a href="{{ url_for('lic_customer.logout') }}" class="text-sm text-gray-400 hover:text-white">Logout</a>
            </div>
        </div>
    </header>
    
    <main class="max-w-6xl mx-auto px-4 py-8">
        {% with messages = get_flashed_messages(with_categories=true) %}
            {% if messages %}
                {% for category, message in messages %}
                <div class="mb-4 p-4 rounded-lg {% if category == 'error' %}bg-red-500/10 text-red-400 border border-red-500/20{% elif category == 'success' %}bg-green-500/10 text-green-400 border border-green-500/20{% else %}bg-blue-500/10 text-blue-400 border border-blue-500/20{% endif %}">
                    {{ message }}
                </div>
                {% endfor %}
            {% endif %}
        {% endwith %}
        
        <div class="flex items-center justify-between mb-6">
            <div>
                <h1 class="text-2xl font-bold">My Licenses</h1>
                <p class="text-gray-500">Manage your software licenses</p>
            </div>
            <a href="{{ url_for('lic_customer.activate_license') }}" class="px-4 py-2 bg-emerald-600 hover:bg-emerald-700 text-white rounded-lg">
                + Activate License
            </a>
        </div>
        
        {% if licenses %}
        <div class="grid gap-4">
            {% for license in licenses %}
            <a href="{{ url_for('lic_customer.view_license', id=license.id) }}" class="bg-dark-800 border border-dark-600 rounded-xl p-6 hover:border-dark-500 transition-colors">
                <div class="flex items-center justify-between">
                    <div class="flex items-center gap-4">
                        <div class="w-12 h-12 bg-dark-700 rounded-lg flex items-center justify-center">
                            <svg class="w-6 h-6 text-emerald-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 7a2 2 0 012 2m4 0a6 6 0 01-7.743 5.743L11 17H9v2H7v2H4a1 1 0 01-1-1v-2.586a1 1 0 01.293-.707l5.964-5.964A6 6 0 1121 9z"/>
                            </svg>
                        </div>
                        <div>
                            <p class="font-mono font-medium">{{ license.license_key }}</p>
                            <p class="text-sm text-gray-500">{{ license.product.name }} - {{ license.tier.name }}</p>
                        </div>
                    </div>
                    <div class="text-right">
                        <span class="px-3 py-1 rounded-full text-sm {% if license.is_valid %}bg-green-500/20 text-green-400{% elif license.is_expired %}bg-red-500/20 text-red-400{% else %}bg-yellow-500/20 text-yellow-400{% endif %}">
                            {% if license.is_valid %}Active{% elif license.is_expired %}Expired{% else %}{{ license.status|title }}{% endif %}
                        </span>
                        {% if license.expires_at %}
                        <p class="text-xs text-gray-500 mt-1">
                            {% if license.is_expired %}Expired {{ license.expires_at.strftime('%d %b %Y') }}{% else %}Expires in {{ license.days_until_expiry }} days{% endif %}
                        </p>
                        {% else %}
                        <p class="text-xs text-gray-500 mt-1">Lifetime</p>
                        {% endif %}
                    </div>
                </div>
                
                {% if license.product.require_ip_lock %}
                <div class="mt-4 pt-4 border-t border-dark-600">
                    <p class="text-xs text-gray-500 mb-2">Allowed IPs:</p>
                    <div class="flex flex-wrap gap-2">
                        {% for ip in (license.allowed_ips or []) %}
                        <span class="px-2 py-1 bg-dark-700 rounded text-xs font-mono">{{ ip }}</span>
                        {% else %}
                        <span class="text-xs text-yellow-400">No IPs configured - click to set up</span>
                        {% endfor %}
                    </div>
                </div>
                {% endif %}
            </a>
            {% endfor %}
        </div>
        {% else %}
        <div class="bg-dark-800 border border-dark-600 rounded-xl p-12 text-center">
            <div class="w-16 h-16 bg-dark-700 rounded-full flex items-center justify-center mx-auto mb-4">
                <svg class="w-8 h-8 text-gray-500" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 7a2 2 0 012 2m4 0a6 6 0 01-7.743 5.743L11 17H9v2H7v2H4a1 1 0 01-1-1v-2.586a1 1 0 01.293-.707l5.964-5.964A6 6 0 1121 9z"/>
                </svg>
            </div>
            <h2 class="text-xl font-semibold mb-2">No Licenses Yet</h2>
            <p class="text-gray-500 mb-6">Activate a license key to get started</p>
            <a href="{{ url_for('lic_customer.activate_license') }}" class="px-6 py-3 bg-emerald-600 hover:bg-emerald-700 text-white rounded-lg inline-block">
                Activate License Key
            </a>
        </div>
        {% endif %}
    </main>
</div>
{% endblock %}
OPSLAB_LIC_EOF__7f2d8a5e

say "Writing app/licenses/templates/customer/login.html"
write_file 'app/licenses/templates/customer/login.html' << 'OPSLAB_LIC_EOF__7f2d8a5e'
{% extends "customer/base.html" %}
{% block title %}Login - Customer Portal{% endblock %}

{% block body %}
<div class="min-h-screen flex items-center justify-center p-4">
    <div class="w-full max-w-md">
        <div class="bg-dark-800 border border-dark-600 rounded-2xl p-8">
            <div class="text-center mb-8">
                <div class="w-16 h-16 bg-gradient-to-br from-emerald-500 to-teal-600 rounded-2xl flex items-center justify-center mx-auto mb-4">
                    <svg class="w-8 h-8 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M16 7a4 4 0 11-8 0 4 4 0 018 0zM12 14a7 7 0 00-7 7h14a7 7 0 00-7-7z"/>
                    </svg>
                </div>
                <h1 class="text-2xl font-bold">Customer Portal</h1>
                <p class="text-gray-500 mt-1">Sign in to manage your licenses</p>
            </div>
            
            {% with messages = get_flashed_messages(with_categories=true) %}
                {% if messages %}
                    {% for category, message in messages %}
                    <div class="mb-4 p-3 rounded-lg text-sm {% if category == 'error' %}bg-red-500/10 text-red-400{% elif category == 'success' %}bg-green-500/10 text-green-400{% else %}bg-blue-500/10 text-blue-400{% endif %}">
                        {{ message }}
                    </div>
                    {% endfor %}
                {% endif %}
            {% endwith %}
            
            <form method="POST" class="space-y-4">
                <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
                <div>
                    <label class="block text-sm font-medium text-gray-300 mb-2">Email</label>
                    <input type="email" name="email" required
                        class="w-full px-4 py-3 bg-dark-700 border border-dark-500 rounded-lg focus:outline-none focus:border-emerald-500"
                        placeholder="you@example.com">
                </div>
                <div>
                    <label class="block text-sm font-medium text-gray-300 mb-2">Password</label>
                    <input type="password" name="password" required
                        class="w-full px-4 py-3 bg-dark-700 border border-dark-500 rounded-lg focus:outline-none focus:border-emerald-500"
                        placeholder="••••••••">
                </div>
                <button type="submit" class="w-full py-3 bg-gradient-to-r from-emerald-500 to-teal-600 hover:from-emerald-600 hover:to-teal-700 text-white font-semibold rounded-lg">
                    Sign In
                </button>
            </form>
            
            <div class="mt-6 text-center text-sm">
                <span class="text-gray-500">Don't have an account?</span>
                <a href="{{ url_for('lic_customer.register') }}" class="text-emerald-400 hover:text-emerald-300 ml-1">Register</a>
            </div>
            
            <div class="mt-4 text-center">
                <a href="/" class="text-gray-500 hover:text-gray-400 text-sm">← Back to Home</a>
            </div>
        </div>
    </div>
</div>
{% endblock %}
OPSLAB_LIC_EOF__7f2d8a5e

say "Writing app/licenses/templates/customer/profile.html"
write_file 'app/licenses/templates/customer/profile.html' << 'OPSLAB_LIC_EOF__7f2d8a5e'
{% extends "customer/base.html" %}
{% block title %}Profile - Customer Portal{% endblock %}

{% block body %}
<div class="min-h-screen">
    <header class="bg-dark-800 border-b border-dark-600">
        <div class="max-w-6xl mx-auto px-4 py-4 flex items-center gap-3">
            <a href="{{ url_for('lic_customer.dashboard') }}" class="text-gray-400 hover:text-white">
                <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 19l-7-7 7-7"/>
                </svg>
            </a>
            <span class="font-bold">Profile Settings</span>
        </div>
    </header>
    
    <main class="max-w-xl mx-auto px-4 py-8">
        {% with messages = get_flashed_messages(with_categories=true) %}
            {% if messages %}
                {% for category, message in messages %}
                <div class="mb-4 p-4 rounded-lg {% if category == 'error' %}bg-red-500/10 text-red-400{% else %}bg-green-500/10 text-green-400{% endif %}">
                    {{ message }}
                </div>
                {% endfor %}
            {% endif %}
        {% endwith %}
        
        <form method="POST" class="space-y-6">
            <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
            
            <div class="bg-dark-800 border border-dark-600 rounded-xl p-6 space-y-4">
                <h2 class="font-semibold">Account Information</h2>
                
                <div>
                    <label class="block text-sm text-gray-400 mb-1">Email</label>
                    <input type="email" value="{{ customer.email }}" disabled
                        class="w-full px-4 py-2 bg-dark-900 border border-dark-600 rounded-lg text-gray-500">
                </div>
                
                <div>
                    <label class="block text-sm text-gray-400 mb-1">Company Name</label>
                    <input type="text" name="company_name" value="{{ customer.company_name or '' }}"
                        class="w-full px-4 py-2 bg-dark-700 border border-dark-500 rounded-lg focus:outline-none focus:border-emerald-500">
                </div>
                
                <div>
                    <label class="block text-sm text-gray-400 mb-1">Contact Name</label>
                    <input type="text" name="contact_name" value="{{ customer.contact_name or '' }}"
                        class="w-full px-4 py-2 bg-dark-700 border border-dark-500 rounded-lg focus:outline-none focus:border-emerald-500">
                </div>
                
                <div>
                    <label class="block text-sm text-gray-400 mb-1">Phone</label>
                    <input type="text" name="phone" value="{{ customer.phone or '' }}"
                        class="w-full px-4 py-2 bg-dark-700 border border-dark-500 rounded-lg focus:outline-none focus:border-emerald-500">
                </div>
                
                <div>
                    <label class="block text-sm text-gray-400 mb-1">Address</label>
                    <textarea name="address" rows="2"
                        class="w-full px-4 py-2 bg-dark-700 border border-dark-500 rounded-lg focus:outline-none focus:border-emerald-500">{{ customer.address or '' }}</textarea>
                </div>
            </div>
            
            <div class="bg-dark-800 border border-dark-600 rounded-xl p-6 space-y-4">
                <h2 class="font-semibold">Change Password</h2>
                
                <div>
                    <label class="block text-sm text-gray-400 mb-1">Current Password</label>
                    <input type="password" name="current_password"
                        class="w-full px-4 py-2 bg-dark-700 border border-dark-500 rounded-lg focus:outline-none focus:border-emerald-500">
                </div>
                
                <div>
                    <label class="block text-sm text-gray-400 mb-1">New Password</label>
                    <input type="password" name="new_password"
                        class="w-full px-4 py-2 bg-dark-700 border border-dark-500 rounded-lg focus:outline-none focus:border-emerald-500"
                        placeholder="Leave blank to keep current">
                </div>
            </div>
            
            <button type="submit" class="w-full py-3 bg-emerald-600 hover:bg-emerald-700 text-white font-semibold rounded-lg">
                Save Changes
            </button>
        </form>
    </main>
</div>
{% endblock %}
OPSLAB_LIC_EOF__7f2d8a5e

say "Writing app/licenses/templates/customer/register.html"
write_file 'app/licenses/templates/customer/register.html' << 'OPSLAB_LIC_EOF__7f2d8a5e'
{% extends "customer/base.html" %}
{% block title %}Register - Customer Portal{% endblock %}

{% block body %}
<div class="min-h-screen flex items-center justify-center p-4">
    <div class="w-full max-w-md">
        <div class="bg-dark-800 border border-dark-600 rounded-2xl p-8">
            <div class="text-center mb-8">
                <h1 class="text-2xl font-bold">Create Account</h1>
                <p class="text-gray-500 mt-1">Register to manage your licenses</p>
            </div>
            
            {% with messages = get_flashed_messages(with_categories=true) %}
                {% if messages %}
                    {% for category, message in messages %}
                    <div class="mb-4 p-3 rounded-lg text-sm {% if category == 'error' %}bg-red-500/10 text-red-400{% else %}bg-green-500/10 text-green-400{% endif %}">
                        {{ message }}
                    </div>
                    {% endfor %}
                {% endif %}
            {% endwith %}
            
            <form method="POST" class="space-y-4">
                <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
                <div>
                    <label class="block text-sm font-medium text-gray-300 mb-2">Email *</label>
                    <input type="email" name="email" required
                        class="w-full px-4 py-3 bg-dark-700 border border-dark-500 rounded-lg focus:outline-none focus:border-emerald-500">
                </div>
                <div>
                    <label class="block text-sm font-medium text-gray-300 mb-2">Password *</label>
                    <input type="password" name="password" required minlength="8"
                        class="w-full px-4 py-3 bg-dark-700 border border-dark-500 rounded-lg focus:outline-none focus:border-emerald-500"
                        placeholder="Minimum 8 characters">
                </div>
                <div>
                    <label class="block text-sm font-medium text-gray-300 mb-2">Company Name</label>
                    <input type="text" name="company_name"
                        class="w-full px-4 py-3 bg-dark-700 border border-dark-500 rounded-lg focus:outline-none focus:border-emerald-500">
                </div>
                <div>
                    <label class="block text-sm font-medium text-gray-300 mb-2">Your Name</label>
                    <input type="text" name="contact_name"
                        class="w-full px-4 py-3 bg-dark-700 border border-dark-500 rounded-lg focus:outline-none focus:border-emerald-500">
                </div>
                <button type="submit" class="w-full py-3 bg-gradient-to-r from-emerald-500 to-teal-600 hover:from-emerald-600 hover:to-teal-700 text-white font-semibold rounded-lg">
                    Create Account
                </button>
            </form>
            
            <div class="mt-6 text-center text-sm">
                <span class="text-gray-500">Already have an account?</span>
                <a href="{{ url_for('lic_customer.login') }}" class="text-emerald-400 hover:text-emerald-300 ml-1">Sign In</a>
            </div>
        </div>
    </div>
</div>
{% endblock %}
OPSLAB_LIC_EOF__7f2d8a5e

say "Writing app/licenses/templates/customer/view_license.html"
write_file 'app/licenses/templates/customer/view_license.html' << 'OPSLAB_LIC_EOF__7f2d8a5e'
{% extends "customer/base.html" %}
{% block title %}{{ license.license_key }} - Customer Portal{% endblock %}

{% block body %}
<div class="min-h-screen">
    <header class="bg-dark-800 border-b border-dark-600">
        <div class="max-w-6xl mx-auto px-4 py-4 flex items-center justify-between">
            <div class="flex items-center gap-3">
                <a href="{{ url_for('lic_customer.dashboard') }}" class="text-gray-400 hover:text-white">
                    <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 19l-7-7 7-7"/>
                    </svg>
                </a>
                <span class="font-bold">License Details</span>
            </div>
            <a href="{{ url_for('lic_customer.logout') }}" class="text-sm text-gray-400 hover:text-white">Logout</a>
        </div>
    </header>
    
    <main class="max-w-6xl mx-auto px-4 py-8">
        {% with messages = get_flashed_messages(with_categories=true) %}
            {% if messages %}
                {% for category, message in messages %}
                <div class="mb-4 p-4 rounded-lg {% if category == 'error' %}bg-red-500/10 text-red-400 border border-red-500/20{% elif category == 'success' %}bg-green-500/10 text-green-400 border border-green-500/20{% else %}bg-blue-500/10 text-blue-400 border border-blue-500/20{% endif %}">
                    {{ message }}
                </div>
                {% endfor %}
            {% endif %}
        {% endwith %}
        
        <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
            <div class="lg:col-span-2 space-y-6">
                <!-- License Info -->
                <div class="bg-dark-800 border border-dark-600 rounded-xl p-6">
                    <div class="flex items-center justify-between mb-6">
                        <h2 class="text-lg font-semibold">License Information</h2>
                        <span class="px-3 py-1 rounded-full text-sm {% if license.is_valid %}bg-green-500/20 text-green-400{% else %}bg-red-500/20 text-red-400{% endif %}">
                            {{ license.status|upper }}
                        </span>
                    </div>
                    
                    <div class="bg-dark-900 rounded-lg p-4 mb-6">
                        <p class="text-xs text-gray-500 mb-1">License Key</p>
                        <p class="font-mono text-lg">{{ license.license_key }}</p>
                    </div>
                    
                    <div class="grid grid-cols-2 gap-4">
                        <div>
                            <p class="text-xs text-gray-500">Product</p>
                            <p class="font-medium">{{ license.product.name }}</p>
                        </div>
                        <div>
                            <p class="text-xs text-gray-500">Tier</p>
                            <p class="font-medium">{{ license.tier.name }}</p>
                        </div>
                        <div>
                            <p class="text-xs text-gray-500">Max Users</p>
                            <p class="font-medium">{{ license.tier.max_users or 'Unlimited' }}</p>
                        </div>
                        <div>
                            <p class="text-xs text-gray-500">Expires</p>
                            <p class="font-medium">{% if license.expires_at %}{{ license.expires_at.strftime('%d %b %Y') }}{% else %}Never{% endif %}</p>
                        </div>
                    </div>
                </div>
                
                <!-- IP Management -->
                {% if license.product.require_ip_lock %}
                <div class="bg-dark-800 border border-dark-600 rounded-xl p-6">
                    <div class="flex items-center justify-between mb-4">
                        <h2 class="text-lg font-semibold">IP Address Management</h2>
                        <span class="text-xs text-gray-500">Max {{ license.product.max_ip_addresses }} IPs allowed</span>
                    </div>
                    
                    <div class="bg-blue-500/10 border border-blue-500/20 rounded-lg p-4 mb-4">
                        <p class="text-sm text-blue-400">
                            <strong>Your current IP:</strong> <span class="font-mono">{{ current_ip }}</span>
                        </p>
                    </div>
                    
                    {% if license.allowed_ips %}
                    <div class="space-y-2 mb-4">
                        <p class="text-sm text-gray-400">Allowed IPs:</p>
                        {% for ip in license.allowed_ips %}
                        <div class="flex items-center justify-between bg-dark-700 rounded-lg px-4 py-3">
                            <span class="font-mono">{{ ip }}</span>
                            {% if can_change_ip %}
                            <form method="POST" action="{{ url_for('lic_customer.remove_ip', id=license.id) }}" class="inline">
                                <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
                                <input type="hidden" name="ip_address" value="{{ ip }}">
                                <button type="submit" class="text-red-400 hover:text-red-300 text-sm" onclick="return confirm('Remove this IP?')">Remove</button>
                            </form>
                            {% endif %}
                        </div>
                        {% endfor %}
                    </div>
                    {% else %}
                    <div class="bg-yellow-500/10 border border-yellow-500/20 rounded-lg p-4 mb-4">
                        <p class="text-sm text-yellow-400">No IPs configured. Your license will automatically lock to the first IP that activates it, or you can set it manually below.</p>
                    </div>
                    {% endif %}
                    
                    {% if can_change_ip %}
                        {% if (license.allowed_ips or [])|length < license.product.max_ip_addresses %}
                        <div class="flex gap-2 mb-4">
                            <form method="POST" action="{{ url_for('lic_customer.use_current_ip', id=license.id) }}" class="flex-1">
                                <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
                                <button type="submit" class="w-full px-4 py-2 bg-emerald-600 hover:bg-emerald-700 text-white rounded-lg">
                                    Use My Current IP ({{ current_ip }})
                                </button>
                            </form>
                        </div>
                        
                        <form method="POST" action="{{ url_for('lic_customer.add_ip', id=license.id) }}" class="flex gap-2">
                            <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
                            <input type="text" name="ip_address" placeholder="Or enter IP manually" 
                                class="flex-1 px-4 py-2 bg-dark-700 border border-dark-500 rounded-lg text-sm focus:outline-none focus:border-emerald-500">
                            <button type="submit" class="px-4 py-2 bg-dark-600 hover:bg-dark-500 rounded-lg text-sm">Add IP</button>
                        </form>
                        {% endif %}
                    {% else %}
                    <div class="bg-yellow-500/10 border border-yellow-500/20 rounded-lg p-4">
                        <p class="text-sm text-yellow-400">{{ change_message }}</p>
                    </div>
                    {% endif %}
                </div>
                {% endif %}
                
                <!-- Features -->
                <div class="bg-dark-800 border border-dark-600 rounded-xl p-6">
                    <h2 class="text-lg font-semibold mb-4">Included Features</h2>
                    <div class="grid grid-cols-2 gap-3">
                        {% for feature, enabled in (license.tier.features or {}).items() %}
                        <div class="flex items-center gap-2">
                            {% if enabled %}
                            <svg class="w-5 h-5 text-green-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7"/>
                            </svg>
                            <span class="capitalize">{{ feature.replace('_', ' ') }}</span>
                            {% else %}
                            <svg class="w-5 h-5 text-gray-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"/>
                            </svg>
                            <span class="text-gray-500 capitalize">{{ feature.replace('_', ' ') }}</span>
                            {% endif %}
                        </div>
                        {% endfor %}
                    </div>
                </div>
            </div>
            
            <!-- Sidebar -->
            <div class="space-y-6">
                <!-- Activations -->
                <div class="bg-dark-800 border border-dark-600 rounded-xl p-6">
                    <h2 class="font-semibold mb-4">Activations</h2>
                    <p class="text-2xl font-bold">{{ license.current_activations }}/{{ license.max_activations }}</p>
                    <p class="text-sm text-gray-500">active installations</p>
                    
                    {% if activations %}
                    <div class="mt-4 space-y-2">
                        {% for act in activations[:5] %}
                        <div class="text-sm p-2 bg-dark-700 rounded">
                            <p class="font-mono text-xs">{{ act.ip_address }}</p>
                            <p class="text-xs text-gray-500">{{ act.activated_at.strftime('%d %b %Y') }}</p>
                        </div>
                        {% endfor %}
                    </div>
                    {% endif %}
                </div>
                
                <!-- IP History -->
                {% if ip_history %}
                <div class="bg-dark-800 border border-dark-600 rounded-xl p-6">
                    <h2 class="font-semibold mb-4">IP Change History</h2>
                    <div class="space-y-2 text-sm">
                        {% for h in ip_history[:10] %}
                        <div class="flex items-center justify-between">
                            <span class="font-mono text-xs">{{ h.ip_address }}</span>
                            <span class="text-xs {% if h.action == 'added' %}text-green-400{% else %}text-red-400{% endif %}">{{ h.action }}</span>
                        </div>
                        {% endfor %}
                    </div>
                </div>
                {% endif %}
            </div>
        </div>
    </main>
</div>
{% endblock %}
OPSLAB_LIC_EOF__7f2d8a5e

say "Writing app/licenses/templates/errors/404.html"
write_file 'app/licenses/templates/errors/404.html' << 'OPSLAB_LIC_EOF__7f2d8a5e'
{% extends "licenses/base.html" %}
{% block title %}Page Not Found{% endblock %}

{% block content %}
<div class="flex items-center justify-center min-h-[60vh]">
    <div class="text-center">
        <p class="text-6xl font-bold text-gray-700">404</p>
        <h1 class="text-2xl font-bold mt-4">Page Not Found</h1>
        <p class="text-gray-500 mt-2">The page you're looking for doesn't exist.</p>
        <a href="{{ url_for('lic_admin.dashboard') }}" class="inline-block mt-6 px-4 py-2 bg-emerald-600 hover:bg-emerald-700 text-white rounded-lg">
            Go to Dashboard
        </a>
    </div>
</div>
{% endblock %}
OPSLAB_LIC_EOF__7f2d8a5e

say "Writing app/licenses/templates/errors/500.html"
write_file 'app/licenses/templates/errors/500.html' << 'OPSLAB_LIC_EOF__7f2d8a5e'
{% extends "licenses/base.html" %}
{% block title %}Server Error{% endblock %}

{% block content %}
<div class="flex items-center justify-center min-h-[60vh]">
    <div class="text-center">
        <p class="text-6xl font-bold text-gray-700">500</p>
        <h1 class="text-2xl font-bold mt-4">Server Error</h1>
        <p class="text-gray-500 mt-2">Something went wrong. Please try again later.</p>
        <a href="{{ url_for('lic_admin.dashboard') }}" class="inline-block mt-6 px-4 py-2 bg-emerald-600 hover:bg-emerald-700 text-white rounded-lg">
            Go to Dashboard
        </a>
    </div>
</div>
{% endblock %}
OPSLAB_LIC_EOF__7f2d8a5e

say "Writing app/licenses/templates/index.html"
write_file 'app/licenses/templates/index.html' << 'OPSLAB_LIC_EOF__7f2d8a5e'
<!DOCTYPE html>
<html lang="en" class="dark">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>License Manager</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <script>
        tailwind.config = {
            darkMode: 'class',
            theme: {
                extend: {
                    colors: {
                        dark: { 900: '#0a0a0a', 800: '#141414', 700: '#1f1f1f', 600: '#2a2a2a', 500: '#3a3a3a' }
                    }
                }
            }
        }
    </script>
</head>
<body class="bg-dark-900 text-gray-100 min-h-screen flex items-center justify-center">
    <div class="text-center max-w-2xl mx-auto px-6">
        <div class="w-20 h-20 bg-gradient-to-br from-emerald-500 to-teal-600 rounded-2xl flex items-center justify-center mx-auto mb-6">
            <svg class="w-10 h-10 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 7a2 2 0 012 2m4 0a6 6 0 01-7.743 5.743L11 17H9v2H7v2H4a1 1 0 01-1-1v-2.586a1 1 0 01.293-.707l5.964-5.964A6 6 0 1121 9z"/>
            </svg>
        </div>
        
        <h1 class="text-4xl font-bold mb-4">License Manager</h1>
        <p class="text-gray-400 mb-8">Manage software licenses, track activations, and control access</p>
        
        <div class="flex flex-col sm:flex-row gap-4 justify-center">
            <a href="/portal/login" class="px-8 py-3 bg-gradient-to-r from-emerald-500 to-teal-600 hover:from-emerald-600 hover:to-teal-700 text-white font-semibold rounded-xl transition-all">
                Customer Portal
            </a>
            <a href="/admin" class="px-8 py-3 bg-dark-700 hover:bg-dark-600 border border-dark-500 rounded-xl transition-all">
                Admin Login
            </a>
        </div>
        
        <div class="mt-12 grid grid-cols-1 sm:grid-cols-3 gap-6 text-left">
            <div class="bg-dark-800 border border-dark-600 rounded-xl p-5">
                <div class="w-10 h-10 bg-blue-500/20 rounded-lg flex items-center justify-center mb-3">
                    <svg class="w-5 h-5 text-blue-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 12l2 2 4-4m5.618-4.016A11.955 11.955 0 0112 2.944a11.955 11.955 0 01-8.618 3.04A12.02 12.02 0 003 9c0 5.591 3.824 10.29 9 11.622 5.176-1.332 9-6.03 9-11.622 0-1.042-.133-2.052-.382-3.016z"/>
                    </svg>
                </div>
                <h3 class="font-semibold mb-1">Secure Licensing</h3>
                <p class="text-sm text-gray-500">IP locking, domain validation, and hardware binding</p>
            </div>
            
            <div class="bg-dark-800 border border-dark-600 rounded-xl p-5">
                <div class="w-10 h-10 bg-purple-500/20 rounded-lg flex items-center justify-center mb-3">
                    <svg class="w-5 h-5 text-purple-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 19v-6a2 2 0 00-2-2H5a2 2 0 00-2 2v6a2 2 0 002 2h2a2 2 0 002-2zm0 0V9a2 2 0 012-2h2a2 2 0 012 2v10m-6 0a2 2 0 002 2h2a2 2 0 002-2m0 0V5a2 2 0 012-2h2a2 2 0 012 2v14a2 2 0 01-2 2h-2a2 2 0 01-2-2z"/>
                    </svg>
                </div>
                <h3 class="font-semibold mb-1">Usage Tracking</h3>
                <p class="text-sm text-gray-500">Monitor activations and track license usage in real-time</p>
            </div>
            
            <div class="bg-dark-800 border border-dark-600 rounded-xl p-5">
                <div class="w-10 h-10 bg-emerald-500/20 rounded-lg flex items-center justify-center mb-3">
                    <svg class="w-5 h-5 text-emerald-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M17 20h5v-2a3 3 0 00-5.356-1.857M17 20H7m10 0v-2c0-.656-.126-1.283-.356-1.857M7 20H2v-2a3 3 0 015.356-1.857M7 20v-2c0-.656.126-1.283.356-1.857m0 0a5.002 5.002 0 019.288 0M15 7a3 3 0 11-6 0 3 3 0 016 0z"/>
                    </svg>
                </div>
                <h3 class="font-semibold mb-1">Customer Portal</h3>
                <p class="text-sm text-gray-500">Self-service license management for your customers</p>
            </div>
        </div>
    </div>
</body>
</html>
OPSLAB_LIC_EOF__7f2d8a5e

say "Writing app/licenses/templates/licenses/base.html"
write_file 'app/licenses/templates/licenses/base.html' << 'OPSLAB_LIC_EOF__7f2d8a5e'
<!DOCTYPE html>
<html lang="en" class="dark">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta name="csrf-token" content="{{ csrf_token() }}">
    <title>{% block title %}{{ site_name }}{% endblock %}</title>
    
    <script src="https://cdn.tailwindcss.com"></script>
    <script>
        tailwind.config = {
            darkMode: 'class',
            theme: {
                extend: {
                    colors: {
                        dark: {
                            950: '#050505',
                            900: '#0a0a0a',
                            800: '#121212',
                            700: '#1a1a1a',
                            600: '#242424',
                            500: '#2e2e2e',
                            400: '#404040',
                        }
                    }
                }
            }
        }
    </script>
    <style>
        * { scrollbar-width: thin; scrollbar-color: #2e2e2e #121212; }
        .glass { background: rgba(18, 18, 18, 0.8); backdrop-filter: blur(12px); }
        .gradient-border { background: linear-gradient(135deg, #10b981 0%, #059669 100%); padding: 1px; }
        .gradient-border > * { background: #121212; }
        .shine { background: linear-gradient(135deg, transparent 0%, rgba(255,255,255,0.03) 50%, transparent 100%); }
        @keyframes pulse-slow { 0%, 100% { opacity: 1; } 50% { opacity: 0.7; } }
        .animate-pulse-slow { animation: pulse-slow 3s ease-in-out infinite; }
    </style>
</head>
<body class="bg-dark-950 text-gray-100 min-h-screen">
    {% if current_user.is_authenticated %}
    <div class="flex min-h-screen">
        <!-- Sidebar -->
        <aside class="w-72 bg-dark-900 border-r border-dark-700/50 flex flex-col shadow-2xl">
            <!-- Logo -->
            <div class="p-5 border-b border-dark-700/50">
                <div class="flex items-center gap-3">
                    <div class="w-11 h-11 bg-gradient-to-br from-{{ primary_color }}-400 to-{{ primary_color }}-600 rounded-xl flex items-center justify-center shadow-lg shadow-{{ primary_color }}-500/20">
                        <svg class="w-6 h-6 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 7a2 2 0 012 2m4 0a6 6 0 01-7.743 5.743L11 17H9v2H7v2H4a1 1 0 01-1-1v-2.586a1 1 0 01.293-.707l5.964-5.964A6 6 0 1121 9z"/>
                        </svg>
                    </div>
                    <div>
                        <span class="text-lg font-bold bg-gradient-to-r from-white to-gray-400 bg-clip-text text-transparent">{{ site_name }}</span>
                        <span class="block text-xs text-gray-500">{{ site_tagline }}</span>
                    </div>
                </div>
            </div>
            
            <!-- Navigation -->
            <nav class="flex-1 p-4 space-y-1.5 overflow-y-auto">
                <p class="px-3 py-2 text-xs font-semibold text-gray-500 uppercase tracking-wider">Main</p>
                
                <a href="{{ url_for('lic_admin.dashboard') }}" class="flex items-center gap-3 px-3 py-2.5 rounded-xl transition-all duration-200 {% if request.endpoint == 'admin.dashboard' %}bg-{{ primary_color }}-500/10 text-{{ primary_color }}-400 border border-{{ primary_color }}-500/20{% else %}text-gray-400 hover:bg-dark-700/50 hover:text-white{% endif %}">
                    <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M3 12l2-2m0 0l7-7 7 7M5 10v10a1 1 0 001 1h3m10-11l2 2m-2-2v10a1 1 0 01-1 1h-3m-6 0a1 1 0 001-1v-4a1 1 0 011-1h2a1 1 0 011 1v4a1 1 0 001 1m-6 0h6"/>
                    </svg>
                    <span class="font-medium">Dashboard</span>
                </a>
                
                <a href="{{ url_for('lic_admin.licenses') }}" class="flex items-center gap-3 px-3 py-2.5 rounded-xl transition-all duration-200 {% if 'license' in request.endpoint %}bg-{{ primary_color }}-500/10 text-{{ primary_color }}-400 border border-{{ primary_color }}-500/20{% else %}text-gray-400 hover:bg-dark-700/50 hover:text-white{% endif %}">
                    <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 7a2 2 0 012 2m4 0a6 6 0 01-7.743 5.743L11 17H9v2H7v2H4a1 1 0 01-1-1v-2.586a1 1 0 01.293-.707l5.964-5.964A6 6 0 1121 9z"/>
                    </svg>
                    <span class="font-medium">Licenses</span>
                </a>
                
                <a href="{{ url_for('lic_admin.customers') }}" class="flex items-center gap-3 px-3 py-2.5 rounded-xl transition-all duration-200 {% if 'customer' in request.endpoint %}bg-{{ primary_color }}-500/10 text-{{ primary_color }}-400 border border-{{ primary_color }}-500/20{% else %}text-gray-400 hover:bg-dark-700/50 hover:text-white{% endif %}">
                    <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M17 20h5v-2a3 3 0 00-5.356-1.857M17 20H7m10 0v-2c0-.656-.126-1.283-.356-1.857M7 20H2v-2a3 3 0 015.356-1.857M7 20v-2c0-.656.126-1.283.356-1.857m0 0a5.002 5.002 0 019.288 0M15 7a3 3 0 11-6 0 3 3 0 016 0z"/>
                    </svg>
                    <span class="font-medium">Customers</span>
                </a>
                
                <a href="{{ url_for('lic_admin.products') }}" class="flex items-center gap-3 px-3 py-2.5 rounded-xl transition-all duration-200 {% if 'product' in request.endpoint or 'tier' in request.endpoint %}bg-{{ primary_color }}-500/10 text-{{ primary_color }}-400 border border-{{ primary_color }}-500/20{% else %}text-gray-400 hover:bg-dark-700/50 hover:text-white{% endif %}">
                    <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M20 7l-8-4-8 4m16 0l-8 4m8-4v10l-8 4m0-10L4 7m8 4v10M4 7v10l8 4"/>
                    </svg>
                    <span class="font-medium">Products</span>
                </a>
                
                <a href="{{ url_for('lic_admin.features') }}" class="flex items-center gap-3 px-3 py-2.5 rounded-xl transition-all duration-200 {% if 'feature' in request.endpoint %}bg-{{ primary_color }}-500/10 text-{{ primary_color }}-400 border border-{{ primary_color }}-500/20{% else %}text-gray-400 hover:bg-dark-700/50 hover:text-white{% endif %}">
                    <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M11 4a2 2 0 114 0v1a1 1 0 001 1h3a1 1 0 011 1v3a1 1 0 01-1 1h-1a2 2 0 100 4h1a1 1 0 011 1v3a1 1 0 01-1 1h-3a1 1 0 01-1-1v-1a2 2 0 10-4 0v1a1 1 0 01-1 1H7a1 1 0 01-1-1v-3a1 1 0 00-1-1H4a2 2 0 110-4h1a1 1 0 001-1V7a1 1 0 011-1h3a1 1 0 001-1V4z"/>
                    </svg>
                    <span class="font-medium">Features</span>
                </a>

                <a href="{{ url_for('lic_admin.api_explorer') }}" class="flex items-center gap-3 px-3 py-2.5 rounded-xl transition-all duration-200 {% if 'api_explorer' in request.endpoint %}bg-{{ primary_color }}-500/10 text-{{ primary_color }}-400 border border-{{ primary_color }}-500/20{% else %}text-gray-400 hover:bg-dark-700/50 hover:text-white{% endif %}">
                    <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8 9l3 3-3 3m5 0h3M5 20h14a2 2 0 002-2V6a2 2 0 00-2-2H5a2 2 0 00-2 2v12a2 2 0 002 2z"/>
                    </svg>
                    <span class="font-medium">API Explorer</span>
                </a>
                
                <p class="px-3 py-2 mt-4 text-xs font-semibold text-gray-500 uppercase tracking-wider">Administration</p>
                
                <a href="{{ url_for('lic_admin.admin_users') }}" class="flex items-center gap-3 px-3 py-2.5 rounded-xl transition-all duration-200 {% if 'users' in request.endpoint %}bg-{{ primary_color }}-500/10 text-{{ primary_color }}-400 border border-{{ primary_color }}-500/20{% else %}text-gray-400 hover:bg-dark-700/50 hover:text-white{% endif %}">
                    <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4.354a4 4 0 110 5.292M15 21H3v-1a6 6 0 0112 0v1zm0 0h6v-1a6 6 0 00-9-5.197M13 7a4 4 0 11-8 0 4 4 0 018 0z"/>
                    </svg>
                    <span class="font-medium">Admin Users</span>
                </a>
                
                <a href="{{ url_for('lic_admin.roles') }}" class="flex items-center gap-3 px-3 py-2.5 rounded-xl transition-all duration-200 {% if 'role' in request.endpoint %}bg-{{ primary_color }}-500/10 text-{{ primary_color }}-400 border border-{{ primary_color }}-500/20{% else %}text-gray-400 hover:bg-dark-700/50 hover:text-white{% endif %}">
                    <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 12l2 2 4-4m5.618-4.016A11.955 11.955 0 0112 2.944a11.955 11.955 0 01-8.618 3.04A12.02 12.02 0 003 9c0 5.591 3.824 10.29 9 11.622 5.176-1.332 9-6.03 9-11.622 0-1.042-.133-2.052-.382-3.016z"/>
                    </svg>
                    <span class="font-medium">Roles & Permissions</span>
                </a>
                
                <a href="{{ url_for('lic_admin.settings') }}" class="flex items-center gap-3 px-3 py-2.5 rounded-xl transition-all duration-200 {% if 'settings' in request.endpoint %}bg-{{ primary_color }}-500/10 text-{{ primary_color }}-400 border border-{{ primary_color }}-500/20{% else %}text-gray-400 hover:bg-dark-700/50 hover:text-white{% endif %}">
                    <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 002.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 001.065 2.572c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 00-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 00-2.572 1.065c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 00-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 00-1.065-2.572c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 001.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z"/>
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"/>
                    </svg>
                    <span class="font-medium">Settings</span>
                </a>
                
                <a href="{{ url_for('lic_admin.activity_log') }}" class="flex items-center gap-3 px-3 py-2.5 rounded-xl transition-all duration-200 {% if 'activity' in request.endpoint %}bg-{{ primary_color }}-500/10 text-{{ primary_color }}-400 border border-{{ primary_color }}-500/20{% else %}text-gray-400 hover:bg-dark-700/50 hover:text-white{% endif %}">
                    <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 5H7a2 2 0 00-2 2v12a2 2 0 002 2h10a2 2 0 002-2V7a2 2 0 00-2-2h-2M9 5a2 2 0 002 2h2a2 2 0 002-2M9 5a2 2 0 012-2h2a2 2 0 012 2"/>
                    </svg>
                    <span class="font-medium">Activity Log</span>
                </a>
            </nav>
            
            <!-- User Section -->
            <div class="p-4 border-t border-dark-700/50">
                <!-- Session Timer -->
                <div class="mb-4 px-3 py-2.5 bg-dark-800 rounded-xl border border-dark-700/50">
                    <div class="flex items-center justify-between text-xs">
                        <span class="text-gray-500">Session</span>
                        <span id="sessionTimer" class="font-mono text-{{ primary_color }}-400 font-medium">00:{{ session_timeout }}</span>
                    </div>
                    <div class="mt-2 h-1 bg-dark-700 rounded-full overflow-hidden">
                        <div id="sessionBar" class="h-full bg-gradient-to-r from-{{ primary_color }}-400 to-{{ primary_color }}-600 transition-all duration-1000" style="width: 100%"></div>
                    </div>
                </div>
                
                <!-- User Profile -->
                <div class="flex items-center gap-3 p-2 rounded-xl hover:bg-dark-800 transition-colors">
                    <div class="w-10 h-10 bg-gradient-to-br from-{{ current_user.avatar_color }}-400 to-{{ current_user.avatar_color }}-600 rounded-xl flex items-center justify-center text-sm font-bold text-white shadow-lg">
                        {{ current_user.name[0] }}
                    </div>
                    <div class="flex-1 min-w-0">
                        <p class="text-sm font-semibold truncate">{{ current_user.name }}</p>
                        <p class="text-xs text-gray-500 truncate">{{ current_user.email }}</p>
                    </div>
                    <a href="{{ url_for('lic_auth.logout') }}" class="p-2 text-gray-500 hover:text-red-400 hover:bg-red-500/10 rounded-lg transition-colors" title="Logout">
                        <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M17 16l4-4m0 0l-4-4m4 4H7m6 4v1a3 3 0 01-3 3H6a3 3 0 01-3-3V7a3 3 0 013-3h4a3 3 0 013 3v1"/>
                        </svg>
                    </a>
                </div>
            </div>
        </aside>
        
        <!-- Main Content -->
        <main class="flex-1 overflow-auto bg-gradient-to-br from-dark-950 via-dark-900 to-dark-950">
            <div class="p-8">
                {% with messages = get_flashed_messages(with_categories=true) %}
                    {% if messages %}
                        {% for category, message in messages %}
                        <div class="mb-6 p-4 rounded-xl backdrop-blur-sm {% if category == 'error' %}bg-red-500/10 text-red-400 border border-red-500/20{% elif category == 'success' %}bg-{{ primary_color }}-500/10 text-{{ primary_color }}-400 border border-{{ primary_color }}-500/20{% elif category == 'warning' %}bg-yellow-500/10 text-yellow-400 border border-yellow-500/20{% else %}bg-blue-500/10 text-blue-400 border border-blue-500/20{% endif %}">
                            <div class="flex items-center gap-3">
                                {% if category == 'error' %}
                                <svg class="w-5 h-5 flex-shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4m0 4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>
                                {% elif category == 'success' %}
                                <svg class="w-5 h-5 flex-shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>
                                {% else %}
                                <svg class="w-5 h-5 flex-shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>
                                {% endif %}
                                <span>{{ message }}</span>
                            </div>
                        </div>
                        {% endfor %}
                    {% endif %}
                {% endwith %}
                
                {% block content %}{% endblock %}
            </div>
        </main>
    </div>
    
    <!-- Inactivity Timeout Script -->
    <script>
        (function() {
            const TIMEOUT_SECONDS = {{ session_timeout }};
            let timeLeft = TIMEOUT_SECONDS;
            let timerId;
            
            const timerEl = document.getElementById('sessionTimer');
            const barEl = document.getElementById('sessionBar');
            
            function formatTime(seconds) {
                const mins = Math.floor(seconds / 60);
                const secs = seconds % 60;
                return `${mins.toString().padStart(2, '0')}:${secs.toString().padStart(2, '0')}`;
            }
            
            function updateDisplay() {
                if (timerEl) timerEl.textContent = formatTime(timeLeft);
                if (barEl) barEl.style.width = (timeLeft / TIMEOUT_SECONDS * 100) + '%';
            }
            
            function tick() {
                timeLeft--;
                updateDisplay();
                if (timeLeft <= 0) {
                    clearInterval(timerId);
                    window.location.href = '{{ url_for("lic_auth.logout") }}';
                }
            }
            
            function resetTimer() {
                timeLeft = TIMEOUT_SECONDS;
                updateDisplay();
            }
            
            ['mousedown', 'mousemove', 'keydown', 'scroll', 'touchstart', 'click'].forEach(event => {
                document.addEventListener(event, resetTimer, { passive: true });
            });
            
            updateDisplay();
            timerId = setInterval(tick, 1000);
        })();
    </script>
    {% else %}
    <div class="min-h-screen flex items-center justify-center bg-gradient-to-br from-dark-950 via-dark-900 to-dark-950 p-4">
        <div class="absolute inset-0 overflow-hidden">
            <div class="absolute -top-40 -right-40 w-80 h-80 bg-{{ primary_color }}-500/10 rounded-full blur-3xl"></div>
            <div class="absolute -bottom-40 -left-40 w-80 h-80 bg-{{ primary_color }}-500/5 rounded-full blur-3xl"></div>
        </div>
        {% block auth_content %}{% endblock %}
    </div>
    {% endif %}
    
    <script>
        const csrfToken = document.querySelector('meta[name="csrf-token"]')?.getAttribute('content');
        if (csrfToken) {
            document.querySelectorAll('form').forEach(form => {
                if (!form.querySelector('input[name="csrf_token"]')) {
                    const input = document.createElement('input');
                    input.type = 'hidden';
                    input.name = 'csrf_token';
                    input.value = csrfToken;
                    form.appendChild(input);
                }
            });
        }
    </script>
</body>
</html>
OPSLAB_LIC_EOF__7f2d8a5e

say "Writing app/licenses/templates/licenses/landing.html"
write_file 'app/licenses/templates/licenses/landing.html' << 'OPSLAB_LIC_EOF__7f2d8a5e'
{% extends "licenses/base.html" %}
{% block title %}{{ site_name }} — Sign in{% endblock %}

{% block content %}
<div class="min-h-[60vh] flex items-center justify-center px-4">
  <div class="max-w-md w-full text-center">
    <div class="inline-flex w-16 h-16 mb-6 rounded-2xl bg-gradient-to-br from-{{ primary_color }}-500 to-{{ primary_color }}-700 items-center justify-center shadow-lg shadow-{{ primary_color }}-500/30">
      <svg class="w-8 h-8 text-white" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24">
        <path stroke-linecap="round" stroke-linejoin="round" d="M12 15v2m-6 4h12a2 2 0 002-2v-6a2 2 0 00-2-2H6a2 2 0 00-2 2v6a2 2 0 002 2zm10-10V7a4 4 0 00-8 0v4h8z"/>
      </svg>
    </div>

    <h1 class="text-3xl font-extrabold tracking-tight mb-2">{{ site_name }}</h1>
    <p class="text-gray-400 mb-8">{{ site_tagline }}</p>

    <div class="grid sm:grid-cols-2 gap-3">
      <a href="{{ url_for('lic_auth.login') }}"
         class="block p-5 rounded-xl bg-gray-800/50 border border-gray-700 hover:border-{{ primary_color }}-500/50 hover:bg-gray-800 transition group">
        <div class="text-xs font-bold uppercase tracking-widest text-{{ primary_color }}-400 mb-1">Staff</div>
        <div class="text-base font-bold text-white">Admin sign-in</div>
        <p class="text-xs text-gray-500 mt-1">Manage licenses, customers, and products</p>
      </a>

      <a href="{{ url_for('lic_customer.login') }}"
         class="block p-5 rounded-xl bg-gray-800/50 border border-gray-700 hover:border-{{ primary_color }}-500/50 hover:bg-gray-800 transition group">
        <div class="text-xs font-bold uppercase tracking-widest text-{{ primary_color }}-400 mb-1">Customers</div>
        <div class="text-base font-bold text-white">Customer portal</div>
        <p class="text-xs text-gray-500 mt-1">View and manage your licenses</p>
      </a>
    </div>

    <p class="text-[11px] text-gray-600 mt-6">
      Part of <a href="/" class="text-{{ primary_color }}-400 hover:text-{{ primary_color }}-300 underline">{{ company_name }}</a>
    </p>
  </div>
</div>
{% endblock %}
OPSLAB_LIC_EOF__7f2d8a5e

echo ""
# ─── 2. Patch app/__init__.py ───
say "Patching app/__init__.py"
python3 - "$TARGET/app/__init__.py" << 'OPSLAB_LIC_PATCHER_EOF__7f2d8a5e'
"""Patch app/__init__.py to mount /licenses/ under the OpsLabs Flask app.

Adds (idempotently):
  • import: from . import licenses
  • call:   licenses.register(app)            (after all other blueprints)
  • call:   licenses.seed_defaults()          (inside the seed block)
"""
import sys

path = sys.argv[1] if len(sys.argv) > 1 else "/root/opslabs/app/__init__.py"
with open(path) as f:
    src = f.read()
orig = src

# ─── 1. Import the licenses package ─────────────────────────────────
if "from . import licenses" not in src and "from app import licenses" not in src:
    # Insert near the other `from . import models_admin / admin_seeds` lines
    for anchor in [
        "from . import admin_seeds",
        "from . import models_admin",
        "from . import models",
    ]:
        idx = src.find(anchor)
        if idx >= 0:
            line_start = src.rfind("\n", 0, idx) + 1
            indent = src[line_start:idx]
            nl = src.find("\n", idx)
            if nl < 0:
                nl = len(src)
            src = (src[:nl + 1] +
                   f"{indent}from . import licenses\n" +
                   src[nl + 1:])
            break

# ─── 2. Register the blueprints ────────────────────────────────────
if "licenses.register(" not in src:
    # Anchor after the last app.register_blueprint() inside create_app()
    last = src.rfind("app.register_blueprint(")
    if last >= 0:
        # End of that line
        nl = src.find("\n", last)
        if nl < 0:
            nl = len(src)
        # Detect indent
        line_start = src.rfind("\n", 0, last) + 1
        indent = src[line_start:last]
        src = (src[:nl + 1] +
               f"\n{indent}# License Manager (/licenses/) — mounted as sub-package\n" +
               f"{indent}licenses.register(app)\n" +
               src[nl + 1:])

# ─── 3. Seed defaults ──────────────────────────────────────────────
if "licenses.seed_defaults()" not in src:
    # Anchor at the existing admin_seeds.seed_admin_defaults(db) line
    anchor = "admin_seeds.seed_admin_defaults(db)"
    idx = src.find(anchor)
    if idx >= 0:
        nl = src.find("\n", idx)
        line_start = src.rfind("\n", 0, idx) + 1
        indent = src[line_start:idx]
        if nl < 0:
            nl = len(src)
        src = (src[:nl + 1] +
               f"{indent}licenses.seed_defaults()\n" +
               src[nl + 1:])
    else:
        # Fallback: append a one-shot bootstrap before `return app`
        import re
        m = re.search(r"\n([ \t]+)return app\b", src)
        if m:
            indent = m.group(1)
            tail = (
                f"\n{indent}with app.app_context():\n"
                f"{indent}    try:\n"
                f"{indent}        db.create_all()\n"
                f"{indent}        licenses.seed_defaults()\n"
                f"{indent}    except Exception as _e:\n"
                f"{indent}        app.logger.warning(f\"license seed failed: {{_e}}\")\n"
            )
            src = src[:m.start()] + tail + src[m.start():]

if src != orig:
    with open(path, "w") as f:
        f.write(src)
    print("patched")
else:
    print("already-patched")
OPSLAB_LIC_PATCHER_EOF__7f2d8a5e

echo ""
# ─── 3. Restart Flask ───
say "Restarting opslabs-app"
sudo systemctl restart opslabs-app || warn "Failed to restart opslabs-app"
sleep 3

if systemctl is-active --quiet opslabs-app; then
    printf "    %s✓%s opslabs-app — %sactive%s\n" "$GREEN" "$RESET" "$GREEN" "$RESET"
else
    printf "    %s✗%s opslabs-app — %sFAILED%s\n" "$RED" "$RESET" "$RED" "$RESET"
    warn "  Logs: sudo journalctl -u opslabs-app -n 50 --no-pager"
    exit 1
fi

echo ""
say "Done."
echo ""
printf "%sLicense Manager URLs:%s\n" "$GREEN" "$RESET"
printf "  %s/licenses/%s              landing page\n"      "$DIM" "$RESET"
printf "  %s/licenses/auth/login%s    admin login\n"        "$DIM" "$RESET"
printf "  %s/licenses/admin/%s        admin dashboard\n"    "$DIM" "$RESET"
printf "  %s/licenses/portal/%s       customer portal\n"    "$DIM" "$RESET"
printf "  %s/licenses/api/...%s       validation API\n"     "$DIM" "$RESET"
echo ""
printf "%sDefault admin login%s — %sCHANGE THIS%s after first sign-in:\n" "$YELLOW" "$RESET" "$RED" "$RESET"
printf "  email:    admin@example.com\n"
printf "  password: admin123\n"
echo ""
echo "Backups in $BACKUP_DIR"
echo "Restore:  cp -r \"$BACKUP_DIR/.\" \"$TARGET/\" && sudo systemctl restart opslabs-app"
