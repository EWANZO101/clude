import secrets
from datetime import datetime, timezone as dt_timezone

from app import db

BOOKING_STATUSES = ["pending", "confirmed", "cancelled", "completed", "no_show"]
ACTIVE_BOOKING_STATUSES = ("pending", "confirmed")


class BookingType(db.Model):
    """A kind of meeting someone can book, e.g. 'Quick Chat, 15 minutes'."""

    __tablename__ = "booking_types"

    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False, index=True)
    name = db.Column(db.String(120), nullable=False)
    description = db.Column(db.String(500), nullable=True)
    duration = db.Column(db.Integer, nullable=False)  # minutes
    buffer_before = db.Column(db.Integer, nullable=False, default=0)  # minutes
    buffer_after = db.Column(db.Integer, nullable=False, default=0)  # minutes
    enabled = db.Column(db.Boolean, nullable=False, default=True)
    created_at = db.Column(db.DateTime, default=lambda: datetime.now(dt_timezone.utc))

    bookings = db.relationship("Booking", backref="booking_type", lazy="select")

    def __repr__(self):  # pragma: no cover
        return f"<BookingType {self.name} ({self.duration}m)>"


class Booking(db.Model):
    """A single scheduled (or requested) meeting."""

    __tablename__ = "bookings"

    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False, index=True)
    booking_type_id = db.Column(db.Integer, db.ForeignKey("booking_types.id"), nullable=True, index=True)

    user = db.relationship("User", backref="bookings")

    name = db.Column(db.String(120), nullable=False)
    email = db.Column(db.String(255), nullable=False)
    phone = db.Column(db.String(40), nullable=True)
    notes = db.Column(db.Text, nullable=True)

    start_datetime = db.Column(db.DateTime, nullable=False, index=True)
    end_datetime = db.Column(db.DateTime, nullable=False)
    status = db.Column(db.String(20), nullable=False, default="confirmed", index=True)

    # Lets the person who booked manage (view/cancel) their own booking
    # without an account — a long random token in the URL rather than a
    # guessable/sequential id. See SECURITY: "secure booking management links".
    manage_token = db.Column(db.String(64), nullable=False, unique=True, default=lambda: secrets.token_urlsafe(32))

    created_at = db.Column(db.DateTime, default=lambda: datetime.now(dt_timezone.utc))
    cancelled_at = db.Column(db.DateTime, nullable=True)

    def __repr__(self):  # pragma: no cover
        return f"<Booking {self.name} {self.start_datetime} [{self.status}]>"
