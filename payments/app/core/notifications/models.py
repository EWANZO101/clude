from datetime import datetime
from app.extensions import db


class Notification(db.Model):
    __tablename__ = "notifications"
    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.String(36), db.ForeignKey("users.id"), nullable=False, index=True)
    kind = db.Column(db.String(60), nullable=False)  # payment_reminder, bill, budget_warning, spending_alert, ...
    title = db.Column(db.String(200), nullable=False)
    body = db.Column(db.Text)
    module_id = db.Column(db.String(80))
    url = db.Column(db.String(255))
    read = db.Column(db.Boolean, default=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)


class NotificationPreference(db.Model):
    __tablename__ = "notification_preferences"
    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.String(36), db.ForeignKey("users.id"), nullable=False, index=True)
    kind = db.Column(db.String(60), nullable=False)
    in_app = db.Column(db.Boolean, default=True)
    email = db.Column(db.Boolean, default=False)

    __table_args__ = (db.UniqueConstraint("user_id", "kind", name="uq_notif_pref_user_kind"),)
