from datetime import datetime, timezone as dt_timezone

from app import db

# Statuses a person can manually set. "offline" is deliberately excluded —
# it's only ever computed automatically for times outside working hours.
MANUAL_STATUSES = ["available", "busy", "unavailable", "away"]


class Settings(db.Model):
    """Per-user settings. One row per user, created on demand.

    Only the manual status override lives here for Phase 2. Public booking
    settings, public status page settings, and notification preferences are
    planned additions here in later phases (see PROJECT STRUCTURE).
    """

    __tablename__ = "settings"

    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False, unique=True, index=True)

    manual_status = db.Column(db.String(20), nullable=True)  # one of MANUAL_STATUSES, or NULL for automatic
    manual_status_message = db.Column(db.String(255), nullable=True)
    manual_status_expires_at = db.Column(db.DateTime, nullable=True)  # optional auto-revert to automatic

    # Public booking/status settings land here in later phases too.
    notify_on_new_booking = db.Column(db.Boolean, nullable=False, default=True)
    notify_on_cancellation = db.Column(db.Boolean, nullable=False, default=True)

    # Discord DM notifications, sent by the separate discord_bot/ process (see
    # its README). discord_user_id is the numeric Discord user ID (stored as a
    # string — it's a 64-bit snowflake, no arithmetic ever needed on it) of
    # the person to DM. The bot can only DM someone who shares a server with
    # it or has DM'd it before, per Discord's own restrictions.
    discord_user_id = db.Column(db.String(32), nullable=True)
    notify_discord_new_booking = db.Column(db.Boolean, nullable=False, default=True)
    notify_discord_cancellation = db.Column(db.Boolean, nullable=False, default=True)
    notify_discord_reminders = db.Column(db.Boolean, nullable=False, default=True)

    # Off switch for the repeated "spam ping" nags on new / out-of-hours
    # bookings — the one-off new-booking DM above is unaffected by this.
    discord_spam_ping_enabled = db.Column(db.Boolean, nullable=False, default=True)

    # Set by the admin settings page, cleared by the bot once it has sent a
    # test DM — a simple cross-process "do this" flag since Flask and the
    # bot don't otherwise talk to each other.
    discord_test_requested_at = db.Column(db.DateTime, nullable=True)

    # A free-text "what I'm doing right now" line for a deliberately minimal
    # public page (/task) that shows only this — no name, no avatar, no
    # schedule, nothing else identifying.
    current_task = db.Column(db.String(255), nullable=True)

    # Shown to a customer on the ISP Support request form when they submit
    # outside your normal working hours (see app/services/availability.py).
    # Free text (like "£45") rather than a decimal, matching how other
    # money-ish fields in this app (last bill amount) are stored — this app
    # doesn't do real invoicing, just communicates the fee up front.
    isp_out_of_hours_fee = db.Column(db.String(30), nullable=True)

    # Separately: whether the public booking page (see app/services/booking.py)
    # offers times outside your normal working hours at all, and what fee is
    # shown for them. Off by default — bookings stay strictly within working
    # hours unless you turn this on.
    allow_out_of_hours_bookings = db.Column(db.Boolean, nullable=False, default=False)
    out_of_hours_booking_fee = db.Column(db.String(30), nullable=True)

    created_at = db.Column(db.DateTime, default=lambda: datetime.now(dt_timezone.utc))
    updated_at = db.Column(
        db.DateTime,
        default=lambda: datetime.now(dt_timezone.utc),
        onupdate=lambda: datetime.now(dt_timezone.utc),
    )

    @classmethod
    def for_user(cls, user):
        """Get (or lazily create) this user's settings row."""
        settings = cls.query.filter_by(user_id=user.id).first()
        if settings is None:
            settings = cls(user_id=user.id)
            db.session.add(settings)
            db.session.commit()
        return settings

    def all_discord_recipient_ids(self):
        """Primary discord_user_id plus every DiscordRecipient for this
        user, deduplicated. Used everywhere a notification fans out to
        'everyone who should be pinged', not just the primary contact."""
        ids = []
        if self.discord_user_id:
            ids.append(self.discord_user_id)
        for r in DiscordRecipient.query.filter_by(user_id=self.user_id).all():
            if r.discord_user_id not in ids:
                ids.append(r.discord_user_id)
        return ids

    def __repr__(self):  # pragma: no cover
        return f"<Settings user_id={self.user_id} manual_status={self.manual_status}>"


class DiscordRecipient(db.Model):
    """An extra person to DM alongside the primary discord_user_id above.

    Every Discord notification (new booking, cancellation, reminders, and
    the repeating spam pings) goes to the primary ID *and* every row here —
    useful for a second person (a partner, an assistant) who should also
    get pinged. Each recipient with their own DM channel, so pings track
    and stop independently per person (see BookingPingState).
    """

    __tablename__ = "discord_recipients"
    __table_args__ = (
        db.UniqueConstraint("user_id", "discord_user_id", name="uq_discord_recipient"),
    )

    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False, index=True)
    discord_user_id = db.Column(db.String(32), nullable=False)
    label = db.Column(db.String(80), nullable=True)
    created_at = db.Column(db.DateTime, default=lambda: datetime.now(dt_timezone.utc))

    def __repr__(self):  # pragma: no cover
        return f"<DiscordRecipient {self.label or self.discord_user_id}>"
