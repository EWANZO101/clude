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

    def __repr__(self):  # pragma: no cover
        return f"<Settings user_id={self.user_id} manual_status={self.manual_status}>"
