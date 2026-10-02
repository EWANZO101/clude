from datetime import datetime, timezone as dt_timezone

from app import db


class PushDevice(db.Model):
    """A phone running the mobile app (ios/) that wants push notifications.

    `token` is an Expo push token ("ExponentPushToken[...]"), registered by
    the app after sign-in via POST /api/v1/push-devices. Sends go through
    Expo's push service (see app/services/push.py); tokens Expo reports as
    no longer registered are deleted there.
    """

    __tablename__ = "push_devices"

    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False, index=True)
    token = db.Column(db.String(255), nullable=False, unique=True)
    created_at = db.Column(db.DateTime, default=lambda: datetime.now(dt_timezone.utc))
    last_seen_at = db.Column(db.DateTime, default=lambda: datetime.now(dt_timezone.utc))

    def __repr__(self):  # pragma: no cover
        return f"<PushDevice user={self.user_id} {self.token[:24]}…>"
