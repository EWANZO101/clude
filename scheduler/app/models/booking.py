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

    # Whether this was booked outside the owner's normal working hours (only
    # possible when Settings.allow_out_of_hours_bookings is on), and what fee
    # was shown to the customer at the time — a snapshot, since the fee in
    # Settings can change later without rewriting history.
    is_out_of_hours = db.Column(db.Boolean, nullable=False, default=False)
    out_of_hours_fee_shown = db.Column(db.String(30), nullable=True)

    created_at = db.Column(db.DateTime, default=lambda: datetime.now(dt_timezone.utc))
    cancelled_at = db.Column(db.DateTime, nullable=True)

    # Sent-flags for the discord_bot/ notifier, so its polling loop never
    # double-sends. Each fires once, in order, as the booking approaches.
    discord_new_notified = db.Column(db.Boolean, nullable=False, default=False)
    discord_cancel_notified = db.Column(db.Boolean, nullable=False, default=False)
    discord_day_reminder_sent = db.Column(db.Boolean, nullable=False, default=False)
    discord_hour_reminder_sent = db.Column(db.Boolean, nullable=False, default=False)
    discord_15min_reminder_sent = db.Column(db.Boolean, nullable=False, default=False)

    ping_states = db.relationship(
        "BookingPingState", backref="booking", lazy="select", cascade="all, delete-orphan"
    )

    def __repr__(self):  # pragma: no cover
        return f"<Booking {self.name} {self.start_datetime} [{self.status}]>"


class BookingPingState(db.Model):
    """One "spam ping" session for one Discord recipient on one booking.

    A booking can have several of these at once — one per person in
    Settings.all_discord_recipient_ids() — each tracked and stopped
    independently, since each recipient has their own DM channel and
    their own Stop button. See discord_bot/notifier.py run_ping_tick().
    """

    __tablename__ = "booking_ping_states"
    __table_args__ = (
        db.UniqueConstraint("booking_id", "discord_user_id", name="uq_booking_ping_recipient"),
    )

    id = db.Column(db.Integer, primary_key=True)
    booking_id = db.Column(db.Integer, db.ForeignKey("bookings.id"), nullable=False, index=True)
    discord_user_id = db.Column(db.String(32), nullable=False)

    active = db.Column(db.Boolean, nullable=False, default=True)
    count = db.Column(db.Integer, nullable=False, default=0)
    last_sent_at = db.Column(db.DateTime, nullable=True)
    # Snowflake ID (string) of the most recent ping DM to this recipient —
    # deleted when the next ping goes out, so only the latest is visible.
    last_message_id = db.Column(db.String(32), nullable=True)

    def __repr__(self):  # pragma: no cover
        return f"<BookingPingState booking={self.booking_id} recipient={self.discord_user_id} active={self.active}>"
