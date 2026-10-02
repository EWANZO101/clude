import uuid
from datetime import datetime
from app.extensions import db

ROLE_OWNER = "owner"
ROLE_ADMIN = "admin"
ROLE_ACCOUNTANT = "accountant"
ROLE_BOOKKEEPER = "bookkeeper"
ROLE_MANAGER = "manager"
ROLE_EMPLOYEE = "employee"
ROLE_READONLY = "readonly"

ALL_ROLES = [
    ROLE_OWNER, ROLE_ADMIN, ROLE_ACCOUNTANT, ROLE_BOOKKEEPER,
    ROLE_MANAGER, ROLE_EMPLOYEE, ROLE_READONLY,
]

# Simple, explicit permission table for Phase 1. Extended later.
ROLE_PERMISSIONS = {
    ROLE_OWNER: {"view", "create", "edit", "delete", "manage_users", "manage_settings", "export"},
    ROLE_ADMIN: {"view", "create", "edit", "delete", "manage_users", "manage_settings", "export"},
    ROLE_ACCOUNTANT: {"view", "create", "edit", "export"},
    ROLE_BOOKKEEPER: {"view", "create", "edit", "export"},
    ROLE_MANAGER: {"view", "create", "edit", "export"},
    ROLE_EMPLOYEE: {"view", "create"},
    ROLE_READONLY: {"view"},
}


def gen_uuid():
    return str(uuid.uuid4())


class Business(db.Model):
    __tablename__ = "businesses"

    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    name = db.Column(db.String(255), nullable=False)
    base_currency = db.Column(db.String(3), default="USD", nullable=False)
    is_archived = db.Column(db.Boolean, default=False, nullable=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    memberships = db.relationship(
        "Membership", back_populates="business", cascade="all, delete-orphan"
    )
    accounts = db.relationship(
        "Account", back_populates="business", cascade="all, delete-orphan"
    )
    journal_entries = db.relationship(
        "JournalEntry", back_populates="business", cascade="all, delete-orphan"
    )

    def __repr__(self):
        return f"<Business {self.name}>"


class Membership(db.Model):
    """Links a User to a Business with a role. Enforces strict data isolation:
    a user can only ever query business data through an existing membership."""

    __tablename__ = "memberships"
    __table_args__ = (
        db.UniqueConstraint("user_id", "business_id", name="uq_user_business"),
    )

    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    user_id = db.Column(db.String(36), db.ForeignKey("users.id"), nullable=False)
    business_id = db.Column(db.String(36), db.ForeignKey("businesses.id"), nullable=False)
    role = db.Column(db.String(32), nullable=False, default=ROLE_EMPLOYEE)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    user = db.relationship("User", back_populates="memberships")
    business = db.relationship("Business", back_populates="memberships")

    def has_permission(self, permission):
        return permission in ROLE_PERMISSIONS.get(self.role, set())
