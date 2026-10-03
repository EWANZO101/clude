import secrets
from datetime import datetime, timezone as dt_timezone

from werkzeug.security import check_password_hash, generate_password_hash

from app import db


class SharedCalendar(db.Model):
    """A calendar created via /clandermaker, identified by a random share link.

    Deliberately independent of the User/admin system — anyone can create
    one without an account. Access is controlled per-person via
    CalendarAccess (email + PIN) rather than a login.
    """

    __tablename__ = "shared_calendars"

    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(120), nullable=False, default="My Calendar")
    share_token = db.Column(db.String(32), nullable=False, unique=True, index=True)
    created_at = db.Column(db.DateTime, default=lambda: datetime.now(dt_timezone.utc))

    accesses = db.relationship(
        "CalendarAccess", backref="calendar", lazy="select", cascade="all, delete-orphan"
    )
    events = db.relationship(
        "CalendarEvent",
        backref="calendar",
        lazy="select",
        cascade="all, delete-orphan",
        order_by="CalendarEvent.event_date",
    )

    @staticmethod
    def generate_share_token():
        # url-safe, short enough to type but with enough entropy (72 bits)
        # that guessing a live token isn't practical.
        return secrets.token_urlsafe(9)

    def __repr__(self):  # pragma: no cover
        return f"<SharedCalendar {self.name} ({self.share_token})>"


class CalendarAccess(db.Model):
    """One person's PIN-protected access to a shared calendar.

    A calendar can have many of these — one per person it's been shared
    with, including the creator, who goes through the same setup flow as
    everyone else.
    """

    __tablename__ = "calendar_access"
    __table_args__ = (
        db.UniqueConstraint("shared_calendar_id", "email", name="uq_calendar_access_email"),
    )

    id = db.Column(db.Integer, primary_key=True)
    shared_calendar_id = db.Column(
        db.Integer, db.ForeignKey("shared_calendars.id"), nullable=False, index=True
    )
    email = db.Column(db.String(255), nullable=False, index=True)
    pin_hash = db.Column(db.String(255), nullable=False)
    created_at = db.Column(db.DateTime, default=lambda: datetime.now(dt_timezone.utc))
    last_accessed_at = db.Column(db.DateTime, nullable=True)

    def set_pin(self, raw_pin: str) -> None:
        self.pin_hash = generate_password_hash(raw_pin)

    def check_pin(self, raw_pin: str) -> bool:
        return check_password_hash(self.pin_hash, raw_pin)

    def __repr__(self):  # pragma: no cover
        return f"<CalendarAccess {self.email} -> calendar {self.shared_calendar_id}>"


class CalendarEvent(db.Model):
    """A simple event on a shared calendar — deliberately lightweight;
    this is a shared notice-board calendar, not the availability/booking
    engine used elsewhere in the app."""

    __tablename__ = "calendar_events"

    id = db.Column(db.Integer, primary_key=True)
    shared_calendar_id = db.Column(
        db.Integer, db.ForeignKey("shared_calendars.id"), nullable=False, index=True
    )
    title = db.Column(db.String(200), nullable=False)
    event_date = db.Column(db.Date, nullable=False, index=True)
    start_time = db.Column(db.Time, nullable=True)
    end_time = db.Column(db.Time, nullable=True)
    notes = db.Column(db.Text, nullable=True)
    created_by_email = db.Column(db.String(255), nullable=True)
    created_at = db.Column(db.DateTime, default=lambda: datetime.now(dt_timezone.utc))

    def __repr__(self):  # pragma: no cover
        return f"<CalendarEvent {self.title} {self.event_date}>"
