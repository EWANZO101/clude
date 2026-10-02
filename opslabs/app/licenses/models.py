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
    
    roles = db.relationship('app.licenses.models.Role', secondary=user_roles, backref='users')
    
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
