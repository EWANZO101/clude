from datetime import datetime

from argon2 import PasswordHasher
from argon2.exceptions import VerifyMismatchError, InvalidHash
from flask_login import UserMixin

from database import db

_hasher = PasswordHasher()


class User(db.Model, UserMixin):
    __tablename__ = "users"

    id = db.Column(db.Integer, primary_key=True)
    username = db.Column(db.String(64), unique=True, nullable=False, index=True)
    email = db.Column(db.String(255), unique=True, nullable=False, index=True)
    password_hash = db.Column(db.String(255), nullable=False)

    role_id = db.Column(db.Integer, db.ForeignKey("roles.id"), nullable=False)
    role = db.relationship("Role", back_populates="users")

    is_super_admin = db.Column(db.Boolean, nullable=False, server_default="0", default=False)
    is_active_flag = db.Column("is_active", db.Boolean, nullable=False, server_default="1", default=True)

    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    last_login_at = db.Column(db.DateTime, nullable=True)

    def set_password(self, raw_password):
        self.password_hash = _hasher.hash(raw_password)

    def check_password(self, raw_password):
        try:
            return _hasher.verify(self.password_hash, raw_password)
        except (VerifyMismatchError, InvalidHash):
            return False

    @property
    def is_active(self):
        return self.is_active_flag

    def has_permission(self, permission):
        if self.is_super_admin:
            return True
        return self.role.has_permission(permission) if self.role else False

    def __repr__(self):
        return f"<User {self.username}>"
