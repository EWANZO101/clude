import uuid
import secrets
from datetime import datetime, timedelta

from flask_login import UserMixin
from werkzeug.security import generate_password_hash, check_password_hash

from app.extensions import db


def gen_uuid():
    return str(uuid.uuid4())


class User(db.Model, UserMixin):
    __tablename__ = "users"

    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    name = db.Column(db.String(120), nullable=False)
    email = db.Column(db.String(255), unique=True, nullable=False, index=True)
    password_hash = db.Column(db.String(255), nullable=False)

    country = db.Column(db.String(80))
    currency = db.Column(db.String(10), default="GBP")
    timezone = db.Column(db.String(80), default="Europe/London")
    date_format = db.Column(db.String(20), default="DD/MM/YYYY")
    number_format = db.Column(db.String(20), default="1,234.56")
    first_day_of_week = db.Column(db.String(10), default="monday")

    theme = db.Column(db.String(20), default="dark")
    accent_colour = db.Column(db.String(20), default="emerald")
    dashboard_density = db.Column(db.String(20), default="comfortable")

    email_verified = db.Column(db.Boolean, default=False)
    two_factor_enabled = db.Column(db.Boolean, default=False)
    two_factor_secret = db.Column(db.String(64))

    setup_complete = db.Column(db.Boolean, default=False)

    is_active_account = db.Column(db.Boolean, default=True)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    updated_at = db.Column(db.DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)

    sessions = db.relationship("UserSession", backref="user", lazy="dynamic", cascade="all, delete-orphan")
    login_events = db.relationship("LoginHistory", backref="user", lazy="dynamic", cascade="all, delete-orphan")

    def set_password(self, password):
        self.password_hash = generate_password_hash(password)

    def check_password(self, password):
        return check_password_hash(self.password_hash, password)

    @property
    def is_active(self):
        return self.is_active_account

    def get_id(self):
        return self.id


class UserSession(db.Model):
    __tablename__ = "sessions"

    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    user_id = db.Column(db.String(36), db.ForeignKey("users.id"), nullable=False, index=True)
    session_token = db.Column(db.String(128), unique=True, nullable=False, default=lambda: secrets.token_hex(32))
    ip_address = db.Column(db.String(64))
    user_agent = db.Column(db.String(255))
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    last_active_at = db.Column(db.DateTime, default=datetime.utcnow)
    expires_at = db.Column(db.DateTime, default=lambda: datetime.utcnow() + timedelta(days=30))
    revoked = db.Column(db.Boolean, default=False)


class LoginHistory(db.Model):
    __tablename__ = "login_history"

    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.String(36), db.ForeignKey("users.id"), nullable=False, index=True)
    ip_address = db.Column(db.String(64))
    user_agent = db.Column(db.String(255))
    success = db.Column(db.Boolean, default=True)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)


class PasswordResetToken(db.Model):
    __tablename__ = "password_reset_tokens"

    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.String(36), db.ForeignKey("users.id"), nullable=False, index=True)
    token = db.Column(db.String(128), unique=True, nullable=False, default=lambda: secrets.token_urlsafe(48))
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    expires_at = db.Column(db.DateTime, default=lambda: datetime.utcnow() + timedelta(hours=2))
    used = db.Column(db.Boolean, default=False)


class EmailVerificationToken(db.Model):
    __tablename__ = "email_verification_tokens"

    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.String(36), db.ForeignKey("users.id"), nullable=False, index=True)
    token = db.Column(db.String(128), unique=True, nullable=False, default=lambda: secrets.token_urlsafe(48))
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    expires_at = db.Column(db.DateTime, default=lambda: datetime.utcnow() + timedelta(hours=24))
    used = db.Column(db.Boolean, default=False)


class Setting(db.Model):
    """Central key/value settings store. user_id NULL = global setting."""
    __tablename__ = "settings"

    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.String(36), db.ForeignKey("users.id"), nullable=True, index=True)
    key = db.Column(db.String(120), nullable=False, index=True)
    value = db.Column(db.Text)
    updated_at = db.Column(db.DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)

    __table_args__ = (db.UniqueConstraint("user_id", "key", name="uq_settings_user_key"),)


class DashboardWidget(db.Model):
    """Per-user configured dashboard widget layout."""
    __tablename__ = "dashboard_widgets"

    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.String(36), db.ForeignKey("users.id"), nullable=False, index=True)
    widget_key = db.Column(db.String(80), nullable=False)
    enabled = db.Column(db.Boolean, default=True)
    position = db.Column(db.Integer, default=0)
    size = db.Column(db.String(20), default="medium")
    config_json = db.Column(db.Text)


class NavItem(db.Model):
    """Navigation items registered by core or modules."""
    __tablename__ = "nav_items"

    id = db.Column(db.Integer, primary_key=True)
    module_id = db.Column(db.String(80), nullable=True, index=True)
    label = db.Column(db.String(80), nullable=False)
    icon = db.Column(db.String(80))
    url = db.Column(db.String(255), nullable=False)
    position = db.Column(db.Integer, default=0)
    enabled = db.Column(db.Boolean, default=True)
