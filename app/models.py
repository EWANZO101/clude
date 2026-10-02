import uuid
from datetime import datetime, timedelta

from flask_login import UserMixin
from werkzeug.security import generate_password_hash, check_password_hash

from app.extensions import db


def gen_uuid():
    return str(uuid.uuid4())


class Role:
    USER = "user"
    ADMIN = "admin"
    SUPPORT = "support"


class User(UserMixin, db.Model):
    __tablename__ = "users"

    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    email = db.Column(db.String(255), unique=True, nullable=False, index=True)
    password_hash = db.Column(db.String(255), nullable=False)
    role = db.Column(db.String(20), default=Role.USER, nullable=False)

    is_temporary = db.Column(db.Boolean, default=False, nullable=False)
    email_verified = db.Column(db.Boolean, default=False, nullable=False)

    totp_secret = db.Column(db.String(64), nullable=True)
    totp_enabled = db.Column(db.Boolean, default=False, nullable=False)

    is_active_flag = db.Column("is_active", db.Boolean, default=True, nullable=False)
    is_suspended = db.Column(db.Boolean, default=False, nullable=False)
    force_logout_at = db.Column(db.DateTime, nullable=True)

    created_at = db.Column(db.DateTime, default=datetime.utcnow, nullable=False)
    expires_at = db.Column(db.DateTime, nullable=True)  # only for temp accounts
    last_login_at = db.Column(db.DateTime, nullable=True)
    last_login_ip = db.Column(db.String(64), nullable=True)

    exports = db.relationship("Export", backref="owner", lazy="dynamic",
                               cascade="all, delete-orphan")

    def set_password(self, raw_password):
        self.password_hash = generate_password_hash(raw_password)

    def check_password(self, raw_password):
        return check_password_hash(self.password_hash, raw_password)

    def mark_temporary(self, lifetime: timedelta):
        self.is_temporary = True
        self.expires_at = datetime.utcnow() + lifetime

    @property
    def is_expired(self):
        return bool(self.is_temporary and self.expires_at and datetime.utcnow() > self.expires_at)

    @property
    def is_active(self):
        return self.is_active_flag and not self.is_suspended and not self.is_expired

    def is_admin(self):
        return self.role == Role.ADMIN

    def __repr__(self):
        return f"<User {self.email}>"


class ExportStatus:
    PENDING = "pending"
    RUNNING = "running"
    COMPLETE = "complete"
    FAILED = "failed"
    EXPIRED = "expired"


class Export(db.Model):
    __tablename__ = "exports"

    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    user_id = db.Column(db.String(36), db.ForeignKey("users.id"), nullable=False)

    source_os = db.Column(db.String(20), nullable=True)   # windows / linux
    status = db.Column(db.String(20), default=ExportStatus.PENDING, nullable=False)

    file_path = db.Column(db.String(512), nullable=True)
    file_size_bytes = db.Column(db.BigInteger, nullable=True)
    sha256 = db.Column(db.String(64), nullable=True)

    manifest_json = db.Column(db.Text, nullable=True)

    error_message = db.Column(db.Text, nullable=True)

    created_at = db.Column(db.DateTime, default=datetime.utcnow, nullable=False)
    completed_at = db.Column(db.DateTime, nullable=True)
    expires_at = db.Column(db.DateTime, nullable=True)

    def __repr__(self):
        return f"<Export {self.id} {self.status}>"


class AuditLog(db.Model):
    __tablename__ = "audit_logs"

    id = db.Column(db.Integer, primary_key=True, autoincrement=True)
    user_id = db.Column(db.String(36), db.ForeignKey("users.id"), nullable=True)
    action = db.Column(db.String(120), nullable=False)
    detail = db.Column(db.Text, nullable=True)
    ip_address = db.Column(db.String(64), nullable=True)
    created_at = db.Column(db.DateTime, default=datetime.utcnow, nullable=False)


class ImportStatus:
    PENDING = "pending"
    RUNNING = "running"
    COMPLETE = "complete"
    FAILED = "failed"


class ImportJob(db.Model):
    __tablename__ = "import_jobs"

    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    user_id = db.Column(db.String(36), db.ForeignKey("users.id"), nullable=False)

    source_filename = db.Column(db.String(255), nullable=True)
    target_path = db.Column(db.String(512), nullable=True)
    target_os = db.Column(db.String(20), nullable=True)

    status = db.Column(db.String(20), default=ImportStatus.PENDING, nullable=False)
    log_text = db.Column(db.Text, nullable=True)
    error_message = db.Column(db.Text, nullable=True)
    warnings_json = db.Column(db.Text, nullable=True)

    created_at = db.Column(db.DateTime, default=datetime.utcnow, nullable=False)
    completed_at = db.Column(db.DateTime, nullable=True)

    user = db.relationship("User")

    def __repr__(self):
        return f"<ImportJob {self.id} {self.status}>"


class Setting(db.Model):
    __tablename__ = "settings"

    key = db.Column(db.String(120), primary_key=True)
    value = db.Column(db.Text, nullable=True)
    updated_at = db.Column(db.DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)

    DEFAULTS = {
        "export_retention_days": "30",
        "temp_account_lifetime_hours": "12",
        "cleanup_enabled": "true",
        "mail_server": "",
        "mail_from": "no-reply@example.com",
    }

    @classmethod
    def get(cls, key, default=None):
        row = db.session.get(cls, key)
        if row is not None:
            return row.value
        return cls.DEFAULTS.get(key, default)

    @classmethod
    def set(cls, key, value):
        row = db.session.get(cls, key)
        if row is None:
            row = cls(key=key, value=value)
            db.session.add(row)
        else:
            row.value = value
        db.session.commit()
