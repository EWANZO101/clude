from datetime import datetime
from app.extensions import db


class Role(db.Model):
    __tablename__ = "roles"
    id = db.Column(db.Integer, primary_key=True)
    key = db.Column(db.String(80), unique=True, nullable=False)
    label = db.Column(db.String(120), nullable=False)


class Permission(db.Model):
    __tablename__ = "permissions"
    id = db.Column(db.Integer, primary_key=True)
    key = db.Column(db.String(120), unique=True, nullable=False)
    module_id = db.Column(db.String(80), nullable=True)
    label = db.Column(db.String(200))


class RolePermission(db.Model):
    __tablename__ = "role_permissions"
    id = db.Column(db.Integer, primary_key=True)
    role_id = db.Column(db.Integer, db.ForeignKey("roles.id"), nullable=False)
    permission_id = db.Column(db.Integer, db.ForeignKey("permissions.id"), nullable=False)


class UserRole(db.Model):
    __tablename__ = "user_roles"
    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.String(36), db.ForeignKey("users.id"), nullable=False, index=True)
    role_id = db.Column(db.Integer, db.ForeignKey("roles.id"), nullable=False)
    granted_at = db.Column(db.DateTime, default=datetime.utcnow)


class ModulePermissionGrant(db.Model):
    """A permission a module requested and the user approved on install."""
    __tablename__ = "module_permission_grants"
    id = db.Column(db.Integer, primary_key=True)
    module_id = db.Column(db.String(80), nullable=False, index=True)
    permission_key = db.Column(db.String(120), nullable=False)
    granted = db.Column(db.Boolean, default=True)
    granted_at = db.Column(db.DateTime, default=datetime.utcnow)
