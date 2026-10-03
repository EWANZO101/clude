from datetime import datetime, timezone
from flask_login import UserMixin
from app.extensions import db


def utcnow():
    return datetime.now(timezone.utc)


class User(db.Model, UserMixin):
    __tablename__ = "users"

    id = db.Column(db.Integer, primary_key=True)

    # Public-facing identifiers
    user_id = db.Column(db.String(20), unique=True, nullable=False, index=True)
    support_id = db.Column(db.String(20), unique=True, nullable=False, index=True)
    api_identifier = db.Column(db.String(40), unique=True, nullable=False, index=True)

    username = db.Column(db.String(64), unique=True, nullable=False, index=True)
    email = db.Column(db.String(255), unique=True, nullable=False, index=True)

    password_hash = db.Column(db.String(255), nullable=False)

    # Recovery PIN: only the hash is ever stored. Raw value is shown once at
    # creation/reset time and cannot be retrieved afterwards.
    recovery_pin_hash = db.Column(db.String(255), nullable=True)

    is_developer = db.Column(db.Boolean, default=False, nullable=False)
    is_admin = db.Column(db.Boolean, default=False, nullable=False)
    is_support = db.Column(db.Boolean, default=False, nullable=False)
    is_suspended = db.Column(db.Boolean, default=False, nullable=False)

    # Email verification. Not just a nicety - auto-linking purchases to
    # an account by email match (Phase 6) is only safe to trust once the
    # email is actually verified, otherwise registering with someone
    # else's email would auto-link THEIR future purchases to the
    # registrant's account before the real owner ever signs up.
    email_verified = db.Column(db.Boolean, default=False, server_default=db.text("false"), nullable=False)

    # 2FA - secret is reversibly encrypted (Fernet, same as webhook secrets)
    # since TOTP verification needs the raw value, unlike passwords.
    totp_secret_encrypted = db.Column(db.Text, nullable=True)
    totp_enabled = db.Column(db.Boolean, default=False, nullable=False)
    backup_codes_hashed = db.Column(db.Text, nullable=True)  # JSON list of bcrypt hashes

    created_at = db.Column(db.DateTime(timezone=True), default=utcnow, nullable=False)
    last_login_at = db.Column(db.DateTime(timezone=True), nullable=True)
    last_login_ip = db.Column(db.String(64), nullable=True)

    def get_id(self):
        # flask-login identity - use the internal integer PK
        return str(self.id)

    def __repr__(self):
        return f"<User {self.username} ({self.user_id})>"


class SupportAuditLog(db.Model):
    """Every time a support agent looks up or acts on an account, log it."""

    __tablename__ = "support_audit_log"

    id = db.Column(db.Integer, primary_key=True)
    support_user_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False)
    target_user_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False)
    action = db.Column(db.String(64), nullable=False)  # e.g. "lookup", "temp_password_issued"
    detail = db.Column(db.Text, nullable=True)
    created_at = db.Column(db.DateTime(timezone=True), default=utcnow, nullable=False)

    support_user = db.relationship("User", foreign_keys=[support_user_id])
    target_user = db.relationship("User", foreign_keys=[target_user_id])


class AdminActionLog(db.Model):
    """Platform-wide admin actions - suspending a user, changing roles,
    disabling any product, revoking any license. Separate from
    SupportAuditLog (which is specifically the account-recovery flow) -
    this covers admin's own broader powers, which had zero accountability
    at all before this. With more than one admin, that's a real gap."""

    __tablename__ = "admin_action_log"

    id = db.Column(db.Integer, primary_key=True)
    admin_user_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False)
    action = db.Column(db.String(64), nullable=False)
    target_label = db.Column(db.String(255), nullable=True)
    created_at = db.Column(db.DateTime(timezone=True), default=utcnow, nullable=False, index=True)

    admin_user = db.relationship("User", foreign_keys=[admin_user_id])
