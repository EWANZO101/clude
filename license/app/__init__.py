"""
License Manager - Application Factory
"""
from flask import Flask, render_template
from flask_sqlalchemy import SQLAlchemy
from flask_login import LoginManager
from flask_wtf.csrf import CSRFProtect
from config import Config

db = SQLAlchemy()
login_manager = LoginManager()
login_manager.login_view = 'auth.login'
csrf = CSRFProtect()


def create_app(config_class=Config):
    app = Flask(__name__)
    app.config.from_object(config_class)
    
    db.init_app(app)
    login_manager.init_app(app)
    csrf.init_app(app)
    
    from app.models import AdminUser
    
    @login_manager.user_loader
    def load_user(user_id):
        if isinstance(user_id, str) and '_' in user_id:
            try:
                user_id = int(user_id.split('_')[1])
            except:
                return None
        return AdminUser.query.get(int(user_id))
    
    # Context processor for settings
    @app.context_processor
    def inject_settings():
        from app.models import Settings
        return {
            'site_name': Settings.get('site_name', 'License Manager'),
            'site_tagline': Settings.get('site_tagline', 'Admin Panel'),
            'company_name': Settings.get('company_name', 'Your Company'),
            'primary_color': Settings.get('primary_color', 'emerald'),
            'session_timeout': Settings.get('session_timeout', '30'),
        }
    
    # Blueprints
    from app.auth import bp as auth_bp
    app.register_blueprint(auth_bp, url_prefix='/auth')
    
    from app.admin import bp as admin_bp
    app.register_blueprint(admin_bp, url_prefix='/admin')
    
    from app.customer import bp as customer_bp
    app.register_blueprint(customer_bp, url_prefix='/portal')
    
    from app.api import bp as api_bp
    app.register_blueprint(api_bp, url_prefix='/api')
    csrf.exempt(api_bp)
    
    @app.route('/')
    def index():
        return render_template('index.html')
    
    with app.app_context():
        db.create_all()
        seed_data()
    
    @app.errorhandler(404)
    def not_found(e):
        return render_template('errors/404.html'), 404
    
    @app.errorhandler(500)
    def server_error(e):
        return render_template('errors/500.html'), 500
    
    return app


