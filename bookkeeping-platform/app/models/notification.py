import uuid
from datetime import datetime
from app.extensions import db

TYPE_OVERDUE_INVOICE = "overdue_invoice"
TYPE_UPCOMING_BILL = "upcoming_bill"
TYPE_INTEGRATION_FAILURE = "integration_failure"
TYPE_AUDIT_WARNING = "audit_warning"
TYPE_BACKUP_FAILURE = "backup_failure"
TYPE_SYNC_FAILURE = "sync_failure"


def gen_uuid():
    return str(uuid.uuid4())


class Notification(db.Model):
    __tablename__ = "notifications"

    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    user_id = db.Column(db.String(36), db.ForeignKey("users.id"), nullable=False)
    business_id = db.Column(db.String(36), db.ForeignKey("businesses.id"), nullable=True)

    type = db.Column(db.String(50), nullable=False)
    title = db.Column(db.String(255), nullable=False)
    message = db.Column(db.Text, nullable=False)
    link = db.Column(db.String(500), nullable=True)
    is_read = db.Column(db.Boolean, default=False, nullable=False)

    created_at = db.Column(db.DateTime, default=datetime.utcnow, index=True)


class NotificationPreference(db.Model):
    """One row per user. Missing row = all defaults (everything on)."""

    __tablename__ = "notification_preferences"

    user_id = db.Column(db.String(36), db.ForeignKey("users.id"), primary_key=True)
    notify_overdue_invoices = db.Column(db.Boolean, default=True, nullable=False)
    notify_upcoming_bills = db.Column(db.Boolean, default=True, nullable=False)
    notify_integration_failures = db.Column(db.Boolean, default=True, nullable=False)
    notify_audit_warnings = db.Column(db.Boolean, default=True, nullable=False)
    notify_backup_failures = db.Column(db.Boolean, default=True, nullable=False)
    notify_sync_failures = db.Column(db.Boolean, default=True, nullable=False)


PREFERENCE_FIELD_BY_TYPE = {
    TYPE_OVERDUE_INVOICE: "notify_overdue_invoices",
    TYPE_UPCOMING_BILL: "notify_upcoming_bills",
    TYPE_INTEGRATION_FAILURE: "notify_integration_failures",
    TYPE_AUDIT_WARNING: "notify_audit_warnings",
    TYPE_BACKUP_FAILURE: "notify_backup_failures",
    TYPE_SYNC_FAILURE: "notify_sync_failures",
}
