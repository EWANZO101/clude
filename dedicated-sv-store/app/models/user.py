import enum
import secrets
from datetime import timedelta

from flask_login import UserMixin
from werkzeug.security import generate_password_hash, check_password_hash

from app.extensions import db
from app.models.base import TimestampMixin, utcnow


class AccountType(str, enum.Enum):
    CUSTOMER = "customer"
    SELLER = "seller"
    STAFF = "staff"
    ADMIN = "admin"


class Permission(db.Model, TimestampMixin):
    __tablename__ = "permissions"

    id = db.Column(db.Integer, primary_key=True)
    code = db.Column(db.String(100), unique=True, nullable=False, index=True)
    category = db.Column(db.String(50), nullable=False)
    description = db.Column(db.String(255))

    def __repr__(self):
        return f"<Permission {self.code}>"


class Role(db.Model, TimestampMixin):
    __tablename__ = "roles"

    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(80), unique=True, nullable=False)
    description = db.Column(db.String(255))
    is_system = db.Column(db.Boolean, default=False, nullable=False)

    permissions = db.relationship(
        "RolePermission", back_populates="role", cascade="all, delete-orphan"
    )
    user_roles = db.relationship(
        "UserRole", back_populates="role", cascade="all, delete-orphan"
    )

    def __repr__(self):
        return f"<Role {self.name}>"

    @property
    def permission_codes(self):
        return {rp.permission.code for rp in self.permissions}


class RolePermission(db.Model):
    __tablename__ = "role_permissions"

    id = db.Column(db.Integer, primary_key=True)
    role_id = db.Column(db.Integer, db.ForeignKey("roles.id"), nullable=False)
    permission_id = db.Column(
        db.Integer, db.ForeignKey("permissions.id"), nullable=False
    )
    granted_at = db.Column(db.DateTime(timezone=True), default=utcnow, nullable=False)

    role = db.relationship("Role", back_populates="permissions")
    permission = db.relationship("Permission")

    __table_args__ = (
        db.UniqueConstraint("role_id", "permission_id", name="uq_role_permission"),
    )


class User(db.Model, TimestampMixin, UserMixin):
    __tablename__ = "users"

    id = db.Column(db.Integer, primary_key=True)
    email = db.Column(db.String(255), unique=True, nullable=False, index=True)
    password_hash = db.Column(db.String(255), nullable=False)

    first_name = db.Column(db.String(100))
    last_name = db.Column(db.String(100))
    phone = db.Column(db.String(30))

    account_type = db.Column(
        db.Enum(AccountType, name="account_type"),
        nullable=False,
        default=AccountType.CUSTOMER,
    )

    is_active = db.Column(db.Boolean, default=True, nullable=False)
    is_email_verified = db.Column(db.Boolean, default=False, nullable=False)
    email_verified_at = db.Column(db.DateTime(timezone=True))

    last_login_at = db.Column(db.DateTime(timezone=True))
    last_login_ip = db.Column(db.String(45))
    failed_login_attempts = db.Column(db.Integer, default=0, nullable=False)
    locked_until = db.Column(db.DateTime(timezone=True))

    two_factor_enabled = db.Column(db.Boolean, default=False, nullable=False)
    two_factor_secret = db.Column(db.String(64))

    user_roles = db.relationship(
        "UserRole",
        back_populates="user",
        cascade="all, delete-orphan",
        foreign_keys="UserRole.user_id",
    )
    customer_profile = db.relationship(
        "CustomerProfile", back_populates="user", uselist=False,
        cascade="all, delete-orphan",
    )
    seller_profile = db.relationship(
        "SellerProfile", back_populates="user", uselist=False,
        cascade="all, delete-orphan",
    )

    def set_password(self, raw_password):
        self.password_hash = generate_password_hash(raw_password)

    def check_password(self, raw_password):
        return check_password_hash(self.password_hash, raw_password)

    @property
    def full_name(self):
        parts = [p for p in (self.first_name, self.last_name) if p]
        return " ".join(parts) or self.email

    @property
    def roles(self):
        return [ur.role for ur in self.user_roles]

    def has_role(self, role_name):
        return any(r.name == role_name for r in self.roles)

    def has_permission(self, code):
        if self.account_type == AccountType.ADMIN and self.has_role("Super Admin"):
            return True
        for role in self.roles:
            if code in role.permission_codes:
                return True
        return False

    def is_locked(self):
        return bool(self.locked_until and self.locked_until > utcnow())

    def register_failed_login(self, max_attempts=5, lockout_minutes=15):
        self.failed_login_attempts = (self.failed_login_attempts or 0) + 1
        if self.failed_login_attempts >= max_attempts:
            self.locked_until = utcnow() + timedelta(minutes=lockout_minutes)

    def register_successful_login(self, ip=None):
        self.failed_login_attempts = 0
        self.locked_until = None
        self.last_login_at = utcnow()
        self.last_login_ip = ip

    def __repr__(self):
        return f"<User {self.email}>"


class UserRole(db.Model):
    __tablename__ = "user_roles"

    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False)
    role_id = db.Column(db.Integer, db.ForeignKey("roles.id"), nullable=False)
    granted_at = db.Column(db.DateTime(timezone=True), default=utcnow, nullable=False)
    granted_by_id = db.Column(db.Integer, db.ForeignKey("users.id"))

    user = db.relationship("User", back_populates="user_roles", foreign_keys=[user_id])
    role = db.relationship("Role", back_populates="user_roles")
    granted_by = db.relationship("User", foreign_keys=[granted_by_id])

    __table_args__ = (
        db.UniqueConstraint("user_id", "role_id", name="uq_user_role"),
    )


def _make_token():
    return secrets.token_urlsafe(48)


class EmailVerificationToken(db.Model):
    __tablename__ = "email_verification_tokens"

    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False)
    token = db.Column(db.String(128), unique=True, default=_make_token, nullable=False)
    created_at = db.Column(db.DateTime(timezone=True), default=utcnow, nullable=False)
    expires_at = db.Column(db.DateTime(timezone=True), nullable=False)
    used_at = db.Column(db.DateTime(timezone=True))

    user = db.relationship("User")

    def is_valid(self):
        return self.used_at is None and self.expires_at > utcnow()


class PasswordResetToken(db.Model):
    __tablename__ = "password_reset_tokens"

    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False)
    token = db.Column(db.String(128), unique=True, default=_make_token, nullable=False)
    created_at = db.Column(db.DateTime(timezone=True), default=utcnow, nullable=False)
    expires_at = db.Column(db.DateTime(timezone=True), nullable=False)
    used_at = db.Column(db.DateTime(timezone=True))
    requested_ip = db.Column(db.String(45))

    user = db.relationship("User")

    def is_valid(self):
        return self.used_at is None and self.expires_at > utcnow()