def seed_data():
    from app.models import AdminUser, Product, ProductTier, Settings, Role, Permission
    
    # Seed default settings
    default_settings = [
        ('site_name', 'License Manager', 'Site name displayed in header', 'branding'),
        ('site_tagline', 'Admin Panel', 'Tagline shown below site name', 'branding'),
        ('company_name', 'Your Company', 'Company name for branding', 'branding'),
        ('primary_color', 'emerald', 'Primary theme color (emerald, blue, purple, rose)', 'appearance'),
        ('session_timeout', '30', 'Session timeout in seconds', 'security'),
        ('require_2fa', 'false', 'Require two-factor authentication', 'security'),
        ('allow_registration', 'true', 'Allow customer self-registration', 'customers'),
        ('default_license_duration', '365', 'Default license duration in days', 'licenses'),
        ('max_activations_default', '1', 'Default max activations for new licenses', 'licenses'),
        ('admin_api_key', '', 'API key for the management API (leave blank to disable). Use a long random string.', 'api'),
    ]
    
    for key, value, desc, category in default_settings:
        if not Settings.query.filter_by(key=key).first():
            db.session.add(Settings(key=key, value=value, description=desc, category=category))
    
    # Seed permissions
    default_permissions = [
        ('licenses.view', 'View Licenses', 'View license list and details', 'licenses'),
        ('licenses.create', 'Create Licenses', 'Create new licenses', 'licenses'),
        ('licenses.edit', 'Edit Licenses', 'Edit license details', 'licenses'),
        ('licenses.delete', 'Delete Licenses', 'Delete licenses', 'licenses'),
        ('licenses.manage_ips', 'Manage IPs', 'Manage license IP addresses', 'licenses'),
        ('customers.view', 'View Customers', 'View customer list and details', 'customers'),
        ('customers.create', 'Create Customers', 'Create new customers', 'customers'),
        ('customers.edit', 'Edit Customers', 'Edit customer details', 'customers'),
        ('customers.delete', 'Delete Customers', 'Delete customers', 'customers'),
        ('products.view', 'View Products', 'View products and tiers', 'products'),
        ('products.create', 'Create Products', 'Create new products', 'products'),
        ('products.edit', 'Edit Products', 'Edit product details', 'products'),
        ('products.delete', 'Delete Products', 'Delete products', 'products'),
        ('roles.view', 'View Roles', 'View roles and permissions', 'admin'),
        ('roles.manage', 'Manage Roles', 'Create, edit, delete roles', 'admin'),
        ('users.view', 'View Users', 'View admin users', 'admin'),
        ('users.manage', 'Manage Users', 'Create, edit, delete admin users', 'admin'),
        ('settings.view', 'View Settings', 'View system settings', 'admin'),
        ('settings.edit', 'Edit Settings', 'Modify system settings', 'admin'),
        ('activity.view', 'View Activity', 'View activity logs', 'admin'),
    ]
    
    for code, name, desc, category in default_permissions:
        if not Permission.query.filter_by(code=code).first():
            db.session.add(Permission(code=code, name=name, description=desc, category=category))
    
    db.session.flush()
    
    # Seed default roles
    if not Role.query.filter_by(name='Super Admin').first():
        role = Role(name='Super Admin', description='Full system access', color='red', is_system=True)
        role.permissions = Permission.query.all()
        db.session.add(role)
    
    if not Role.query.filter_by(name='Manager').first():
        role = Role(name='Manager', description='Manage licenses and customers', color='blue', is_system=False)
        manager_perms = ['licenses.view', 'licenses.create', 'licenses.edit', 'licenses.manage_ips',
                        'customers.view', 'customers.create', 'customers.edit', 'products.view', 'activity.view']
        role.permissions = Permission.query.filter(Permission.code.in_(manager_perms)).all()
        db.session.add(role)
    
    if not Role.query.filter_by(name='Viewer').first():
        role = Role(name='Viewer', description='View-only access', color='gray', is_system=False)
        viewer_perms = ['licenses.view', 'customers.view', 'products.view', 'activity.view']
        role.permissions = Permission.query.filter(Permission.code.in_(viewer_perms)).all()
        db.session.add(role)
    
    # Seed admin user
    if not AdminUser.query.filter_by(email='admin@example.com').first():
        admin = AdminUser(email='admin@example.com', name='Administrator', is_superadmin=True)
        admin.set_password('admin123')
        db.session.add(admin)
    
    # Seed default product
    if not Product.query.filter_by(code='STAFF_SCHEDULER').first():
        product = Product(
            name='Staff Scheduler',
            code='STAFF_SCHEDULER',
            description='Complete staff scheduling and management system',
            require_ip_lock=True,
            max_ip_addresses=2,
            allow_ip_change=True,
            ip_change_cooldown=24
        )
        db.session.add(product)
        db.session.flush()
        
        tiers = [
            {'name': 'Starter', 'code': 'starter', 'price_monthly': 0, 'price_yearly': 0, 'max_users': 5,
             'features': {'schedule': True}, 'sort_order': 1},
            {'name': 'Basic', 'code': 'basic', 'price_monthly': 29, 'price_yearly': 290, 'max_users': 25,
             'features': {'schedule': True, 'leave': True, 'tasks': True, 'board': True}, 'sort_order': 2},
            {'name': 'Professional', 'code': 'pro', 'price_monthly': 79, 'price_yearly': 790, 'max_users': 100,
             'features': {'schedule': True, 'leave': True, 'tasks': True, 'board': True, 'finance': True, 'reports': True}, 'sort_order': 3},
            {'name': 'Enterprise', 'code': 'enterprise', 'price_monthly': 199, 'price_yearly': 1990, 'max_users': 0,
             'features': {'schedule': True, 'leave': True, 'tasks': True, 'board': True, 'finance': True, 'reports': True, 'api_access': True, 'white_label': True}, 'sort_order': 4},
        ]
        
        for tier_data in tiers:
            db.session.add(ProductTier(product_id=product.id, **tier_data))
    
    db.session.commit()

    # Seed default CAD features
    from app.models import Feature
    default_features = [
        ('dispatch',      'Dispatch',          'Live dispatch board and unit management',   'cad'),
        ('mdt',           'MDT',               'Mobile Data Terminal access',               'cad'),
        ('citizens',      'Citizens',          'Citizen record management',                 'cad'),
        ('vehicle_lookup','Vehicle Lookup',    'Vehicle registration & lookup',             'cad'),
        ('reports',       'Reports',           'Incident and arrest reports',               'cad'),
        ('admin_panel',   'Admin Panel',       'System administration access',              'admin'),
        ('api_access',    'API Access',        'External API access',                       'admin'),
        ('white_label',   'White Label',       'Custom branding options',                   'admin'),
        ('finance',       'Finance',           'Finance and billing module',                'billing'),
        ('schedule',      'Scheduling',        'Staff scheduling module',                   'hr'),
        ('leave',         'Leave Management',  'Leave requests and approvals',              'hr'),
        ('tasks',         'Task Manager',      'Task tracking and assignment',              'hr'),
        ('board',         'Board View',        'Kanban/board view for tasks',              'hr'),
    ]
    for code, name, desc, cat in default_features:
        if not Feature.query.filter_by(code=code).first():
            db.session.add(Feature(code=code, name=name, description=desc, category=cat))
    db.session.commit()
