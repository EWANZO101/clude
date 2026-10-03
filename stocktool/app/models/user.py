from datetime import datetime, timezone
from flask_login import UserMixin
from werkzeug.security import generate_password_hash, check_password_hash
from app.extensions import db


class Role:
    ADMIN = "admin"
    STOCK_USER = "stock_user"
    ALL = [ADMIN, STOCK_USER]


class User(UserMixin, db.Model):
    __tablename__ = "users"

    id = db.Column(db.Integer, primary_key=True)
    username = db.Column(db.String(64), unique=True, nullable=False, index=True)
    email = db.Column(db.String(120), unique=True, nullable=False, index=True)
    password_hash = db.Column(db.String(256), nullable=False)
    role = db.Column(db.String(32), nullable=False, default=Role.STOCK_USER)
    is_active = db.Column(db.Boolean, default=True, nullable=False)
    force_password_change = db.Column(db.Boolean, default=False, nullable=False)
    created_at = db.Column(db.DateTime, default=lambda: datetime.now(timezone.utc))
    last_login = db.Column(db.DateTime, nullable=True)

    # ── Relationships ──────────────────────────────────────────────────────
    tool_histories = db.relationship("ToolHistory", back_populates="user", lazy="dynamic")
    audit_logs = db.relationship("AuditLog", back_populates="user", lazy="dynamic")
    barcode = db.relationship("Barcode", back_populates="user", uselist=False,
                               foreign_keys="Barcode.user_id")

    # ── Password ───────────────────────────────────────────────────────────
    def set_password(self, password: str):
        self.password_hash = generate_password_hash(password)

    def check_password(self, password: str) -> bool:
        return check_password_hash(self.password_hash, password)

    # ── Role helpers ───────────────────────────────────────────────────────
    @property
    def is_admin(self) -> bool:
        return self.role == Role.ADMIN

    @property
    def is_stock_user(self) -> bool:
        return self.role == Role.STOCK_USER

    # ── Flask-Login required ───────────────────────────────────────────────
    @property
    def active(self) -> bool:
        return self.is_active

    def get_id(self) -> str:
        return str(self.id)

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "username": self.username,
            "email": self.email,
            "role": self.role,
            "is_active": self.is_active,
            "created_at": self.created_at.isoformat() if self.created_at else None,
            "last_login": self.last_login.isoformat() if self.last_login else None,
        }

    def __repr__(self):
        return f"<User {self.username} [{self.role}]>"
