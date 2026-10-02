import secrets
from datetime import datetime, timezone as dt_timezone

from werkzeug.security import check_password_hash, generate_password_hash

from app import db


class TimeOff(db.Model):
    """A one-off unavailable period: a holiday, a day off, or a partial-day block.

    Stored as naive datetimes in the user's configured timezone (see
    User.timezone) — the availability engine is responsible for interpreting
    them consistently, the same way it interprets working hours.
    """

    __tablename__ = "time_off"

    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False, index=True)
    start_datetime = db.Column(db.DateTime, nullable=False)
    end_datetime = db.Column(db.DateTime, nullable=False)
    all_day = db.Column(db.Boolean, nullable=False, default=True)
    reason = db.Column(db.String(255), nullable=True)
    created_at = db.Column(db.DateTime, default=lambda: datetime.now(dt_timezone.utc))

    def __repr__(self):  # pragma: no cover
        return f"<TimeOff {self.start_datetime} - {self.end_datetime}>"


class TimeOffShareLink(db.Model):
    """A link that lets someone who isn't the admin add time off on the
    admin's behalf — e.g. a partner or assistant marking days the admin is
    unavailable. Optionally PIN-protected; if pin_hash is None the link is
    open to anyone who has it, same as calendarmaker's public link.

    Deliberately narrow: whoever holds this link can only see and manage
    TimeOff entries (via the owning user_id) — never bookings, availability,
    or anything else in the admin panel.
    """

    __tablename__ = "time_off_share_links"

    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False, index=True)
    token = db.Column(db.String(32), nullable=False, unique=True, index=True)
    label = db.Column(db.String(120), nullable=True)
    pin_hash = db.Column(db.String(255), nullable=True)
    created_at = db.Column(db.DateTime, default=lambda: datetime.now(dt_timezone.utc))
    last_used_at = db.Column(db.DateTime, nullable=True)

    user = db.relationship("User", backref=db.backref("time_off_share_links", lazy="select"))

    @staticmethod
    def generate_token():
        return secrets.token_urlsafe(9)

    @property
    def pin_protected(self):
        return self.pin_hash is not None

    def set_pin(self, raw_pin: str) -> None:
        self.pin_hash = generate_password_hash(raw_pin) if raw_pin else None

    def check_pin(self, raw_pin: str) -> bool:
        if not self.pin_hash:
            return True
        return check_password_hash(self.pin_hash, raw_pin or "")

    def __repr__(self):  # pragma: no cover
        return f"<TimeOffShareLink {self.token} -> user {self.user_id}>"
