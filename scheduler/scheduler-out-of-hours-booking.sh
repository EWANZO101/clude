#!/usr/bin/env bash
# Scheduler patch — out-of-hours bookings on the main booking page.
#
# Root cause of "can't book the same day out of hours": the booking system
# was built to NEVER offer a slot outside your configured working hours —
# that was by design, not a bug, but you want it to be possible with a fee.
#
# New: Settings -> "Booking out-of-hours" — a toggle + a fee. Off by
# default (nothing changes unless you turn it on). Once on, /book pages
# show a second row of times below the normal ones, out-of-hours slots,
# with the fee shown and a required accept-the-fee checkbox before
# confirming. Bookings made this way are flagged in the admin bookings
# list and on the customer's confirmation page.
#
# Paste this whole block into a terminal on the server.
set -euo pipefail

APP_DIR="${APP_DIR:-/root/scheduler}"
SERVICE_NAME="${SERVICE_NAME:-scheduler}"
PORT="${PORT:-5076}"

[ -f "$APP_DIR/run.py" ] || { echo "APP_DIR ($APP_DIR) doesn't look like the scheduler app — set APP_DIR=/path first."; exit 1; }

ts=$(date +%Y%m%d%H%M%S)
mkdir -p "$APP_DIR/.pre-patch-backup-$ts"
[ -f "$APP_DIR/app/models/settings.py" ] && { mkdir -p "$APP_DIR/.pre-patch-backup-$ts/$(dirname app/models/settings.py)"; cp "$APP_DIR/app/models/settings.py" "$APP_DIR/.pre-patch-backup-$ts/app/models/settings.py"; } || true
[ -f "$APP_DIR/app/models/booking.py" ] && { mkdir -p "$APP_DIR/.pre-patch-backup-$ts/$(dirname app/models/booking.py)"; cp "$APP_DIR/app/models/booking.py" "$APP_DIR/.pre-patch-backup-$ts/app/models/booking.py"; } || true
[ -f "$APP_DIR/app/services/availability.py" ] && { mkdir -p "$APP_DIR/.pre-patch-backup-$ts/$(dirname app/services/availability.py)"; cp "$APP_DIR/app/services/availability.py" "$APP_DIR/.pre-patch-backup-$ts/app/services/availability.py"; } || true
[ -f "$APP_DIR/app/services/booking.py" ] && { mkdir -p "$APP_DIR/.pre-patch-backup-$ts/$(dirname app/services/booking.py)"; cp "$APP_DIR/app/services/booking.py" "$APP_DIR/.pre-patch-backup-$ts/app/services/booking.py"; } || true
[ -f "$APP_DIR/app/forms.py" ] && { mkdir -p "$APP_DIR/.pre-patch-backup-$ts/$(dirname app/forms.py)"; cp "$APP_DIR/app/forms.py" "$APP_DIR/.pre-patch-backup-$ts/app/forms.py"; } || true
[ -f "$APP_DIR/app/routes/public.py" ] && { mkdir -p "$APP_DIR/.pre-patch-backup-$ts/$(dirname app/routes/public.py)"; cp "$APP_DIR/app/routes/public.py" "$APP_DIR/.pre-patch-backup-$ts/app/routes/public.py"; } || true
[ -f "$APP_DIR/app/routes/admin.py" ] && { mkdir -p "$APP_DIR/.pre-patch-backup-$ts/$(dirname app/routes/admin.py)"; cp "$APP_DIR/app/routes/admin.py" "$APP_DIR/.pre-patch-backup-$ts/app/routes/admin.py"; } || true
[ -f "$APP_DIR/app/templates/admin/settings.html" ] && { mkdir -p "$APP_DIR/.pre-patch-backup-$ts/$(dirname app/templates/admin/settings.html)"; cp "$APP_DIR/app/templates/admin/settings.html" "$APP_DIR/.pre-patch-backup-$ts/app/templates/admin/settings.html"; } || true
[ -f "$APP_DIR/app/templates/admin/bookings.html" ] && { mkdir -p "$APP_DIR/.pre-patch-backup-$ts/$(dirname app/templates/admin/bookings.html)"; cp "$APP_DIR/app/templates/admin/bookings.html" "$APP_DIR/.pre-patch-backup-$ts/app/templates/admin/bookings.html"; } || true
[ -f "$APP_DIR/app/templates/public/pick_slot.html" ] && { mkdir -p "$APP_DIR/.pre-patch-backup-$ts/$(dirname app/templates/public/pick_slot.html)"; cp "$APP_DIR/app/templates/public/pick_slot.html" "$APP_DIR/.pre-patch-backup-$ts/app/templates/public/pick_slot.html"; } || true
[ -f "$APP_DIR/app/templates/public/booking_details.html" ] && { mkdir -p "$APP_DIR/.pre-patch-backup-$ts/$(dirname app/templates/public/booking_details.html)"; cp "$APP_DIR/app/templates/public/booking_details.html" "$APP_DIR/.pre-patch-backup-$ts/app/templates/public/booking_details.html"; } || true
[ -f "$APP_DIR/app/templates/public/confirmation.html" ] && { mkdir -p "$APP_DIR/.pre-patch-backup-$ts/$(dirname app/templates/public/confirmation.html)"; cp "$APP_DIR/app/templates/public/confirmation.html" "$APP_DIR/.pre-patch-backup-$ts/app/templates/public/confirmation.html"; } || true
[ -f "$APP_DIR/app/static/css/main.css" ] && { mkdir -p "$APP_DIR/.pre-patch-backup-$ts/$(dirname app/static/css/main.css)"; cp "$APP_DIR/app/static/css/main.css" "$APP_DIR/.pre-patch-backup-$ts/app/static/css/main.css"; } || true
[ -f "$APP_DIR/migrations/versions/32925cbc8dca_add_out_of_hours_bookings.py" ] && { mkdir -p "$APP_DIR/.pre-patch-backup-$ts/$(dirname migrations/versions/32925cbc8dca_add_out_of_hours_bookings.py)"; cp "$APP_DIR/migrations/versions/32925cbc8dca_add_out_of_hours_bookings.py" "$APP_DIR/.pre-patch-backup-$ts/migrations/versions/32925cbc8dca_add_out_of_hours_bookings.py"; } || true

mkdir -p "$APP_DIR/app/models"
cat > "$APP_DIR/app/models/settings.py" << 'CLAUDE_PATCH_EOF'
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

    def __repr__(self):  # pragma: no cover
        return f"<Settings user_id={self.user_id} manual_status={self.manual_status}>"
CLAUDE_PATCH_EOF

mkdir -p "$APP_DIR/app/models"
cat > "$APP_DIR/app/models/booking.py" << 'CLAUDE_PATCH_EOF'
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

    def __repr__(self):  # pragma: no cover
        return f"<Booking {self.name} {self.start_datetime} [{self.status}]>"
CLAUDE_PATCH_EOF

mkdir -p "$APP_DIR/app/services"
cat > "$APP_DIR/app/services/availability.py" << 'CLAUDE_PATCH_EOF'
"""The availability engine.

Per the plan's architecture, this is the single source of truth for free
time — the calendar, the public booking page, and the status system all
read from here rather than deriving availability independently.

    Working Hours -- Breaks -- Time Off -- Bookings --> Availability Engine

Bookings aren't modeled yet (Phase 3), so `compute_available_intervals`
accepts an optional `busy_periods` list so that phase can plug straight in
without changing this function's contract.
"""

from datetime import datetime, time as dt_time, timedelta

from app import db
from app.models.availability import WorkingHours
from app.models.time_off import TimeOff

DEFAULT_START = dt_time(9, 0)
DEFAULT_END = dt_time(17, 0)


def ensure_working_hours_rows(user):
    """Create the 7 WorkingHours rows for a user if they don't exist yet.

    Defaults to Monday-Friday 09:00-17:00 enabled, weekends off — a
    reasonable starting point the user can then edit.
    """
    existing_days = {wh.day_of_week for wh in WorkingHours.query.filter_by(user_id=user.id).all()}
    created = False
    for day in range(7):
        if day in existing_days:
            continue
        is_weekday = day < 5
        db.session.add(
            WorkingHours(
                user_id=user.id,
                day_of_week=day,
                enabled=is_weekday,
                start_time=DEFAULT_START if is_weekday else None,
                end_time=DEFAULT_END if is_weekday else None,
            )
        )
        created = True
    if created:
        db.session.commit()


def subtract_intervals(base_intervals, blocking_intervals):
    """Remove every blocking interval from every base interval.

    Both are lists of (start, end) datetime tuples. Returns the remaining
    free intervals, sorted, with zero-length results dropped.
    """
    result = [iv for iv in base_intervals if iv[0] < iv[1]]

    for b_start, b_end in sorted(blocking_intervals):
        if b_start >= b_end:
            continue
        next_result = []
        for start, end in result:
            if b_end <= start or b_start >= end:
                next_result.append((start, end))
                continue
            if b_start > start:
                next_result.append((start, b_start))
            if b_end < end:
                next_result.append((b_end, end))
        result = next_result

    return sorted(result)


def _day_end_datetime(target_date, end_time):
    """Combine a working-hours end time with its calendar date.

    A stored end time of exactly midnight (00:00) means "runs until the
    end of the day", not "the day's first instant" — so it's treated as
    the following midnight rather than literally 00:00 on `target_date`,
    which would otherwise always be before the day's start time.
    """
    if end_time == dt_time(0, 0):
        return datetime.combine(target_date + timedelta(days=1), dt_time(0, 0))
    return datetime.combine(target_date, end_time)


def get_working_hours_for_day(user, target_date):
    return WorkingHours.query.filter_by(user_id=user.id, day_of_week=target_date.weekday()).first()


def get_time_off_blocks_for_day(user, target_date):
    """Time off entries that overlap the given calendar date, clipped to that day."""
    day_start = datetime.combine(target_date, dt_time.min)
    day_end = datetime.combine(target_date, dt_time.max)

    overlapping = TimeOff.query.filter(
        TimeOff.user_id == user.id,
        TimeOff.start_datetime < day_end,
        TimeOff.end_datetime > day_start,
    ).all()

    return [(max(t.start_datetime, day_start), min(t.end_datetime, day_end)) for t in overlapping]


def compute_available_intervals(user, target_date, busy_periods=None):
    """Free (start, end) datetime intervals for `user` on `target_date`.

    Order of subtraction, matching the plan:
        working hours -> breaks -> time off -> busy_periods (bookings)
    """
    working_hours = get_working_hours_for_day(user, target_date)

    if not working_hours or not working_hours.enabled or not working_hours.start_time or not working_hours.end_time:
        return []

    day_start = datetime.combine(target_date, working_hours.start_time)
    day_end = _day_end_datetime(target_date, working_hours.end_time)
    if day_start >= day_end:
        return []

    intervals = [(day_start, day_end)]

    break_blocks = [
        (datetime.combine(target_date, b.start_time), datetime.combine(target_date, b.end_time))
        for b in working_hours.breaks
    ]
    intervals = subtract_intervals(intervals, break_blocks)

    intervals = subtract_intervals(intervals, get_time_off_blocks_for_day(user, target_date))

    if busy_periods:
        todays_busy = [(s, e) for s, e in busy_periods if s.date() <= target_date <= e.date()]
        intervals = subtract_intervals(intervals, todays_busy)

    return intervals


def compute_out_of_hours_intervals(user, target_date, busy_periods=None):
    """Free (start, end) datetime intervals OUTSIDE `user`'s normal working
    hours on `target_date` — the complement of compute_available_intervals.

    Still honors breaks, time off, and busy_periods (bookings) the same
    way the normal-hours computation does; only the working-hours gate
    itself is lifted. On a day marked off entirely (enabled=False), the
    whole day counts as "outside working hours".
    """
    working_hours = get_working_hours_for_day(user, target_date)
    day_full_start = datetime.combine(target_date, dt_time.min)
    day_full_end = datetime.combine(target_date + timedelta(days=1), dt_time.min)

    if working_hours and working_hours.enabled and working_hours.start_time and working_hours.end_time:
        in_hours_start = datetime.combine(target_date, working_hours.start_time)
        in_hours_end = _day_end_datetime(target_date, working_hours.end_time)
        intervals = subtract_intervals([(day_full_start, day_full_end)], [(in_hours_start, in_hours_end)])
    else:
        intervals = [(day_full_start, day_full_end)]

    if working_hours:
        break_blocks = [
            (datetime.combine(target_date, b.start_time), datetime.combine(target_date, b.end_time))
            for b in working_hours.breaks
        ]
        intervals = subtract_intervals(intervals, break_blocks)

    intervals = subtract_intervals(intervals, get_time_off_blocks_for_day(user, target_date))

    if busy_periods:
        todays_busy = [(s, e) for s, e in busy_periods if s.date() <= target_date <= e.date()]
        intervals = subtract_intervals(intervals, todays_busy)

    return intervals


def get_next_available(user, from_dt, max_days=14, busy_periods=None):
    """The first free moment at or after `from_dt`, searching up to `max_days` ahead."""
    for offset in range(max_days):
        day = (from_dt + timedelta(days=offset)).date()
        for start, end in compute_available_intervals(user, day, busy_periods=busy_periods):
            if end <= from_dt:
                continue
            return max(start, from_dt)
    return None


def get_public_week_overview(user, start_date, days=7):
    """A privacy-safe day-by-day summary for the public status page.

    Deliberately exposes only enough to answer "when are they free" — never
    booking details, and never a time-off entry's private `reason` text.
    Each day is one of: 'available', 'off' (not a working day), 'unavailable'
    (a working day fully blocked by time off), or 'limited' (partially
    blocked by time off).
    """
    overview = []
    for offset in range(days):
        day = start_date + timedelta(days=offset)
        working_hours = get_working_hours_for_day(user, day)
        is_working_day = bool(working_hours and working_hours.enabled)
        time_off_blocks = get_time_off_blocks_for_day(user, day)

        if not is_working_day:
            state = "off"
        elif time_off_blocks:
            day_start = datetime.combine(day, working_hours.start_time)
            day_end = _day_end_datetime(day, working_hours.end_time)
            fully_blocked = any(b_start <= day_start and b_end >= day_end for b_start, b_end in time_off_blocks)
            state = "unavailable" if fully_blocked else "limited"
        else:
            state = "available"

        overview.append({"date": day, "state": state})
    return overview
CLAUDE_PATCH_EOF

mkdir -p "$APP_DIR/app/services"
cat > "$APP_DIR/app/services/booking.py" << 'CLAUDE_PATCH_EOF'
"""Turns free intervals into concrete bookable slots, and creates bookings.

Slot generation plugs straight into the Phase 2 availability engine via its
`busy_periods` argument — existing bookings (expanded by their own type's
buffers) are just another kind of blocked time, same as breaks or time off.
"""

from datetime import datetime, time as dt_time, timedelta

from app import db
from app.models.booking import ACTIVE_BOOKING_STATUSES, Booking
from app.services.availability import compute_available_intervals, compute_out_of_hours_intervals
from app.services.status import local_now


def get_busy_periods(user, range_start, range_end, exclude_booking_id=None):
    """Active bookings overlapping [range_start, range_end), each expanded by its own buffers."""
    query = Booking.query.filter(
        Booking.user_id == user.id,
        Booking.status.in_(ACTIVE_BOOKING_STATUSES),
        Booking.start_datetime < range_end,
        Booking.end_datetime > range_start,
    )
    if exclude_booking_id:
        query = query.filter(Booking.id != exclude_booking_id)

    busy = []
    for booking in query.all():
        bt = booking.booking_type
        before = timedelta(minutes=bt.buffer_before) if bt else timedelta()
        after = timedelta(minutes=bt.buffer_after) if bt else timedelta()
        busy.append((booking.start_datetime - before, booking.end_datetime + after))
    return busy


def _slots_from_intervals(free_intervals, booking_type, now):
    duration = timedelta(minutes=booking_type.duration)
    buffer_before = timedelta(minutes=booking_type.buffer_before)
    buffer_after = timedelta(minutes=booking_type.buffer_after)

    slots = []
    for interval_start, interval_end in free_intervals:
        cursor = interval_start
        while cursor + duration <= interval_end:
            slot_start, slot_end = cursor, cursor + duration
            # The slot's own buffer must also fit inside this free interval —
            # buffers are protected spacing, not just a display concern.
            if slot_start - buffer_before >= interval_start and slot_end + buffer_after <= interval_end:
                slots.append(slot_start)
            cursor += duration

    return [s for s in slots if s > now]


def get_available_slots(user, booking_type, target_date):
    """Bookable start times for `booking_type` on `target_date`, within normal working hours."""
    if not booking_type.enabled:
        return []

    day_start = datetime.combine(target_date, dt_time.min)
    day_end = datetime.combine(target_date, dt_time.max)
    busy = get_busy_periods(user, day_start, day_end)

    free_intervals = compute_available_intervals(user, target_date, busy_periods=busy)
    return _slots_from_intervals(free_intervals, booking_type, local_now(user))


def get_out_of_hours_slots(user, booking_type, target_date):
    """Bookable start times for `booking_type` on `target_date`, OUTSIDE
    normal working hours — only meaningful when the owner has out-of-hours
    bookings enabled (see Settings.allow_out_of_hours_bookings); callers
    are responsible for checking that flag before offering these.
    """
    if not booking_type.enabled:
        return []

    day_start = datetime.combine(target_date, dt_time.min)
    day_end = datetime.combine(target_date, dt_time.max)
    busy = get_busy_periods(user, day_start, day_end)

    free_intervals = compute_out_of_hours_intervals(user, target_date, busy_periods=busy)
    return _slots_from_intervals(free_intervals, booking_type, local_now(user))


class SlotUnavailableError(Exception):
    pass


def create_booking(user, booking_type, start_dt, name, email, phone, notes, is_out_of_hours=False, out_of_hours_fee_shown=None):
    """Creates a booking after re-confirming the slot is still free.

    Re-checking here (rather than trusting the slot the person clicked a
    minute ago) closes the obvious race: two people booking the same slot
    at nearly the same time. For an out-of-hours slot, the re-check looks
    at the out-of-hours intervals rather than normal working hours —
    otherwise every out-of-hours booking would fail this check by design.
    """
    end_dt = start_dt + timedelta(minutes=booking_type.duration)

    buffer_before = timedelta(minutes=booking_type.buffer_before)
    buffer_after = timedelta(minutes=booking_type.buffer_after)
    check_start = start_dt - buffer_before
    check_end = end_dt + buffer_after

    busy = get_busy_periods(user, check_start, check_end)
    if is_out_of_hours:
        still_free = compute_out_of_hours_intervals(user, start_dt.date(), busy_periods=busy)
    else:
        still_free = compute_available_intervals(user, start_dt.date(), busy_periods=busy)

    if not any(iv_start <= check_start and check_end <= iv_end for iv_start, iv_end in still_free):
        raise SlotUnavailableError("That time is no longer available.")

    booking = Booking(
        user_id=user.id,
        booking_type_id=booking_type.id,
        name=name.strip(),
        email=email.strip().lower(),
        phone=(phone or "").strip() or None,
        notes=(notes or "").strip() or None,
        start_datetime=start_dt,
        end_datetime=end_dt,
        status="confirmed",
        is_out_of_hours=is_out_of_hours,
        out_of_hours_fee_shown=out_of_hours_fee_shown if is_out_of_hours else None,
    )
    db.session.add(booking)
    db.session.commit()
    return booking
CLAUDE_PATCH_EOF

mkdir -p "$APP_DIR/app"
cat > "$APP_DIR/app/forms.py" << 'CLAUDE_PATCH_EOF'
from flask_wtf import FlaskForm
from wtforms import (
    BooleanField,
    DateField,
    HiddenField,
    IntegerField,
    PasswordField,
    SelectField,
    StringField,
    TextAreaField,
    TimeField,
)
from wtforms.validators import DataRequired, Email, Length, NumberRange, Optional, ValidationError

from app.models.settings import MANUAL_STATUSES


class LoginForm(FlaskForm):
    email = StringField(
        "Email",
        validators=[DataRequired(message="Enter your email."), Email(message="Enter a valid email.")],
    )
    password = PasswordField(
        "Password",
        validators=[DataRequired(message="Enter your password.")],
    )
    remember_me = BooleanField("Keep me signed in")


class CSRFOnlyForm(FlaskForm):
    """Used for pages/actions that need CSRF protection but no real fields."""

    pass


class BreakForm(FlaskForm):
    day_of_week = HiddenField(validators=[DataRequired()])
    label = StringField(
        "Label", validators=[DataRequired(message="Give the break a label."), Length(max=120)], default="Lunch"
    )
    start_time = TimeField("Starts", validators=[DataRequired(message="Enter a start time.")])
    end_time = TimeField("Ends", validators=[DataRequired(message="Enter an end time.")])

    def validate_end_time(self, field):
        if self.start_time.data and field.data and field.data <= self.start_time.data:
            raise ValidationError("End time must be after the start time.")


class TimeOffForm(FlaskForm):
    start_date = DateField("Start date", validators=[DataRequired(message="Enter a start date.")])
    end_date = DateField("End date", validators=[DataRequired(message="Enter an end date.")])
    all_day = BooleanField("All day", default=True)
    start_time = TimeField("Starts", validators=[Optional()])
    end_time = TimeField("Ends", validators=[Optional()])
    reason = StringField("Reason", validators=[Optional(), Length(max=255)])

    def validate_end_date(self, field):
        if self.start_date.data and field.data and field.data < self.start_date.data:
            raise ValidationError("End date can't be before the start date.")
        # A guard rail against exactly the kind of typo that's easy to make
        # in a date field — e.g. "2023" instead of "2026" — which silently
        # creates a multi-year time-off block instead of the intended
        # one-week entry. A year mismatch produces a huge, obviously-wrong
        # span, so this catches it without limiting genuine long entries
        # (e.g. a multi-month sabbatical) that stay within a normal range.
        if self.start_date.data and field.data:
            span_days = (field.data - self.start_date.data).days
            if span_days > 366:
                raise ValidationError(
                    f"That's a {span_days}-day span — did you mean a different year? "
                    "Double check the start and end dates."
                )

    def validate(self, extra_validators=None):
        # Optional() on start_time/end_time stops WTForms' per-field validator
        # chain as soon as a field is empty, which would also skip an inline
        # validate_end_time(self, field) method — so the "required unless
        # all_day" and "end after start" checks live here instead, run after
        # the normal per-field validation has already populated .data.
        if not super().validate(extra_validators=extra_validators):
            return False

        if not self.all_day.data:
            if not self.start_time.data or not self.end_time.data:
                self.end_time.errors.append("Enter both a start and end time, or mark this as all day.")
                return False
            if self.start_date.data == self.end_date.data and self.end_time.data <= self.start_time.data:
                self.end_time.errors.append("End time must be after the start time.")
                return False

        return True


class StatusOverrideForm(FlaskForm):
    manual_status = SelectField(
        "Status",
        choices=[("", "Automatic (based on working hours)")] + [(s, s.capitalize()) for s in MANUAL_STATUSES],
        validators=[Optional()],
    )
    manual_status_message = StringField("Message", validators=[Optional(), Length(max=255)])


class BookingTypeForm(FlaskForm):
    name = StringField("Name", validators=[DataRequired(message="Give it a name."), Length(max=120)])
    description = TextAreaField("Description", validators=[Optional(), Length(max=500)])
    duration = IntegerField(
        "Duration (minutes)",
        validators=[DataRequired(message="Enter a duration."), NumberRange(min=5, max=480, message="5–480 minutes.")],
    )
    buffer_before = IntegerField(
        "Buffer before (minutes)",
        default=0,
        validators=[Optional(), NumberRange(min=0, max=240)],
    )
    buffer_after = IntegerField(
        "Buffer after (minutes)",
        default=0,
        validators=[Optional(), NumberRange(min=0, max=240)],
    )
    enabled = BooleanField("Enabled", default=True)


class PublicBookingDetailsForm(FlaskForm):
    name = StringField("Name", validators=[DataRequired(message="Enter your name."), Length(max=120)])
    email = StringField(
        "Email",
        validators=[DataRequired(message="Enter your email."), Email(message="Enter a valid email.")],
    )
    phone = StringField("Phone (optional)", validators=[Optional(), Length(max=40)])
    notes = TextAreaField("Notes (optional)", validators=[Optional(), Length(max=1000)])
    # Requiredness depends on whether the selected slot is out-of-hours and
    # a fee is configured — checked in the route, not here (a field-level
    # Optional() would short-circuit a conditional required-check anyway).
    consent_out_of_hours_fee = BooleanField("I understand an out-of-hours fee applies to this booking and I agree to it.")


class ProfileForm(FlaskForm):
    name = StringField("Name", validators=[DataRequired(message="Enter your name."), Length(max=120)])
    timezone = SelectField("Timezone", validators=[DataRequired()])


class NotificationSettingsForm(FlaskForm):
    notify_on_new_booking = BooleanField("Email me when someone books time with me")
    notify_on_cancellation = BooleanField("Email me when someone cancels a booking")


class CurrentTaskForm(FlaskForm):
    current_task = StringField(
        "What are you working on right now?",
        validators=[Optional(), Length(max=255)],
    )


class CreateCalendarForm(FlaskForm):
    name = StringField(
        "Calendar name",
        validators=[Optional(), Length(max=120)],
        default="My Calendar",
    )


def _pin_validators():
    return [
        DataRequired(message="Enter a PIN."),
        Length(min=4, max=6, message="PIN must be 4-6 digits."),
    ]


class SetupAccessForm(FlaskForm):
    """First-time setup: register an email and choose a PIN for a calendar."""

    email = StringField(
        "Email", validators=[DataRequired(message="Enter your email."), Email(message="Enter a valid email.")]
    )
    pin = StringField("Choose a PIN", validators=_pin_validators())
    confirm_pin = StringField("Confirm PIN", validators=_pin_validators())

    def validate_pin(self, field):
        if not field.data.isdigit():
            raise ValidationError("PIN must be numbers only.")

    def validate_confirm_pin(self, field):
        if field.data != self.pin.data:
            raise ValidationError("PINs don't match.")


class PinLoginForm(FlaskForm):
    """Returning visitor: this browser is already recognized, just need the PIN."""

    pin = StringField("PIN", validators=_pin_validators())


class RecoverCalendarForm(FlaskForm):
    email = StringField(
        "Email", validators=[DataRequired(message="Enter your email."), Email(message="Enter a valid email.")]
    )


class CalendarEventForm(FlaskForm):
    title = StringField("Title", validators=[DataRequired(message="Enter a title."), Length(max=200)])
    event_date = DateField("Date", validators=[DataRequired(message="Enter a date.")])
    start_time = TimeField("Start time (optional)", validators=[Optional()])
    end_time = TimeField("End time (optional)", validators=[Optional()])
    notes = TextAreaField("Notes (optional)", validators=[Optional(), Length(max=1000)])

    def validate_end_time(self, field):
        if self.start_time.data and field.data and field.data <= self.start_time.data:
            raise ValidationError("End time must be after the start time.")


def _must_be_checked(message):
    def _validator(form, field):
        if not field.data:
            raise ValidationError(message)
    return _validator


# Common UK residential/business ISPs, for the dropdown on the ISP support
# form. Not an exhaustive or official regulator-published list — Ofcom
# doesn't publish one — there are 100+ smaller and regional providers, so
# "Other" with a free-text fallback (isp_name_other, below) always covers
# anyone not listed here.
UK_ISP_CHOICES = [
    ("", "Select your ISP\u2026"),
    ("BT", "BT"),
    ("Sky", "Sky"),
    ("Virgin Media", "Virgin Media"),
    ("TalkTalk", "TalkTalk"),
    ("EE", "EE"),
    ("Vodafone", "Vodafone"),
    ("Plusnet", "Plusnet"),
    ("NOW Broadband", "NOW Broadband"),
    ("Zen Internet", "Zen Internet"),
    ("Hyperoptic", "Hyperoptic"),
    ("Community Fibre", "Community Fibre"),
    ("Gigaclear", "Gigaclear"),
    ("YouFibre", "YouFibre"),
    ("Toob", "Toob"),
    ("Trooli", "Trooli"),
    ("Giganet", "Giganet"),
    ("Brsk", "Brsk"),
    ("Wessex Internet", "Wessex Internet"),
    ("Shell Energy Broadband", "Shell Energy Broadband"),
    ("Utility Warehouse", "Utility Warehouse"),
    ("Onestream", "Onestream"),
    ("other", "Other (type below)"),
]


class ISPSupportForm(FlaskForm):
    """Public request form for the ISP Support & Customer Authorisation flow.

    Only full name, ISP name, and the problem description are required —
    everything else is exactly what the policy says to collect only if
    the ISP has actually asked for it. There is deliberately no password
    or one-time-code field anywhere on this form.
    """

    full_name = StringField(
        "Full name on the account", validators=[DataRequired(message="Enter the name on the account."), Length(max=200)]
    )
    email = StringField("Email address", validators=[Optional(), Email(message="Enter a valid email."), Length(max=255)])
    phone = StringField("Contact telephone number", validators=[Optional(), Length(max=50)])
    isp_name = SelectField(
        "ISP / Internet Service Provider name",
        choices=UK_ISP_CHOICES,
        validators=[DataRequired(message="Select or enter your ISP.")],
    )
    isp_name_other = StringField(
        "If your ISP isn't listed, enter its name", validators=[Length(max=200)]
    )
    problem_description = TextAreaField(
        "Describe the internet/service problem",
        validators=[DataRequired(message="Briefly describe the problem."), Length(max=4000)],
    )

    def validate_isp_name_other(self, field):
        if self.isp_name.data == "other" and not (field.data or "").strip():
            raise ValidationError("Enter your ISP's name.")

    account_number = StringField("Account or customer number", validators=[Optional(), Length(max=200)])
    customer_number = StringField("Customer number (if different)", validators=[Optional(), Length(max=200)])
    full_address = StringField("Full address / service address", validators=[Optional(), Length(max=500)])
    service_address = StringField("Service address, if different", validators=[Optional(), Length(max=500)])
    date_of_birth = StringField("Date of birth (only if your ISP requires it)", validators=[Optional(), Length(max=50)])
    last_bill_date = StringField("Date of your most recent bill", validators=[Optional(), Length(max=50)])
    last_bill_amount = StringField("Amount of your most recent bill", validators=[Optional(), Length(max=50)])

    mothers_maiden_name = StringField(
        "Mother's maiden name (only if specifically required by your ISP)", validators=[Optional(), Length(max=200)]
    )
    childhood_nickname = StringField(
        "Childhood nickname (only if specifically required by your ISP)", validators=[Optional(), Length(max=200)]
    )
    security_question = StringField("Security question your ISP asks (if any)", validators=[Optional(), Length(max=255)])
    security_answer = StringField("Answer to that security question", validators=[Optional(), Length(max=500)])
    other_security_info = TextAreaField(
        "Any other security information your ISP specifically requires", validators=[Optional(), Length(max=2000)]
    )

    consent_authorised = BooleanField(
        "I am authorised to provide this information.",
        validators=[_must_be_checked("Please confirm you're authorised to provide this information.")],
    )
    consent_accurate = BooleanField(
        "The information I've provided is accurate to the best of my knowledge.",
        validators=[_must_be_checked("Please confirm the information is accurate.")],
    )
    consent_purpose = BooleanField(
        "I consent to this information being used solely to contact my ISP and assist with my internet service problem.",
        validators=[_must_be_checked("Please confirm you consent to this use of your information.")],
    )
    consent_additional_verification = BooleanField(
        "I understand that additional verification may need to be completed by me directly with my ISP.",
        validators=[_must_be_checked("Please confirm you understand this.")],
    )
    consent_no_password_request = BooleanField(
        "I understand I will never be asked for my ISP password or one-time authentication codes through this form.",
        validators=[_must_be_checked("Please confirm you understand this.")],
    )
    consent_out_of_hours_fee = BooleanField(
        "I understand an out-of-hours fee applies to this request and I agree to it.",
        validators=[Optional()],
    )


class SupportRequestStatusForm(FlaskForm):
    status = SelectField(
        "Status",
        choices=[("new", "New"), ("contacted", "ISP contacted"), ("verifying", "Awaiting your verification"),
                 ("resolved", "Resolved"), ("closed", "Closed")],
        validators=[DataRequired()],
    )
    admin_notes = TextAreaField("Internal notes", validators=[Optional(), Length(max=4000)])


class SupportRequestLookupForm(FlaskForm):
    reference = StringField(
        "Reference code", validators=[DataRequired(message="Enter the reference code from your confirmation."), Length(max=12)]
    )
    email = StringField(
        "Email address used on the request",
        validators=[DataRequired(message="Enter the email you used."), Email(message="Enter a valid email.")],
    )


class ISPFeeForm(FlaskForm):
    isp_out_of_hours_fee = StringField(
        "Out-of-hours fee (shown to customers, e.g. \u00a345)",
        validators=[Optional(), Length(max=30)],
    )


class BookingOutOfHoursForm(FlaskForm):
    allow_out_of_hours_bookings = BooleanField("Allow bookings outside my working hours")
    out_of_hours_booking_fee = StringField(
        "Out-of-hours fee (shown to customers, e.g. \u00a325)",
        validators=[Optional(), Length(max=30)],
    )
CLAUDE_PATCH_EOF

mkdir -p "$APP_DIR/app/routes"
cat > "$APP_DIR/app/routes/public.py" << 'CLAUDE_PATCH_EOF'
from datetime import date, datetime, timedelta

from flask import Blueprint, abort, current_app, flash, jsonify, redirect, render_template, request, url_for

from app import db
from app.forms import PublicBookingDetailsForm
from app.models.availability import WorkingHours
from app.models.booking import Booking, BookingType
from app.models.settings import Settings
from app.models.time_off import TimeOff
from app.models.user import User
from app.services.booking import SlotUnavailableError, create_booking, get_available_slots, get_out_of_hours_slots
from app.services.notifications import notify_cancelled_booking, notify_new_booking
from app.services.status import get_current_status, local_now
from app.services.availability import get_public_week_overview

public_bp = Blueprint("public", __name__)

MAX_DAYS_AHEAD = 60


def _get_owner_or_404():
    owner = User.get_primary()
    if owner is None:
        abort(404)
    return owner


def _parse_date_param(raw, default):
    if not raw:
        return default
    try:
        return date.fromisoformat(raw)
    except ValueError:
        return default


@public_bp.route("/")
def index():
    # The bare domain should land customers on the booking page, not a
    # 404 or the admin sign-in screen — that's the page anyone sharing
    # just "scheduler.opslabsystems.cloud" actually means.
    return redirect(url_for("public.booking_types"))


@public_bp.route("/book")
def booking_types():
    owner = _get_owner_or_404()
    types = BookingType.query.filter_by(user_id=owner.id, enabled=True).order_by(BookingType.duration).all()
    return render_template("public/booking_types.html", owner=owner, types=types)


@public_bp.route("/book/<int:type_id>")
def pick_slot(type_id):
    owner = _get_owner_or_404()
    booking_type = BookingType.query.filter_by(id=type_id, user_id=owner.id, enabled=True).first_or_404()

    today = local_now(owner).date()
    max_date = today + timedelta(days=MAX_DAYS_AHEAD)
    target_date = _parse_date_param(request.args.get("date"), today)
    if target_date < today:
        target_date = today
    if target_date > max_date:
        target_date = max_date

    slots = get_available_slots(owner, booking_type, target_date)

    settings_row = Settings.for_user(owner)
    ooh_fee = settings_row.out_of_hours_booking_fee if settings_row.allow_out_of_hours_bookings else None
    ooh_slots = (
        get_out_of_hours_slots(owner, booking_type, target_date)
        if settings_row.allow_out_of_hours_bookings
        else []
    )

    return render_template(
        "public/pick_slot.html",
        owner=owner,
        booking_type=booking_type,
        target_date=target_date,
        today=today,
        max_date=max_date,
        prev_date=target_date - timedelta(days=1),
        next_date=target_date + timedelta(days=1),
        slots=slots,
        ooh_slots=ooh_slots,
        ooh_fee=ooh_fee,
    )


@public_bp.route("/book/<int:type_id>/details", methods=["GET", "POST"])
def booking_details(type_id):
    owner = _get_owner_or_404()
    booking_type = BookingType.query.filter_by(id=type_id, user_id=owner.id, enabled=True).first_or_404()

    dt_raw = request.args.get("dt") or request.form.get("dt")
    try:
        start_dt = datetime.fromisoformat(dt_raw)
    except (TypeError, ValueError):
        abort(400)

    settings_row = Settings.for_user(owner)
    in_hours_slots = get_available_slots(owner, booking_type, start_dt.date())
    is_out_of_hours = False

    if start_dt not in in_hours_slots:
        if settings_row.allow_out_of_hours_bookings and start_dt in get_out_of_hours_slots(
            owner, booking_type, start_dt.date()
        ):
            is_out_of_hours = True
        else:
            # Bounce back to slot picking if this exact time isn't offered
            # anymore (e.g. someone else just booked it, or it's now in the
            # past).
            flash("That time isn't available anymore — please pick another.", "error")
            return redirect(url_for("public.pick_slot", type_id=type_id, date=start_dt.date().isoformat()))

    ooh_fee = settings_row.out_of_hours_booking_fee if is_out_of_hours else None

    form = PublicBookingDetailsForm()

    if form.validate_on_submit():
        if is_out_of_hours and ooh_fee and not form.consent_out_of_hours_fee.data:
            flash(f"Please confirm you accept the {ooh_fee} out-of-hours fee to continue.", "error")
        else:
            try:
                booking = create_booking(
                    owner,
                    booking_type,
                    start_dt,
                    form.name.data,
                    form.email.data,
                    form.phone.data,
                    form.notes.data,
                    is_out_of_hours=is_out_of_hours,
                    out_of_hours_fee_shown=ooh_fee,
                )
            except SlotUnavailableError:
                flash("That time was just booked by someone else — please pick another.", "error")
                return redirect(url_for("public.pick_slot", type_id=type_id, date=start_dt.date().isoformat()))

            notify_new_booking(booking)
            return redirect(url_for("public.confirmation", token=booking.manage_token))

    return render_template(
        "public/booking_details.html",
        owner=owner,
        booking_type=booking_type,
        start_dt=start_dt,
        dt_raw=dt_raw,
        form=form,
        is_out_of_hours=is_out_of_hours,
        ooh_fee=ooh_fee,
    )


@public_bp.route("/book/confirmation/<token>")
def confirmation(token):
    booking = Booking.query.filter_by(manage_token=token).first_or_404()
    return render_template("public/confirmation.html", booking=booking)


@public_bp.route("/book/manage/<token>", methods=["GET", "POST"])
def manage_booking(token):
    booking = Booking.query.filter_by(manage_token=token).first_or_404()

    if request.method == "POST":
        if booking.status == "cancelled":
            flash("This booking is already cancelled.", "info")
        else:
            booking.status = "cancelled"
            booking.cancelled_at = datetime.utcnow()
            db.session.commit()
            notify_cancelled_booking(booking, cancelled_by="guest")
            flash("Your booking has been cancelled.", "success")
        return redirect(url_for("public.manage_booking", token=token))

    return render_template("public/manage_booking.html", booking=booking)


@public_bp.route("/status")
def status_page():
    owner = _get_owner_or_404()
    status = get_current_status(owner)
    has_bookable_types = BookingType.query.filter_by(user_id=owner.id, enabled=True).first() is not None

    today = local_now(owner).date()
    week_overview = get_public_week_overview(owner, today, days=7)

    working_hours = (
        WorkingHours.query.filter_by(user_id=owner.id).order_by(WorkingHours.day_of_week).all()
    )

    range_start = datetime.combine(today, datetime.min.time())
    range_end = datetime.combine(today + timedelta(days=90), datetime.max.time())
    upcoming_time_off = (
        TimeOff.query.filter(
            TimeOff.user_id == owner.id,
            TimeOff.end_datetime > range_start,
            TimeOff.start_datetime < range_end,
        )
        .order_by(TimeOff.start_datetime)
        .limit(5)
        .all()
    )

    return render_template(
        "public/status.html",
        owner=owner,
        status=status,
        has_bookable_types=has_bookable_types,
        today=today,
        week_overview=week_overview,
        working_hours=working_hours,
        upcoming_time_off=upcoming_time_off,
        local_time_display=local_now(owner).strftime("%H:%M"),
    )


@public_bp.route("/api/status")
def api_status():
    """JSON status feed for the embeddable widget. CORS-open by design —
    this is meant to be fetched from arbitrary third-party sites, same as
    the plan's <script src="https://mydomain.com/widget.js"> example."""
    owner = _get_owner_or_404()
    status = get_current_status(owner)
    has_bookable_types = BookingType.query.filter_by(user_id=owner.id, enabled=True).first() is not None

    response = jsonify(
        {
            "name": owner.name,
            "status": status["status"],
            "message": status["message"],
            "next_available": status["next_available"],
            "book_url": url_for("public.booking_types", _external=True) if has_bookable_types else None,
            "status_url": url_for("public.status_page", _external=True),
        }
    )
    response.headers["Access-Control-Allow-Origin"] = "*"
    response.headers["Cache-Control"] = "no-store"
    return response


@public_bp.route("/widget.js")
def widget_script():
    response = current_app.send_static_file("js/widget.js")
    response.headers["Access-Control-Allow-Origin"] = "*"
    response.headers["Cache-Control"] = "public, max-age=3600"
    return response


@public_bp.route("/task")
def current_task_page():
    """Deliberately minimal: shows only the current-task text, nothing else
    — no name, no avatar, no schedule, no booking link. A separate page
    from /status on purpose, for anyone who wants to share "what I'm doing"
    without sharing who they are or when they're free."""
    owner = _get_owner_or_404()
    settings = Settings.for_user(owner)
    return render_template("public/task.html", current_task=settings.current_task)
CLAUDE_PATCH_EOF

mkdir -p "$APP_DIR/app/routes"
cat > "$APP_DIR/app/routes/admin.py" << 'CLAUDE_PATCH_EOF'
from datetime import datetime, time as dt_time, timedelta, timezone as dt_timezone

from flask import Blueprint, abort, flash, redirect, render_template, request, url_for
from flask_login import current_user, login_required

from app import db
from app.forms import BookingOutOfHoursForm, BookingTypeForm, BreakForm, CSRFOnlyForm, CurrentTaskForm, ISPFeeForm, NotificationSettingsForm, ProfileForm, StatusOverrideForm, TimeOffForm
from app.models.availability import DAY_NAMES, Break, WorkingHours
from app.models.booking import ACTIVE_BOOKING_STATUSES, Booking, BookingType
from app.models.settings import MANUAL_STATUSES, Settings
from app.models.time_off import TimeOff
from app.services.availability import ensure_working_hours_rows
from app.services.calendar import build_month_grid
from app.services.notifications import notify_cancelled_booking
from app.services.status import get_current_status, local_now

admin_bp = Blueprint("admin", __name__, url_prefix="/admin")


@admin_bp.after_request
def no_cache_admin_pages(response):
    # Without this, a browser's back-forward cache (or an overeager reverse
    # proxy) can restore a PRE-save snapshot of a page verbatim when the
    # person navigates away and back — looking exactly like "the save
    # didn't work" even though it did. Admin pages always reflect live data,
    # so nothing here should ever be served from cache.
    response.headers["Cache-Control"] = "no-store, no-cache, must-revalidate, max-age=0"
    response.headers["Pragma"] = "no-cache"
    return response


@admin_bp.before_request
@login_required
def ensure_schedule_exists():
    # Every admin page assumes 7 WorkingHours rows exist (enabled/disabled,
    # not just "no row yet") — create them on first admin visit rather than
    # only when the Availability page happens to be opened first.
    ensure_working_hours_rows(current_user)


@admin_bp.route("/")
@login_required
def dashboard():
    status = get_current_status(current_user)
    override_form = StatusOverrideForm(
        manual_status=status["status"] if status["is_manual"] else "",
        manual_status_message=status["message"] if status["is_manual"] else "",
    )
    today = datetime.combine(local_now(current_user).date(), dt_time.min)
    tomorrow = today + timedelta(days=1)
    week_end = today + timedelta(days=7)
    now = local_now(current_user)

    active = Booking.query.filter(Booking.user_id == current_user.id, Booking.status.in_(ACTIVE_BOOKING_STATUSES))
    todays_bookings = active.filter(Booking.start_datetime >= today, Booking.start_datetime < tomorrow).count()
    week_bookings = active.filter(Booking.start_datetime >= today, Booking.start_datetime < week_end).count()
    next_booking = (
        active.filter(Booking.start_datetime >= now)
        .order_by(Booking.start_datetime.asc())
        .first()
    )
    stats = {
        "todays_bookings": todays_bookings,
        "week_bookings": week_bookings,
        "next_booking": (
            f"{next_booking.name} · {next_booking.start_datetime.strftime('%a %d %b at %H:%M')}"
            if next_booking
            else None
        ),
    }
    return render_template(
        "admin/dashboard.html",
        status=status,
        stats=stats,
        override_form=override_form,
        task_form=CurrentTaskForm(current_task=Settings.for_user(current_user).current_task),
        active_page="dashboard",
    )


@admin_bp.route("/current-task", methods=["POST"])
@login_required
def update_current_task():
    form = CurrentTaskForm()
    if form.validate_on_submit():
        settings_row = Settings.for_user(current_user)
        settings_row.current_task = form.current_task.data.strip() if form.current_task.data else None
        db.session.commit()
        flash(
            "Current task updated." if settings_row.current_task else "Current task cleared.",
            "success",
        )
    else:
        for field_errors in form.errors.values():
            for err in field_errors:
                flash(err, "error")
    return redirect(url_for("admin.dashboard"))


@admin_bp.route("/status", methods=["POST"])
@login_required
def update_status():
    form = StatusOverrideForm()
    if form.validate_on_submit():
        settings = Settings.for_user(current_user)
        chosen = form.manual_status.data or None
        settings.manual_status = chosen
        settings.manual_status_message = form.manual_status_message.data.strip() if chosen else None
        settings.manual_status_expires_at = None
        db.session.commit()
        flash("Back to automatic status." if not chosen else f"Status set to {chosen}.", "success")
    else:
        flash("Couldn't update your status — please try again.", "error")
    return redirect(url_for("admin.dashboard"))


@admin_bp.route("/availability", methods=["GET", "POST"])
@login_required
def availability():
    ensure_working_hours_rows(current_user)
    csrf_form = CSRFOnlyForm()
    break_form = BreakForm()

    if request.method == "POST":
        if not csrf_form.validate_on_submit():
            # Previously this silently fell through to a plain re-render with
            # no explanation, which looks exactly like "save doesn't work" —
            # now it's an explicit, visible failure instead of a quiet no-op.
            flash(
                "Your save wasn't accepted (your session may have expired). "
                "Please refresh the page and try again.",
                "error",
            )
            return redirect(url_for("admin.availability"))

        rows = WorkingHours.query.filter_by(user_id=current_user.id).all()
        by_day = {wh.day_of_week: wh for wh in rows}
        errors = []
        # Snapshot of exactly what was submitted, keyed by day, so that if we
        # bounce back to the form with errors we re-render what the person
        # actually typed — not stale DB values that happen to look "fine"
        # and make the error message look wrong.
        submitted = {}

        for day in range(7):
            wh = by_day[day]
            enabled = request.form.get(f"day_{day}_enabled") == "on"
            start_raw = request.form.get(f"day_{day}_start", "").strip()
            end_raw = request.form.get(f"day_{day}_end", "").strip()
            submitted[day] = {"enabled": enabled, "start": start_raw, "end": end_raw}

            wh.enabled = enabled
            if not enabled:
                continue

            try:
                start_time = dt_time.fromisoformat(start_raw)
                end_time = dt_time.fromisoformat(end_raw)
            except ValueError:
                errors.append(f"{DAY_NAMES[day]}: enter valid start and end times.")
                continue

            if end_time <= start_time and end_time != dt_time(0, 0):
                errors.append(
                    f"{DAY_NAMES[day]}: end time must be after start time "
                    f"({start_raw or '?'}\u2013{end_raw or '?'} given)."
                )
                continue

            wh.start_time = start_time
            wh.end_time = end_time

        # Commit whatever validated cleanly regardless of errors on other
        # days — a typo on Saturday shouldn't discard edits you made to
        # every other day. Days that failed validation keep their previous
        # saved times untouched.
        db.session.commit()

        if errors:
            for e in errors:
                flash(e, "error")
            flash(
                "Days without an error above were saved. Fix the "
                "highlighted day(s) and save again.",
                "info",
            )
            working_hours = (
                WorkingHours.query.filter_by(user_id=current_user.id)
                .order_by(WorkingHours.day_of_week)
                .all()
            )
            return render_template(
                "admin/availability.html",
                working_hours=working_hours,
                csrf_form=csrf_form,
                break_form=break_form,
                active_page="availability",
                form_state=submitted,
            )

        flash("Working hours updated.", "success")
        return redirect(url_for("admin.availability"))

    working_hours = (
        WorkingHours.query.filter_by(user_id=current_user.id).order_by(WorkingHours.day_of_week).all()
    )
    return render_template(
        "admin/availability.html",
        working_hours=working_hours,
        csrf_form=csrf_form,
        break_form=break_form,
        active_page="availability",
        form_state=None,
    )


@admin_bp.route("/availability/breaks", methods=["POST"])
@login_required
def add_break():
    form = BreakForm()
    if form.validate_on_submit():
        wh = WorkingHours.query.filter_by(
            user_id=current_user.id, day_of_week=int(form.day_of_week.data)
        ).first_or_404()
        db.session.add(
            Break(
                working_hours_id=wh.id,
                label=form.label.data.strip() or "Break",
                start_time=form.start_time.data,
                end_time=form.end_time.data,
            )
        )
        db.session.commit()
        flash(f"Break added to {wh.day_name}.", "success")
    else:
        for field_errors in form.errors.values():
            for err in field_errors:
                flash(err, "error")
    return redirect(url_for("admin.availability"))


@admin_bp.route("/availability/breaks/<int:break_id>/delete", methods=["POST"])
@login_required
def delete_break(break_id):
    br = Break.query.join(WorkingHours).filter(
        Break.id == break_id, WorkingHours.user_id == current_user.id
    ).first_or_404()
    db.session.delete(br)
    db.session.commit()
    flash("Break removed.", "success")
    return redirect(url_for("admin.availability"))


@admin_bp.route("/time-off", methods=["GET", "POST"])
@login_required
def time_off():
    form = TimeOffForm()

    if form.validate_on_submit():
        if form.all_day.data:
            start_dt = datetime.combine(form.start_date.data, dt_time.min)
            end_dt = datetime.combine(form.end_date.data, dt_time.max)
        else:
            start_dt = datetime.combine(form.start_date.data, form.start_time.data)
            end_dt = datetime.combine(form.end_date.data, form.end_time.data)

        db.session.add(
            TimeOff(
                user_id=current_user.id,
                start_datetime=start_dt,
                end_datetime=end_dt,
                all_day=form.all_day.data,
                reason=form.reason.data.strip() if form.reason.data else None,
            )
        )
        db.session.commit()
        flash("Time off added.", "success")
        return redirect(url_for("admin.time_off"))

    entries = (
        TimeOff.query.filter_by(user_id=current_user.id)
        .order_by(TimeOff.start_datetime.desc())
        .all()
    )
    return render_template(
        "admin/time_off.html", entries=entries, form=form, active_page="time_off"
    )


@admin_bp.route("/time-off/<int:time_off_id>/delete", methods=["POST"])
@login_required
def delete_time_off(time_off_id):
    entry = TimeOff.query.filter_by(id=time_off_id, user_id=current_user.id).first_or_404()
    db.session.delete(entry)
    db.session.commit()
    flash("Time off removed.", "success")
    return redirect(url_for("admin.time_off"))


@admin_bp.route("/time-off/<int:time_off_id>/edit", methods=["GET", "POST"])
@login_required
def edit_time_off(time_off_id):
    entry = TimeOff.query.filter_by(id=time_off_id, user_id=current_user.id).first_or_404()

    form = TimeOffForm(
        start_date=entry.start_datetime.date(),
        end_date=entry.end_datetime.date(),
        all_day=entry.all_day,
        start_time=None if entry.all_day else entry.start_datetime.time(),
        end_time=None if entry.all_day else entry.end_datetime.time(),
        reason=entry.reason,
    )

    if form.validate_on_submit():
        if form.all_day.data:
            entry.start_datetime = datetime.combine(form.start_date.data, dt_time.min)
            entry.end_datetime = datetime.combine(form.end_date.data, dt_time.max)
        else:
            entry.start_datetime = datetime.combine(form.start_date.data, form.start_time.data)
            entry.end_datetime = datetime.combine(form.end_date.data, form.end_time.data)
        entry.all_day = form.all_day.data
        entry.reason = form.reason.data.strip() if form.reason.data else None

        db.session.commit()
        flash("Time off updated.", "success")
        return redirect(url_for("admin.time_off"))

    return render_template(
        "admin/edit_time_off.html", form=form, entry=entry, active_page="time_off"
    )


@admin_bp.route("/booking-types", methods=["GET", "POST"])
@login_required
def booking_types():
    form = BookingTypeForm()
    if form.validate_on_submit():
        db.session.add(
            BookingType(
                user_id=current_user.id,
                name=form.name.data.strip(),
                description=(form.description.data or "").strip() or None,
                duration=form.duration.data,
                buffer_before=form.buffer_before.data or 0,
                buffer_after=form.buffer_after.data or 0,
                enabled=form.enabled.data,
            )
        )
        db.session.commit()
        flash(f"Booking type '{form.name.data.strip()}' created.", "success")
        return redirect(url_for("admin.booking_types"))

    types = BookingType.query.filter_by(user_id=current_user.id).order_by(BookingType.created_at).all()
    return render_template(
        "admin/booking_types.html", types=types, form=form, active_page="booking_types"
    )


@admin_bp.route("/booking-types/<int:type_id>/edit", methods=["GET", "POST"])
@login_required
def edit_booking_type(type_id):
    bt = BookingType.query.filter_by(id=type_id, user_id=current_user.id).first_or_404()
    form = BookingTypeForm(obj=bt)

    if form.validate_on_submit():
        bt.name = form.name.data.strip()
        bt.description = (form.description.data or "").strip() or None
        bt.duration = form.duration.data
        bt.buffer_before = form.buffer_before.data or 0
        bt.buffer_after = form.buffer_after.data or 0
        bt.enabled = form.enabled.data
        db.session.commit()
        flash(f"'{bt.name}' updated.", "success")
        return redirect(url_for("admin.booking_types"))

    return render_template(
        "admin/edit_booking_type.html", form=form, booking_type=bt, active_page="booking_types"
    )


@admin_bp.route("/booking-types/<int:type_id>/toggle", methods=["POST"])
@login_required
def toggle_booking_type(type_id):
    csrf_form = CSRFOnlyForm()
    if not csrf_form.validate_on_submit():
        abort(400)
    bt = BookingType.query.filter_by(id=type_id, user_id=current_user.id).first_or_404()
    bt.enabled = not bt.enabled
    db.session.commit()
    flash(f"'{bt.name}' {'enabled' if bt.enabled else 'disabled'}.", "success")
    return redirect(url_for("admin.booking_types"))


@admin_bp.route("/booking-types/<int:type_id>/delete", methods=["POST"])
@login_required
def delete_booking_type(type_id):
    csrf_form = CSRFOnlyForm()
    if not csrf_form.validate_on_submit():
        abort(400)
    bt = BookingType.query.filter_by(id=type_id, user_id=current_user.id).first_or_404()
    if bt.bookings:
        flash(f"Can't delete '{bt.name}' — it has bookings against it. Disable it instead.", "error")
        return redirect(url_for("admin.booking_types"))
    db.session.delete(bt)
    db.session.commit()
    flash(f"'{bt.name}' deleted.", "success")
    return redirect(url_for("admin.booking_types"))


@admin_bp.route("/bookings")
@login_required
def bookings():
    filter_ = request.args.get("filter", "upcoming")
    now = local_now(current_user)
    query = Booking.query.filter_by(user_id=current_user.id)

    if filter_ == "upcoming":
        query = query.filter(
            Booking.start_datetime >= now, Booking.status.in_(ACTIVE_BOOKING_STATUSES)
        ).order_by(Booking.start_datetime.asc())
    elif filter_ == "past":
        query = query.filter(Booking.start_datetime < now).order_by(Booking.start_datetime.desc())
    elif filter_ == "cancelled":
        query = query.filter(Booking.status == "cancelled").order_by(Booking.start_datetime.desc())
    else:
        query = query.order_by(Booking.start_datetime.desc())

    entries = query.limit(200).all()
    return render_template(
        "admin/bookings.html", bookings=entries, filter=filter_, active_page="bookings"
    )


@admin_bp.route("/bookings/<int:booking_id>/cancel", methods=["POST"])
@login_required
def cancel_booking(booking_id):
    csrf_form = CSRFOnlyForm()
    if not csrf_form.validate_on_submit():
        abort(400)
    booking = Booking.query.filter_by(id=booking_id, user_id=current_user.id).first_or_404()
    if booking.status != "cancelled":
        booking.status = "cancelled"
        booking.cancelled_at = datetime.now(dt_timezone.utc).replace(tzinfo=None)
        db.session.commit()
        notify_cancelled_booking(booking, cancelled_by="admin")
        flash(f"Booking with {booking.name} cancelled.", "success")
    return redirect(request.referrer or url_for("admin.bookings"))


@admin_bp.route("/settings", methods=["GET"])
@login_required
def settings():
    from zoneinfo import available_timezones

    settings_row = Settings.for_user(current_user)
    profile_form = ProfileForm(name=current_user.name, timezone=current_user.timezone)
    profile_form.timezone.choices = [(tz, tz) for tz in sorted(available_timezones())]
    notif_form = NotificationSettingsForm(
        notify_on_new_booking=settings_row.notify_on_new_booking,
        notify_on_cancellation=settings_row.notify_on_cancellation,
    )
    isp_fee_form = ISPFeeForm(isp_out_of_hours_fee=settings_row.isp_out_of_hours_fee or "")
    booking_ooh_form = BookingOutOfHoursForm(
        allow_out_of_hours_bookings=settings_row.allow_out_of_hours_bookings,
        out_of_hours_booking_fee=settings_row.out_of_hours_booking_fee or "",
    )
    status_url = url_for("public.status_page", _external=True)
    booking_url = url_for("public.booking_types", _external=True)
    widget_url = url_for("public.widget_script", _external=True)
    return render_template(
        "admin/settings.html",
        profile_form=profile_form,
        notif_form=notif_form,
        isp_fee_form=isp_fee_form,
        booking_ooh_form=booking_ooh_form,
        active_page="settings",
        status_url=status_url,
        booking_url=booking_url,
        widget_url=widget_url,
    )


@admin_bp.route("/settings/isp-fee", methods=["POST"])
@login_required
def update_isp_fee():
    form = ISPFeeForm()
    if form.validate_on_submit():
        settings_row = Settings.for_user(current_user)
        settings_row.isp_out_of_hours_fee = form.isp_out_of_hours_fee.data.strip() or None
        db.session.commit()
        flash("Out-of-hours fee updated." if settings_row.isp_out_of_hours_fee else "Out-of-hours fee removed.", "success")
    else:
        for field_errors in form.errors.values():
            for err in field_errors:
                flash(err, "error")
    return redirect(url_for("admin.settings"))


@admin_bp.route("/settings/booking-out-of-hours", methods=["POST"])
@login_required
def update_booking_out_of_hours():
    form = BookingOutOfHoursForm()
    if form.validate_on_submit():
        settings_row = Settings.for_user(current_user)
        settings_row.allow_out_of_hours_bookings = bool(form.allow_out_of_hours_bookings.data)
        settings_row.out_of_hours_booking_fee = form.out_of_hours_booking_fee.data.strip() or None
        db.session.commit()
        flash(
            "Out-of-hours bookings are now allowed."
            if settings_row.allow_out_of_hours_bookings
            else "Out-of-hours bookings turned off.",
            "success",
        )
    else:
        for field_errors in form.errors.values():
            for err in field_errors:
                flash(err, "error")
    return redirect(url_for("admin.settings"))


@admin_bp.route("/settings/profile", methods=["POST"])
@login_required
def update_profile():
    from zoneinfo import available_timezones

    form = ProfileForm()
    form.timezone.choices = [(tz, tz) for tz in sorted(available_timezones())]

    if form.validate_on_submit():
        current_user.name = form.name.data.strip()
        current_user.timezone = form.timezone.data
        db.session.commit()
        flash("Profile updated.", "success")
    else:
        for field_errors in form.errors.values():
            for err in field_errors:
                flash(err, "error")
    return redirect(url_for("admin.settings"))


@admin_bp.route("/settings/notifications", methods=["POST"])
@login_required
def update_notifications():
    form = NotificationSettingsForm()
    if form.validate_on_submit():
        settings_row = Settings.for_user(current_user)
        settings_row.notify_on_new_booking = form.notify_on_new_booking.data
        settings_row.notify_on_cancellation = form.notify_on_cancellation.data
        db.session.commit()
        flash("Notification settings updated.", "success")
    return redirect(url_for("admin.settings"))


@admin_bp.route("/calendar")
@login_required
def calendar_view():
    today = local_now(current_user).date()
    year = request.args.get("year", type=int) or today.year
    month = request.args.get("month", type=int) or today.month
    if not (1 <= month <= 12):
        month = today.month

    days, meta = build_month_grid(current_user, year, month)
    return render_template(
        "admin/calendar.html", days=days, today=today, active_page="calendar", **meta
    )
CLAUDE_PATCH_EOF

mkdir -p "$APP_DIR/app/templates/admin"
cat > "$APP_DIR/app/templates/admin/settings.html" << 'CLAUDE_PATCH_EOF'
{% extends "layouts/admin.html" %}
{% block title %}Settings · {{ app_name }}{% endblock %}
{% block page_content %}

<div class="mb-8">
  <h1 class="font-display text-2xl font-semibold text-ink">Settings</h1>
  <p class="mt-1 text-sm text-ink-muted">Your profile and notification preferences.</p>
</div>

<div class="max-w-lg space-y-6">

  <div class="card p-6 sm:p-7">
    <h2 class="font-display text-base font-semibold text-ink mb-4">Profile</h2>
    <form method="POST" action="{{ url_for('admin.update_profile') }}" novalidate>
      {{ profile_form.hidden_tag() }}

      <div class="mb-4">
        <label class="field-label" for="{{ profile_form.name.id }}">Name</label>
        {{ profile_form.name(class_="field-input") }}
        {% for error in profile_form.name.errors %}<p class="field-error">{{ error }}</p>{% endfor %}
      </div>

      <div class="mb-5">
        <label class="field-label" for="{{ profile_form.timezone.id }}">Timezone</label>
        {{ profile_form.timezone(class_="field-input") }}
        <p class="mt-1.5 text-xs text-ink-muted">Working hours, time off, and your status are all calculated in this timezone.</p>
      </div>

      <button type="submit" class="btn-primary">Save profile</button>
    </form>
  </div>

  <div class="card p-6 sm:p-7">
    <h2 class="font-display text-base font-semibold text-ink mb-4">Email notifications</h2>
    <form method="POST" action="{{ url_for('admin.update_notifications') }}" novalidate>
      {{ notif_form.hidden_tag() }}

      <label class="mb-3 flex items-start gap-2.5 text-sm text-ink-muted">
        {{ notif_form.notify_on_new_booking(class_="mt-0.5 rounded border-border bg-surface-raised text-accent focus:ring-accent focus:ring-offset-base") }}
        {{ notif_form.notify_on_new_booking.label.text }}
      </label>
      <label class="mb-5 flex items-start gap-2.5 text-sm text-ink-muted">
        {{ notif_form.notify_on_cancellation(class_="mt-0.5 rounded border-border bg-surface-raised text-accent focus:ring-accent focus:ring-offset-base") }}
        {{ notif_form.notify_on_cancellation.label.text }}
      </label>

      <button type="submit" class="btn-primary">Save preferences</button>
    </form>
  </div>
  <div class="card p-6 sm:p-7">
    <h2 class="font-display text-base font-semibold text-ink mb-1">Booking out-of-hours</h2>
    <p class="mb-4 text-sm text-ink-muted">
      By default your <a href="{{ url_for('public.booking_types') }}" class="text-accent hover:underline">booking page</a>
      only ever offers times inside your working hours. Turn this on to also offer times
      outside them (evenings, days off) for a fee you set — the customer sees the fee and
      must accept it before confirming.
    </p>
    <form method="POST" action="{{ url_for('admin.update_booking_out_of_hours') }}" novalidate>
      {{ booking_ooh_form.hidden_tag() }}
      <label class="mb-4 flex items-start gap-2.5 text-sm text-ink-muted">
        {{ booking_ooh_form.allow_out_of_hours_bookings(class_="mt-0.5 rounded border-border bg-surface-raised text-accent focus:ring-accent focus:ring-offset-base") }}
        {{ booking_ooh_form.allow_out_of_hours_bookings.label.text }}
      </label>
      <div class="mb-4">
        <label class="field-label" for="{{ booking_ooh_form.out_of_hours_booking_fee.id }}">{{ booking_ooh_form.out_of_hours_booking_fee.label.text }}</label>
        {{ booking_ooh_form.out_of_hours_booking_fee(class_="field-input", placeholder="e.g. \u00a325") }}
        {% for error in booking_ooh_form.out_of_hours_booking_fee.errors %}<p class="field-error">{{ error }}</p>{% endfor %}
      </div>
      <button type="submit" class="btn-primary">Save</button>
    </form>
  </div>

  <div class="card p-6 sm:p-7">
    <h2 class="font-display text-base font-semibold text-ink mb-1">ISP Support out-of-hours fee</h2>
    <p class="mb-4 text-sm text-ink-muted">
      This only applies to the <a href="{{ url_for('isp_support.request_form') }}" class="text-accent hover:underline">ISP support request form</a>
      — it has no effect on ordinary bookings from your
      <a href="{{ url_for('public.booking_types') }}" class="text-accent hover:underline">booking page</a>,
      since those are never offered outside your working hours in the first place. When someone
      submits an ISP support request outside your working hours, this fee is shown to them and
      they must accept it before submitting. Leave blank for no fee.
    </p>
    <form method="POST" action="{{ url_for('admin.update_isp_fee') }}" novalidate>
      {{ isp_fee_form.hidden_tag() }}
      <div class="mb-4">
        <label class="field-label" for="{{ isp_fee_form.isp_out_of_hours_fee.id }}">{{ isp_fee_form.isp_out_of_hours_fee.label.text }}</label>
        {{ isp_fee_form.isp_out_of_hours_fee(class_="field-input", placeholder="e.g. \u00a345") }}
        {% for error in isp_fee_form.isp_out_of_hours_fee.errors %}<p class="field-error">{{ error }}</p>{% endfor %}
      </div>
      <button type="submit" class="btn-primary">Save fee</button>
    </form>
  </div>

  <div class="card p-6 sm:p-7">
    <h2 class="font-display text-base font-semibold text-ink mb-1">Share your status</h2>
    <p class="mb-4 text-sm text-ink-muted">Give this link to people, or embed it on another site.</p>

    <div class="mb-4">
      <label class="field-label">Public status page</label>
      <div class="flex gap-2">
        <input type="text" readonly value="{{ status_url }}" class="field-input font-mono text-xs" onclick="this.select()">
        <a href="{{ status_url }}" target="_blank" class="btn-secondary shrink-0">Open</a>
      </div>
    </div>

    <div class="mb-4">
      <label class="field-label">Embed as an iframe</label>
      <textarea readonly rows="3" class="field-input font-mono text-xs" onclick="this.select()">&lt;iframe
  src="{{ status_url }}"
  width="100%"
  height="250"
  style="border:0;"&gt;&lt;/iframe&gt;</textarea>
    </div>

    <div>
      <label class="field-label">Embed as a JS widget</label>
      <textarea readonly rows="2" class="field-input font-mono text-xs" onclick="this.select()">&lt;script src="{{ widget_url }}" data-scheduler="{{ current_user.id }}"&gt;&lt;/script&gt;</textarea>
    </div>
  </div>

</div>

{% endblock %}
CLAUDE_PATCH_EOF

mkdir -p "$APP_DIR/app/templates/admin"
cat > "$APP_DIR/app/templates/admin/bookings.html" << 'CLAUDE_PATCH_EOF'
{% extends "layouts/admin.html" %}
{% block title %}Bookings · {{ app_name }}{% endblock %}
{% block page_content %}

<div class="mb-6 flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
  <div>
    <h1 class="font-display text-2xl font-semibold text-ink">Bookings</h1>
    <p class="mt-1 text-sm text-ink-muted">Everything people have booked with you.</p>
  </div>
  <div class="flex gap-1 rounded-lg border border-border bg-surface p-1 self-start">
    {% for key, label in [('upcoming','Upcoming'), ('past','Past'), ('cancelled','Cancelled')] %}
      <a href="{{ url_for('admin.bookings', filter=key) }}"
         class="rounded-md px-3 py-1.5 text-sm font-medium {{ 'bg-surface-raised text-ink' if filter == key else 'text-ink-muted hover:text-ink' }}">
        {{ label }}
      </a>
    {% endfor %}
  </div>
</div>

<div class="card divide-y divide-border">
  {% if bookings %}
    {% for b in bookings %}
    <div class="flex flex-col gap-3 p-5 sm:flex-row sm:items-center sm:justify-between">
      <div class="min-w-0">
        <div class="flex flex-wrap items-center gap-2">
          <p class="font-medium text-ink">{{ b.name }}</p>
          <span class="text-[10px] font-medium uppercase tracking-wide rounded px-1.5 py-0.5 border
            {{ 'border-status-available/30 text-status-available' if b.status == 'confirmed'
               else 'border-status-busy/30 text-status-busy' if b.status == 'cancelled'
               else 'border-border text-ink-faint' }}">
            {{ b.status }}
          </span>
          {% if b.is_out_of_hours %}
          <span class="text-[10px] font-medium uppercase tracking-wide rounded px-1.5 py-0.5 border border-status-away/30 text-status-away">
            Out of hours{% if b.out_of_hours_fee_shown %} · {{ b.out_of_hours_fee_shown }}{% endif %}
          </span>
          {% endif %}
        </div>
        <p class="mt-0.5 text-sm text-ink-muted">
          {{ b.start_datetime.strftime('%a %d %b %Y, %H:%M') }} – {{ b.end_datetime.strftime('%H:%M') }}
          {% if b.booking_type %} · {{ b.booking_type.name }}{% endif %}
        </p>
        <p class="mt-0.5 text-sm text-ink-faint">{{ b.email }}{% if b.phone %} · {{ b.phone }}{% endif %}</p>
        {% if b.notes %}<p class="mt-1.5 text-sm text-ink-muted italic">"{{ b.notes }}"</p>{% endif %}
      </div>
      {% if b.status != 'cancelled' %}
      <form method="POST" action="{{ url_for('admin.cancel_booking', booking_id=b.id) }}" class="shrink-0"
            onsubmit="return confirm('Cancel this booking with {{ b.name }}?');">
        <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
        <button type="submit" class="btn-danger">Cancel</button>
      </form>
      {% endif %}
    </div>
    {% endfor %}
  {% else %}
    <div class="p-8 text-center">
      <p class="text-sm text-ink-muted">No {{ filter }} bookings.</p>
    </div>
  {% endif %}
</div>

{% endblock %}
CLAUDE_PATCH_EOF

mkdir -p "$APP_DIR/app/templates/public"
cat > "$APP_DIR/app/templates/public/pick_slot.html" << 'CLAUDE_PATCH_EOF'
{% extends "base.html" %}
{% block title %}{{ booking_type.name }} · {{ app_name }}{% endblock %}
{% block body %}
<div class="mx-auto max-w-2xl px-4 py-12 sm:py-16">
  <a href="{{ url_for('public.booking_types') }}" class="text-sm text-ink-muted hover:text-ink">&larr; All meeting types</a>

  <div class="mt-4 mb-8">
    <h1 class="font-display text-2xl font-semibold text-ink">{{ booking_type.name }}</h1>
    <p class="mt-1 text-sm text-ink-muted">{{ booking_type.duration }} minutes with {{ owner.name }}{% if booking_type.description %} · {{ booking_type.description }}{% endif %}</p>
  </div>

  {% include "partials/flash.html" %}

  <div class="card p-5 sm:p-6">
    <div class="mb-5 flex items-center justify-between">
      <a href="{{ url_for('public.pick_slot', type_id=booking_type.id, date=prev_date.isoformat()) }}"
         class="btn-ghost !px-2 {{ 'pointer-events-none opacity-30' if target_date <= today }}" aria-label="Previous day">
        <svg xmlns="http://www.w3.org/2000/svg" class="h-5 w-5" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="15 18 9 12 15 6"/></svg>
      </a>
      <div class="text-center">
        <p class="font-display text-base font-semibold text-ink">{{ target_date.strftime('%A') }}</p>
        <p class="text-sm text-ink-muted">{{ target_date.strftime('%d %B %Y') }}</p>
      </div>
      <a href="{{ url_for('public.pick_slot', type_id=booking_type.id, date=next_date.isoformat()) }}"
         class="btn-ghost !px-2 {{ 'pointer-events-none opacity-30' if target_date >= max_date }}" aria-label="Next day">
        <svg xmlns="http://www.w3.org/2000/svg" class="h-5 w-5" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="9 18 15 12 9 6"/></svg>
      </a>
    </div>

    <form method="GET" action="{{ url_for('public.pick_slot', type_id=booking_type.id) }}" class="mb-6">
      <input type="date" name="date" value="{{ target_date.isoformat() }}" min="{{ today.isoformat() }}" max="{{ max_date.isoformat() }}"
             class="field-input" onchange="this.form.submit()">
    </form>

    {% if slots %}
      <div class="grid grid-cols-3 gap-2 sm:grid-cols-4">
        {% for slot in slots %}
        <a href="{{ url_for('public.booking_details', type_id=booking_type.id, dt=slot.isoformat()) }}"
           class="rounded-lg border border-border bg-surface-raised px-3 py-2.5 text-center text-sm font-medium text-ink hover:border-accent hover:text-accent transition-colors">
          {{ slot.strftime('%H:%M') }}
        </a>
        {% endfor %}
      </div>
    {% else %}
      <p class="py-8 text-center text-sm text-ink-muted">
        {% if ooh_slots %}No regular-hours times available on this day — see out-of-hours options below.
        {% else %}No times available on this day — try another date.{% endif %}
      </p>
    {% endif %}

    {% if ooh_slots %}
      <div class="mt-6 border-t border-border pt-5">
        <div class="mb-3 flex items-start gap-2.5">
          <span class="status-dot bg-status-away mt-1 shrink-0"></span>
          <p class="text-sm text-ink-muted">
            Outside normal hours{% if ooh_fee %} — a <span class="font-medium text-ink">{{ ooh_fee }}</span> fee applies{% endif %}.
          </p>
        </div>
        <div class="grid grid-cols-3 gap-2 sm:grid-cols-4">
          {% for slot in ooh_slots %}
          <a href="{{ url_for('public.booking_details', type_id=booking_type.id, dt=slot.isoformat()) }}"
             class="rounded-lg border border-status-away/30 bg-status-away/10 px-3 py-2.5 text-center text-sm font-medium text-ink hover:border-status-away/50 transition-colors">
            {{ slot.strftime('%H:%M') }}
          </a>
          {% endfor %}
        </div>
      </div>
    {% endif %}
  </div>
</div>
{% endblock %}
CLAUDE_PATCH_EOF

mkdir -p "$APP_DIR/app/templates/public"
cat > "$APP_DIR/app/templates/public/booking_details.html" << 'CLAUDE_PATCH_EOF'
{% extends "base.html" %}
{% block title %}Confirm booking · {{ app_name }}{% endblock %}
{% block body %}
<div class="mx-auto max-w-lg px-4 py-12 sm:py-16">
  <a href="{{ url_for('public.pick_slot', type_id=booking_type.id, date=start_dt.date().isoformat()) }}" class="text-sm text-ink-muted hover:text-ink">&larr; Choose a different time</a>

  <div class="mt-4 mb-8">
    <h1 class="font-display text-2xl font-semibold text-ink">Confirm your details</h1>
    <p class="mt-2 text-sm text-ink-muted">
      {{ booking_type.name }} · {{ start_dt.strftime('%A %d %B, %H:%M') }}
      ({{ booking_type.duration }} min) with {{ owner.name }}
    </p>
  </div>

  {% include "partials/flash.html" %}

  {% if is_out_of_hours and ooh_fee %}
  <div class="card p-4 sm:p-5 mb-6 border-status-away/30 bg-status-away/10 flex items-start gap-3">
    <span class="status-dot bg-status-away mt-1.5 shrink-0"></span>
    <p class="text-sm text-ink">
      This time is outside normal working hours, so a <span class="font-medium">{{ ooh_fee }}</span>
      out-of-hours fee applies. You'll be asked to confirm you accept this below.
    </p>
  </div>
  {% endif %}

  <div class="card p-6 sm:p-7">
    <form method="POST" action="{{ url_for('public.booking_details', type_id=booking_type.id, dt=dt_raw) }}" novalidate>
      {{ form.hidden_tag() }}
      <input type="hidden" name="dt" value="{{ dt_raw }}">

      <div class="mb-4">
        <label class="field-label" for="{{ form.name.id }}">Name</label>
        {{ form.name(class_="field-input", autofocus=true) }}
        {% for error in form.name.errors %}<p class="field-error">{{ error }}</p>{% endfor %}
      </div>

      <div class="mb-4">
        <label class="field-label" for="{{ form.email.id }}">Email</label>
        {{ form.email(class_="field-input") }}
        {% for error in form.email.errors %}<p class="field-error">{{ error }}</p>{% endfor %}
      </div>

      <div class="mb-4">
        <label class="field-label" for="{{ form.phone.id }}">Phone (optional)</label>
        {{ form.phone(class_="field-input") }}
      </div>

      <div class="mb-6">
        <label class="field-label" for="{{ form.notes.id }}">Anything you'd like to share? (optional)</label>
        {{ form.notes(class_="field-input", rows=3) }}
      </div>

      {% if is_out_of_hours and ooh_fee %}
      <label class="mb-6 flex items-start gap-3 text-sm text-ink-muted">
        {{ form.consent_out_of_hours_fee(class_="mt-0.5 h-4 w-4 rounded border-border bg-surface-raised text-accent focus:ring-accent focus:ring-offset-base shrink-0") }}
        <span>I understand a <strong class="text-ink">{{ ooh_fee }}</strong> out-of-hours fee applies to this booking and I agree to it.</span>
      </label>
      {% endif %}

      <button type="submit" class="btn-primary w-full">Confirm booking</button>
    </form>
  </div>
</div>
{% endblock %}
CLAUDE_PATCH_EOF

mkdir -p "$APP_DIR/app/templates/public"
cat > "$APP_DIR/app/templates/public/confirmation.html" << 'CLAUDE_PATCH_EOF'
{% extends "base.html" %}
{% block title %}Booking confirmed · {{ app_name }}{% endblock %}
{% block body %}
<div class="mx-auto max-w-lg px-4 py-16 text-center">
  <div class="mx-auto mb-5 flex h-12 w-12 items-center justify-center rounded-full bg-status-available/10 text-status-available">
    <svg xmlns="http://www.w3.org/2000/svg" class="h-6 w-6" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="20 6 9 17 4 12"/></svg>
  </div>

  <h1 class="font-display text-2xl font-semibold text-ink">You're booked in</h1>
  <p class="mt-2 text-sm text-ink-muted">A confirmation has been sent to {{ booking.email }}.</p>

  <div class="card mt-8 p-6 text-left">
    <p class="font-medium text-ink">{{ booking.booking_type.name if booking.booking_type else "Meeting" }}</p>
    <p class="mt-1 text-sm text-ink-muted">
      {{ booking.start_datetime.strftime('%A %d %B %Y') }}<br>
      {{ booking.start_datetime.strftime('%H:%M') }} – {{ booking.end_datetime.strftime('%H:%M') }}
    </p>
    {% if booking.notes %}
      <p class="mt-3 text-sm text-ink-muted italic">"{{ booking.notes }}"</p>
    {% endif %}
    {% if booking.is_out_of_hours and booking.out_of_hours_fee_shown %}
      <p class="mt-3 text-sm text-status-away">Out-of-hours booking — {{ booking.out_of_hours_fee_shown }} fee applies.</p>
    {% endif %}
  </div>

  <a href="{{ url_for('public.manage_booking', token=booking.manage_token) }}" class="mt-6 inline-block text-sm text-accent hover:underline">
    Need to cancel? Manage this booking
  </a>
</div>
{% endblock %}
CLAUDE_PATCH_EOF

mkdir -p "$APP_DIR/app/static/css"
cat > "$APP_DIR/app/static/css/main.css" << 'CLAUDE_PATCH_EOF'
*,:after,:before{--tw-border-spacing-x:0;--tw-border-spacing-y:0;--tw-translate-x:0;--tw-translate-y:0;--tw-rotate:0;--tw-skew-x:0;--tw-skew-y:0;--tw-scale-x:1;--tw-scale-y:1;--tw-pan-x: ;--tw-pan-y: ;--tw-pinch-zoom: ;--tw-scroll-snap-strictness:proximity;--tw-gradient-from-position: ;--tw-gradient-via-position: ;--tw-gradient-to-position: ;--tw-ordinal: ;--tw-slashed-zero: ;--tw-numeric-figure: ;--tw-numeric-spacing: ;--tw-numeric-fraction: ;--tw-ring-inset: ;--tw-ring-offset-width:0px;--tw-ring-offset-color:#fff;--tw-ring-color:rgba(59,130,246,.5);--tw-ring-offset-shadow:0 0 #0000;--tw-ring-shadow:0 0 #0000;--tw-shadow:0 0 #0000;--tw-shadow-colored:0 0 #0000;--tw-blur: ;--tw-brightness: ;--tw-contrast: ;--tw-grayscale: ;--tw-hue-rotate: ;--tw-invert: ;--tw-saturate: ;--tw-sepia: ;--tw-drop-shadow: ;--tw-backdrop-blur: ;--tw-backdrop-brightness: ;--tw-backdrop-contrast: ;--tw-backdrop-grayscale: ;--tw-backdrop-hue-rotate: ;--tw-backdrop-invert: ;--tw-backdrop-opacity: ;--tw-backdrop-saturate: ;--tw-backdrop-sepia: ;--tw-contain-size: ;--tw-contain-layout: ;--tw-contain-paint: ;--tw-contain-style: }::backdrop{--tw-border-spacing-x:0;--tw-border-spacing-y:0;--tw-translate-x:0;--tw-translate-y:0;--tw-rotate:0;--tw-skew-x:0;--tw-skew-y:0;--tw-scale-x:1;--tw-scale-y:1;--tw-pan-x: ;--tw-pan-y: ;--tw-pinch-zoom: ;--tw-scroll-snap-strictness:proximity;--tw-gradient-from-position: ;--tw-gradient-via-position: ;--tw-gradient-to-position: ;--tw-ordinal: ;--tw-slashed-zero: ;--tw-numeric-figure: ;--tw-numeric-spacing: ;--tw-numeric-fraction: ;--tw-ring-inset: ;--tw-ring-offset-width:0px;--tw-ring-offset-color:#fff;--tw-ring-color:rgba(59,130,246,.5);--tw-ring-offset-shadow:0 0 #0000;--tw-ring-shadow:0 0 #0000;--tw-shadow:0 0 #0000;--tw-shadow-colored:0 0 #0000;--tw-blur: ;--tw-brightness: ;--tw-contrast: ;--tw-grayscale: ;--tw-hue-rotate: ;--tw-invert: ;--tw-saturate: ;--tw-sepia: ;--tw-drop-shadow: ;--tw-backdrop-blur: ;--tw-backdrop-brightness: ;--tw-backdrop-contrast: ;--tw-backdrop-grayscale: ;--tw-backdrop-hue-rotate: ;--tw-backdrop-invert: ;--tw-backdrop-opacity: ;--tw-backdrop-saturate: ;--tw-backdrop-sepia: ;--tw-contain-size: ;--tw-contain-layout: ;--tw-contain-paint: ;--tw-contain-style: }/*! tailwindcss v3.4.19 | MIT License | https://tailwindcss.com*/*,:after,:before{box-sizing:border-box;border:0 solid #e5e7eb}:after,:before{--tw-content:""}:host,html{line-height:1.5;-webkit-text-size-adjust:100%;-moz-tab-size:4;-o-tab-size:4;tab-size:4;font-family:Inter,ui-sans-serif,system-ui,sans-serif;font-feature-settings:normal;font-variation-settings:normal;-webkit-tap-highlight-color:transparent}body{margin:0;line-height:inherit}hr{height:0;color:inherit;border-top-width:1px}abbr:where([title]){-webkit-text-decoration:underline dotted;text-decoration:underline dotted}h1,h2,h3,h4,h5,h6{font-size:inherit;font-weight:inherit}a{color:inherit;text-decoration:inherit}b,strong{font-weight:bolder}code,kbd,pre,samp{font-family:ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,Liberation Mono,Courier New,monospace;font-feature-settings:normal;font-variation-settings:normal;font-size:1em}small{font-size:80%}sub,sup{font-size:75%;line-height:0;position:relative;vertical-align:baseline}sub{bottom:-.25em}sup{top:-.5em}table{text-indent:0;border-color:inherit;border-collapse:collapse}button,input,optgroup,select,textarea{font-family:inherit;font-feature-settings:inherit;font-variation-settings:inherit;font-size:100%;font-weight:inherit;line-height:inherit;letter-spacing:inherit;color:inherit;margin:0;padding:0}button,select{text-transform:none}button,input:where([type=button]),input:where([type=reset]),input:where([type=submit]){-webkit-appearance:button;background-color:transparent;background-image:none}:-moz-focusring{outline:auto}:-moz-ui-invalid{box-shadow:none}progress{vertical-align:baseline}::-webkit-inner-spin-button,::-webkit-outer-spin-button{height:auto}[type=search]{-webkit-appearance:textfield;outline-offset:-2px}::-webkit-search-decoration{-webkit-appearance:none}::-webkit-file-upload-button{-webkit-appearance:button;font:inherit}summary{display:list-item}blockquote,dd,dl,figure,h1,h2,h3,h4,h5,h6,hr,p,pre{margin:0}fieldset{margin:0}fieldset,legend{padding:0}menu,ol,ul{list-style:none;margin:0;padding:0}dialog{padding:0}textarea{resize:vertical}input::-moz-placeholder,textarea::-moz-placeholder{opacity:1;color:#9ca3af}input::placeholder,textarea::placeholder{opacity:1;color:#9ca3af}[role=button],button{cursor:pointer}:disabled{cursor:default}audio,canvas,embed,iframe,img,object,svg,video{display:block;vertical-align:middle}img,video{max-width:100%;height:auto}[hidden]:where(:not([hidden=until-found])){display:none}input:where(:not([type])),input:where([type=date]),input:where([type=datetime-local]),input:where([type=email]),input:where([type=month]),input:where([type=number]),input:where([type=password]),input:where([type=search]),input:where([type=tel]),input:where([type=text]),input:where([type=time]),input:where([type=url]),input:where([type=week]),select,select:where([multiple]),textarea{-webkit-appearance:none;-moz-appearance:none;appearance:none;background-color:#fff;border-color:#6b7280;border-width:1px;border-radius:0;padding:.5rem .75rem;font-size:1rem;line-height:1.5rem;--tw-shadow:0 0 #0000}input:where(:not([type])):focus,input:where([type=date]):focus,input:where([type=datetime-local]):focus,input:where([type=email]):focus,input:where([type=month]):focus,input:where([type=number]):focus,input:where([type=password]):focus,input:where([type=search]):focus,input:where([type=tel]):focus,input:where([type=text]):focus,input:where([type=time]):focus,input:where([type=url]):focus,input:where([type=week]):focus,select:focus,select:where([multiple]):focus,textarea:focus{outline:2px solid transparent;outline-offset:2px;--tw-ring-inset:var(--tw-empty,/*!*/ /*!*/);--tw-ring-offset-width:0px;--tw-ring-offset-color:#fff;--tw-ring-color:#2563eb;--tw-ring-offset-shadow:var(--tw-ring-inset) 0 0 0 var(--tw-ring-offset-width) var(--tw-ring-offset-color);--tw-ring-shadow:var(--tw-ring-inset) 0 0 0 calc(1px + var(--tw-ring-offset-width)) var(--tw-ring-color);box-shadow:var(--tw-ring-offset-shadow),var(--tw-ring-shadow),var(--tw-shadow);border-color:#2563eb}input::-moz-placeholder,textarea::-moz-placeholder{color:#6b7280;opacity:1}input::placeholder,textarea::placeholder{color:#6b7280;opacity:1}::-webkit-datetime-edit-fields-wrapper{padding:0}::-webkit-date-and-time-value{min-height:1.5em;text-align:inherit}::-webkit-datetime-edit{display:inline-flex}::-webkit-datetime-edit,::-webkit-datetime-edit-day-field,::-webkit-datetime-edit-hour-field,::-webkit-datetime-edit-meridiem-field,::-webkit-datetime-edit-millisecond-field,::-webkit-datetime-edit-minute-field,::-webkit-datetime-edit-month-field,::-webkit-datetime-edit-second-field,::-webkit-datetime-edit-year-field{padding-top:0;padding-bottom:0}select{background-image:url("data:image/svg+xml;charset=utf-8,%3Csvg xmlns='http://www.w3.org/2000/svg' fill='none' viewBox='0 0 20 20'%3E%3Cpath stroke='%236b7280' stroke-linecap='round' stroke-linejoin='round' stroke-width='1.5' d='m6 8 4 4 4-4'/%3E%3C/svg%3E");background-position:right .5rem center;background-repeat:no-repeat;background-size:1.5em 1.5em;padding-right:2.5rem;-webkit-print-color-adjust:exact;print-color-adjust:exact}select:where([multiple]),select:where([size]:not([size="1"])){background-image:none;background-position:0 0;background-repeat:unset;background-size:initial;padding-right:.75rem;-webkit-print-color-adjust:unset;print-color-adjust:unset}input:where([type=checkbox]),input:where([type=radio]){-webkit-appearance:none;-moz-appearance:none;appearance:none;padding:0;-webkit-print-color-adjust:exact;print-color-adjust:exact;display:inline-block;vertical-align:middle;background-origin:border-box;-webkit-user-select:none;-moz-user-select:none;user-select:none;flex-shrink:0;height:1rem;width:1rem;color:#2563eb;background-color:#fff;border-color:#6b7280;border-width:1px;--tw-shadow:0 0 #0000}input:where([type=checkbox]){border-radius:0}input:where([type=radio]){border-radius:100%}input:where([type=checkbox]):focus,input:where([type=radio]):focus{outline:2px solid transparent;outline-offset:2px;--tw-ring-inset:var(--tw-empty,/*!*/ /*!*/);--tw-ring-offset-width:2px;--tw-ring-offset-color:#fff;--tw-ring-color:#2563eb;--tw-ring-offset-shadow:var(--tw-ring-inset) 0 0 0 var(--tw-ring-offset-width) var(--tw-ring-offset-color);--tw-ring-shadow:var(--tw-ring-inset) 0 0 0 calc(2px + var(--tw-ring-offset-width)) var(--tw-ring-color);box-shadow:var(--tw-ring-offset-shadow),var(--tw-ring-shadow),var(--tw-shadow)}input:where([type=checkbox]):checked,input:where([type=radio]):checked{border-color:transparent;background-color:currentColor;background-size:100% 100%;background-position:50%;background-repeat:no-repeat}input:where([type=checkbox]):checked{background-image:url("data:image/svg+xml;charset=utf-8,%3Csvg xmlns='http://www.w3.org/2000/svg' fill='%23fff' viewBox='0 0 16 16'%3E%3Cpath d='M12.207 4.793a1 1 0 0 1 0 1.414l-5 5a1 1 0 0 1-1.414 0l-2-2a1 1 0 0 1 1.414-1.414L6.5 9.086l4.293-4.293a1 1 0 0 1 1.414 0'/%3E%3C/svg%3E")}@media (forced-colors:active) {input:where([type=checkbox]):checked{-webkit-appearance:auto;-moz-appearance:auto;appearance:auto}}input:where([type=radio]):checked{background-image:url("data:image/svg+xml;charset=utf-8,%3Csvg xmlns='http://www.w3.org/2000/svg' fill='%23fff' viewBox='0 0 16 16'%3E%3Ccircle cx='8' cy='8' r='3'/%3E%3C/svg%3E")}@media (forced-colors:active) {input:where([type=radio]):checked{-webkit-appearance:auto;-moz-appearance:auto;appearance:auto}}input:where([type=checkbox]):checked:focus,input:where([type=checkbox]):checked:hover,input:where([type=radio]):checked:focus,input:where([type=radio]):checked:hover{border-color:transparent;background-color:currentColor}input:where([type=checkbox]):indeterminate{background-image:url("data:image/svg+xml;charset=utf-8,%3Csvg xmlns='http://www.w3.org/2000/svg' fill='none' viewBox='0 0 16 16'%3E%3Cpath stroke='%23fff' stroke-linecap='round' stroke-linejoin='round' stroke-width='2' d='M4 8h8'/%3E%3C/svg%3E");border-color:transparent;background-color:currentColor;background-size:100% 100%;background-position:50%;background-repeat:no-repeat}@media (forced-colors:active) {input:where([type=checkbox]):indeterminate{-webkit-appearance:auto;-moz-appearance:auto;appearance:auto}}input:where([type=checkbox]):indeterminate:focus,input:where([type=checkbox]):indeterminate:hover{border-color:transparent;background-color:currentColor}input:where([type=file]){background:unset;border-color:inherit;border-width:0;border-radius:0;padding:0;font-size:unset;line-height:inherit}input:where([type=file]):focus{outline:1px solid ButtonText;outline:1px auto -webkit-focus-ring-color}html{scroll-behavior:smooth}body{--tw-bg-opacity:1;background-color:rgb(18 20 26/var(--tw-bg-opacity,1));font-family:Inter,ui-sans-serif,system-ui,sans-serif;--tw-text-opacity:1;color:rgb(237 238 242/var(--tw-text-opacity,1));-webkit-font-smoothing:antialiased;-moz-osx-font-smoothing:grayscale}::-moz-selection{background-color:rgba(232,163,61,.3);--tw-text-opacity:1;color:rgb(237 238 242/var(--tw-text-opacity,1))}::selection{background-color:rgba(232,163,61,.3);--tw-text-opacity:1;color:rgb(237 238 242/var(--tw-text-opacity,1))}:focus-visible{border-radius:.125rem;outline:2px solid transparent;outline-offset:2px;--tw-ring-offset-shadow:var(--tw-ring-inset) 0 0 0 var(--tw-ring-offset-width) var(--tw-ring-offset-color);--tw-ring-shadow:var(--tw-ring-inset) 0 0 0 calc(2px + var(--tw-ring-offset-width)) var(--tw-ring-color);box-shadow:var(--tw-ring-offset-shadow),var(--tw-ring-shadow),var(--tw-shadow,0 0 #0000);--tw-ring-opacity:1;--tw-ring-color:rgb(232 163 61/var(--tw-ring-opacity,1));--tw-ring-offset-width:2px;--tw-ring-offset-color:#12141a}h1,h2,h3,h4{font-family:Space Grotesk,ui-sans-serif,system-ui,sans-serif}.card{border-radius:.875rem;border-width:1px;--tw-border-opacity:1;border-color:rgb(44 49 64/var(--tw-border-opacity,1));--tw-bg-opacity:1;background-color:rgb(27 30 39/var(--tw-bg-opacity,1));--tw-shadow:0 1px 0 0 hsla(0,0%,100%,.02) inset,0 8px 24px -12px rgba(0,0,0,.5);--tw-shadow-colored:inset 0 1px 0 0 var(--tw-shadow-color),0 8px 24px -12px var(--tw-shadow-color);box-shadow:var(--tw-ring-offset-shadow,0 0 #0000),var(--tw-ring-shadow,0 0 #0000),var(--tw-shadow)}.btn{display:inline-flex;align-items:center;justify-content:center;gap:.5rem;border-radius:.5rem;padding:.625rem 1rem;font-size:.875rem;line-height:1.25rem;font-weight:500;transition-property:color,background-color,border-color,text-decoration-color,fill,stroke;transition-timing-function:cubic-bezier(.4,0,.2,1);transition-duration:.15s}.btn:disabled{cursor:not-allowed;opacity:.5}.btn-primary{display:inline-flex;align-items:center;justify-content:center;gap:.5rem;border-radius:.5rem;padding:.625rem 1rem;font-size:.875rem;line-height:1.25rem;font-weight:500;transition-property:color,background-color,border-color,text-decoration-color,fill,stroke;transition-timing-function:cubic-bezier(.4,0,.2,1);transition-duration:.15s}.btn-primary:disabled{cursor:not-allowed;opacity:.5}.btn-primary{--tw-bg-opacity:1;background-color:rgb(232 163 61/var(--tw-bg-opacity,1));font-size:1rem;line-height:1.5rem;--tw-text-opacity:1;color:rgb(18 20 26/var(--tw-text-opacity,1))}.btn-primary:hover{--tw-bg-opacity:1;background-color:rgb(242 182 92/var(--tw-bg-opacity,1))}.btn-secondary{display:inline-flex;align-items:center;justify-content:center;gap:.5rem;border-radius:.5rem;padding:.625rem 1rem;font-size:.875rem;line-height:1.25rem;font-weight:500;transition-property:color,background-color,border-color,text-decoration-color,fill,stroke;transition-timing-function:cubic-bezier(.4,0,.2,1);transition-duration:.15s}.btn-secondary:disabled{cursor:not-allowed;opacity:.5}.btn-secondary{border-width:1px;--tw-border-opacity:1;border-color:rgb(44 49 64/var(--tw-border-opacity,1));--tw-bg-opacity:1;background-color:rgb(35 39 51/var(--tw-bg-opacity,1));--tw-text-opacity:1;color:rgb(237 238 242/var(--tw-text-opacity,1))}.btn-secondary:hover{--tw-border-opacity:1;border-color:rgb(84 91 110/var(--tw-border-opacity,1))}.btn-ghost{display:inline-flex;align-items:center;justify-content:center;gap:.5rem;border-radius:.5rem;padding:.625rem 1rem;font-size:.875rem;line-height:1.25rem;font-weight:500;transition-property:color,background-color,border-color,text-decoration-color,fill,stroke;transition-timing-function:cubic-bezier(.4,0,.2,1);transition-duration:.15s}.btn-ghost:disabled{cursor:not-allowed;opacity:.5}.btn-ghost{--tw-text-opacity:1;color:rgb(139 147 167/var(--tw-text-opacity,1))}.btn-ghost:hover{--tw-bg-opacity:1;background-color:rgb(35 39 51/var(--tw-bg-opacity,1));--tw-text-opacity:1;color:rgb(237 238 242/var(--tw-text-opacity,1))}.btn-danger{display:inline-flex;align-items:center;justify-content:center;gap:.5rem;border-radius:.5rem;padding:.625rem 1rem;font-size:.875rem;line-height:1.25rem;font-weight:500;transition-property:color,background-color,border-color,text-decoration-color,fill,stroke;transition-timing-function:cubic-bezier(.4,0,.2,1);transition-duration:.15s}.btn-danger:disabled{cursor:not-allowed;opacity:.5}.btn-danger{border-width:1px;border-color:rgba(242,99,123,.3);background-color:rgba(242,99,123,.1);--tw-text-opacity:1;color:rgb(242 99 123/var(--tw-text-opacity,1))}.btn-danger:hover{background-color:rgba(242,99,123,.2)}.field-label{margin-bottom:.375rem;display:block;font-size:.75rem;line-height:1rem;font-weight:500;text-transform:uppercase;letter-spacing:.025em;--tw-text-opacity:1;color:rgb(139 147 167/var(--tw-text-opacity,1))}.field-input{width:100%;border-radius:.5rem;border-width:1px;--tw-border-opacity:1;border-color:rgb(44 49 64/var(--tw-border-opacity,1));--tw-bg-opacity:1;background-color:rgb(35 39 51/var(--tw-bg-opacity,1));padding:.625rem .875rem;font-size:.875rem;line-height:1.25rem;--tw-text-opacity:1;color:rgb(237 238 242/var(--tw-text-opacity,1))}.field-input::-moz-placeholder{--tw-placeholder-opacity:1;color:rgb(84 91 110/var(--tw-placeholder-opacity,1))}.field-input::placeholder{--tw-placeholder-opacity:1;color:rgb(84 91 110/var(--tw-placeholder-opacity,1))}.field-input{transition-property:color,background-color,border-color,text-decoration-color,fill,stroke;transition-timing-function:cubic-bezier(.4,0,.2,1);transition-duration:.15s}.field-input:focus{--tw-border-opacity:1;border-color:rgb(232 163 61/var(--tw-border-opacity,1))}.field-error{margin-top:.375rem;font-size:.75rem;line-height:1rem;--tw-text-opacity:1;color:rgb(242 99 123/var(--tw-text-opacity,1))}.nav-link{display:flex;align-items:center;gap:.75rem;border-radius:.5rem;padding:.625rem .75rem;font-size:.875rem;line-height:1.25rem;font-weight:500;--tw-text-opacity:1;color:rgb(139 147 167/var(--tw-text-opacity,1));transition-property:color,background-color,border-color,text-decoration-color,fill,stroke;transition-timing-function:cubic-bezier(.4,0,.2,1);transition-duration:.15s}.nav-link:hover{--tw-bg-opacity:1;background-color:rgb(35 39 51/var(--tw-bg-opacity,1));--tw-text-opacity:1;color:rgb(237 238 242/var(--tw-text-opacity,1))}.nav-link-active{display:flex;align-items:center;gap:.75rem;border-radius:.5rem;padding:.625rem .75rem;font-size:.875rem;line-height:1.25rem;font-weight:500;color:rgb(139 147 167/var(--tw-text-opacity,1));transition-property:color,background-color,border-color,text-decoration-color,fill,stroke;transition-timing-function:cubic-bezier(.4,0,.2,1);transition-duration:.15s}.nav-link-active,.nav-link-active:hover{--tw-bg-opacity:1;background-color:rgb(35 39 51/var(--tw-bg-opacity,1));--tw-text-opacity:1;color:rgb(237 238 242/var(--tw-text-opacity,1))}.status-dot{display:inline-block;height:.625rem;width:.625rem;border-radius:9999px}.status-pill{display:inline-flex;align-items:center;gap:.5rem;border-radius:9999px;border-width:1px;padding:.375rem .75rem;font-size:.875rem;line-height:1.25rem;font-weight:500}.day-badge,.day-badge-on{display:flex;height:2.25rem;width:2.25rem;flex-shrink:0;align-items:center;justify-content:center;border-radius:.5rem;border-width:1px;--tw-border-opacity:1;border-color:rgb(44 49 64/var(--tw-border-opacity,1));--tw-bg-opacity:1;background-color:rgb(35 39 51/var(--tw-bg-opacity,1));font-size:.75rem;line-height:1rem;font-weight:600;text-transform:uppercase;letter-spacing:.025em;--tw-text-opacity:1;color:rgb(139 147 167/var(--tw-text-opacity,1))}.day-badge-on{border-color:rgba(232,163,61,.3);background-color:rgba(232,163,61,.1);color:rgb(232 163 61/var(--tw-text-opacity,1))}.pointer-events-none{pointer-events:none}.visible{visibility:visible}.static{position:static}.fixed{position:fixed}.absolute{position:absolute}.relative{position:relative}.sticky{position:sticky}.inset-0{inset:0}.inset-x-0{left:0;right:0}.inset-y-0{top:0;bottom:0}.bottom-12{bottom:3rem}.left-0{left:0}.top-0{top:0}.top-12{top:3rem}.z-30{z-index:30}.z-40{z-index:40}.z-50{z-index:50}.mx-auto{margin-left:auto;margin-right:auto}.-mt-2{margin-top:-.5rem}.mb-1{margin-bottom:.25rem}.mb-1\.5{margin-bottom:.375rem}.mb-10{margin-bottom:2.5rem}.mb-2{margin-bottom:.5rem}.mb-3{margin-bottom:.75rem}.mb-4{margin-bottom:1rem}.mb-5{margin-bottom:1.25rem}.mb-6{margin-bottom:1.5rem}.mb-8{margin-bottom:2rem}.ml-0{margin-left:0}.ml-2{margin-left:.5rem}.ml-5{margin-left:1.25rem}.ml-7{margin-left:1.75rem}.ml-auto{margin-left:auto}.mt-0\.5{margin-top:.125rem}.mt-1{margin-top:.25rem}.mt-1\.5{margin-top:.375rem}.mt-10{margin-top:2.5rem}.mt-2{margin-top:.5rem}.mt-3{margin-top:.75rem}.mt-4{margin-top:1rem}.mt-5{margin-top:1.25rem}.mt-6{margin-top:1.5rem}.mt-8{margin-top:2rem}.block{display:block}.inline-block{display:inline-block}.inline{display:inline}.flex{display:flex}.inline-flex{display:inline-flex}.table{display:table}.grid{display:grid}.hidden{display:none}.h-1\.5{height:.375rem}.h-10{height:2.5rem}.h-12{height:3rem}.h-16{height:4rem}.h-2{height:.5rem}.h-2\.5{height:.625rem}.h-3{height:.75rem}.h-3\.5{height:.875rem}.h-4{height:1rem}.h-5{height:1.25rem}.h-6{height:1.5rem}.h-72{height:18rem}.h-9{height:2.25rem}.h-\[18px\]{height:18px}.h-full{height:100%}.h-px{height:1px}.min-h-\[120px\]{min-height:120px}.min-h-full{min-height:100%}.min-h-screen{min-height:100vh}.w-1\.5{width:.375rem}.w-10{width:2.5rem}.w-12{width:3rem}.w-16{width:4rem}.w-2{width:.5rem}.w-2\.5{width:.625rem}.w-28{width:7rem}.w-3{width:.75rem}.w-3\.5{width:.875rem}.w-32{width:8rem}.w-4{width:1rem}.w-40{width:10rem}.w-5{width:1.25rem}.w-6{width:1.5rem}.w-72{width:18rem}.w-9{width:2.25rem}.w-\[18px\]{width:18px}.w-fit{width:-moz-fit-content;width:fit-content}.w-full{width:100%}.min-w-0{min-width:0}.max-w-2xl{max-width:42rem}.max-w-6xl{max-width:72rem}.max-w-lg{max-width:32rem}.max-w-md{max-width:28rem}.max-w-sm{max-width:24rem}.max-w-xs{max-width:20rem}.flex-1{flex:1 1 0%}.shrink-0{flex-shrink:0}.-translate-x-full{--tw-translate-x:-100%;transform:translate(var(--tw-translate-x),var(--tw-translate-y)) rotate(var(--tw-rotate)) skewX(var(--tw-skew-x)) skewY(var(--tw-skew-y)) scaleX(var(--tw-scale-x)) scaleY(var(--tw-scale-y))}@keyframes pulseSoft{0%,to{opacity:1}50%{opacity:.45}}.animate-pulse-soft{animation:pulseSoft 2.2s ease-in-out infinite}.cursor-not-allowed{cursor:not-allowed}.cursor-pointer{cursor:pointer}.list-disc{list-style-type:disc}.grid-cols-1{grid-template-columns:repeat(1,minmax(0,1fr))}.grid-cols-2{grid-template-columns:repeat(2,minmax(0,1fr))}.grid-cols-3{grid-template-columns:repeat(3,minmax(0,1fr))}.grid-cols-7{grid-template-columns:repeat(7,minmax(0,1fr))}.flex-col{flex-direction:column}.flex-wrap{flex-wrap:wrap}.items-start{align-items:flex-start}.items-end{align-items:flex-end}.items-center{align-items:center}.justify-center{justify-content:center}.justify-between{justify-content:space-between}.gap-1{gap:.25rem}.gap-1\.5{gap:.375rem}.gap-2{gap:.5rem}.gap-2\.5{gap:.625rem}.gap-3{gap:.75rem}.gap-3\.5{gap:.875rem}.gap-4{gap:1rem}.gap-6{gap:1.5rem}.gap-x-4{-moz-column-gap:1rem;column-gap:1rem}.gap-y-1\.5{row-gap:.375rem}.gap-y-3{row-gap:.75rem}.space-y-1>:not([hidden])~:not([hidden]){--tw-space-y-reverse:0;margin-top:calc(.25rem*(1 - var(--tw-space-y-reverse)));margin-bottom:calc(.25rem*var(--tw-space-y-reverse))}.space-y-1\.5>:not([hidden])~:not([hidden]){--tw-space-y-reverse:0;margin-top:calc(.375rem*(1 - var(--tw-space-y-reverse)));margin-bottom:calc(.375rem*var(--tw-space-y-reverse))}.space-y-2>:not([hidden])~:not([hidden]){--tw-space-y-reverse:0;margin-top:calc(.5rem*(1 - var(--tw-space-y-reverse)));margin-bottom:calc(.5rem*var(--tw-space-y-reverse))}.space-y-2\.5>:not([hidden])~:not([hidden]){--tw-space-y-reverse:0;margin-top:calc(.625rem*(1 - var(--tw-space-y-reverse)));margin-bottom:calc(.625rem*var(--tw-space-y-reverse))}.space-y-3>:not([hidden])~:not([hidden]){--tw-space-y-reverse:0;margin-top:calc(.75rem*(1 - var(--tw-space-y-reverse)));margin-bottom:calc(.75rem*var(--tw-space-y-reverse))}.space-y-4>:not([hidden])~:not([hidden]){--tw-space-y-reverse:0;margin-top:calc(1rem*(1 - var(--tw-space-y-reverse)));margin-bottom:calc(1rem*var(--tw-space-y-reverse))}.space-y-6>:not([hidden])~:not([hidden]){--tw-space-y-reverse:0;margin-top:calc(1.5rem*(1 - var(--tw-space-y-reverse)));margin-bottom:calc(1.5rem*var(--tw-space-y-reverse))}.space-y-8>:not([hidden])~:not([hidden]){--tw-space-y-reverse:0;margin-top:calc(2rem*(1 - var(--tw-space-y-reverse)));margin-bottom:calc(2rem*var(--tw-space-y-reverse))}.divide-y>:not([hidden])~:not([hidden]){--tw-divide-y-reverse:0;border-top-width:calc(1px*(1 - var(--tw-divide-y-reverse)));border-bottom-width:calc(1px*var(--tw-divide-y-reverse))}.divide-border>:not([hidden])~:not([hidden]){--tw-divide-opacity:1;border-color:rgb(44 49 64/var(--tw-divide-opacity,1))}.self-start{align-self:flex-start}.overflow-hidden,.truncate{overflow:hidden}.truncate{text-overflow:ellipsis;white-space:nowrap}.whitespace-pre-line{white-space:pre-line}.rounded{border-radius:.25rem}.rounded-full{border-radius:9999px}.rounded-lg{border-radius:.5rem}.rounded-md{border-radius:.375rem}.border{border-width:1px}.border-b{border-bottom-width:1px}.border-r{border-right-width:1px}.border-t{border-top-width:1px}.border-accent\/30{border-color:rgba(232,163,61,.3)}.border-accent\/40{border-color:rgba(232,163,61,.4)}.border-accent\/50{border-color:rgba(232,163,61,.5)}.border-border{--tw-border-opacity:1;border-color:rgb(44 49 64/var(--tw-border-opacity,1))}.border-status-available{--tw-border-opacity:1;border-color:rgb(61 220 151/var(--tw-border-opacity,1))}.border-status-available\/30{border-color:rgba(61,220,151,.3)}.border-status-away{--tw-border-opacity:1;border-color:rgb(91 141 239/var(--tw-border-opacity,1))}.border-status-away\/30{border-color:rgba(91,141,239,.3)}.border-status-busy{--tw-border-opacity:1;border-color:rgb(242 99 123/var(--tw-border-opacity,1))}.border-status-busy\/30{border-color:rgba(242,99,123,.3)}.border-status-busy\/40{border-color:rgba(242,99,123,.4)}.border-status-offline{--tw-border-opacity:1;border-color:rgb(91 100 120/var(--tw-border-opacity,1))}.border-status-unavailable{--tw-border-opacity:1;border-color:rgb(185 139 242/var(--tw-border-opacity,1))}.bg-accent{--tw-bg-opacity:1;background-color:rgb(232 163 61/var(--tw-bg-opacity,1))}.bg-accent-muted{--tw-bg-opacity:1;background-color:rgb(58 45 24/var(--tw-bg-opacity,1))}.bg-accent-muted\/40{background-color:rgba(58,45,24,.4)}.bg-base{--tw-bg-opacity:1;background-color:rgb(18 20 26/var(--tw-bg-opacity,1))}.bg-base\/95{background-color:rgba(18,20,26,.95)}.bg-black\/50{background-color:rgba(0,0,0,.5)}.bg-black\/60{background-color:rgba(0,0,0,.6)}.bg-border{--tw-bg-opacity:1;background-color:rgb(44 49 64/var(--tw-bg-opacity,1))}.bg-current{background-color:currentColor}.bg-ink-faint{--tw-bg-opacity:1;background-color:rgb(84 91 110/var(--tw-bg-opacity,1))}.bg-status-available{--tw-bg-opacity:1;background-color:rgb(61 220 151/var(--tw-bg-opacity,1))}.bg-status-available\/10{background-color:rgba(61,220,151,.1)}.bg-status-away{--tw-bg-opacity:1;background-color:rgb(91 141 239/var(--tw-bg-opacity,1))}.bg-status-away\/10{background-color:rgba(91,141,239,.1)}.bg-status-busy{--tw-bg-opacity:1;background-color:rgb(242 99 123/var(--tw-bg-opacity,1))}.bg-status-busy\/10{background-color:rgba(242,99,123,.1)}.bg-status-offline{--tw-bg-opacity:1;background-color:rgb(91 100 120/var(--tw-bg-opacity,1))}.bg-status-unavailable{--tw-bg-opacity:1;background-color:rgb(185 139 242/var(--tw-bg-opacity,1))}.bg-surface{--tw-bg-opacity:1;background-color:rgb(27 30 39/var(--tw-bg-opacity,1))}.bg-surface-raised{--tw-bg-opacity:1;background-color:rgb(35 39 51/var(--tw-bg-opacity,1))}.bg-gradient-to-b{background-image:linear-gradient(to bottom,var(--tw-gradient-stops))}.bg-gradient-to-br{background-image:linear-gradient(to bottom right,var(--tw-gradient-stops))}.from-accent-muted\/40{--tw-gradient-from:rgba(58,45,24,.4) var(--tw-gradient-from-position);--tw-gradient-to:rgba(58,45,24,0) var(--tw-gradient-to-position);--tw-gradient-stops:var(--tw-gradient-from),var(--tw-gradient-to)}.from-accent-muted\/50{--tw-gradient-from:rgba(58,45,24,.5) var(--tw-gradient-from-position);--tw-gradient-to:rgba(58,45,24,0) var(--tw-gradient-to-position);--tw-gradient-stops:var(--tw-gradient-from),var(--tw-gradient-to)}.via-transparent{--tw-gradient-to:transparent var(--tw-gradient-to-position);--tw-gradient-stops:var(--tw-gradient-from),transparent var(--tw-gradient-via-position),var(--tw-gradient-to)}.to-transparent{--tw-gradient-to:transparent var(--tw-gradient-to-position)}.p-1{padding:.25rem}.p-2{padding:.5rem}.p-4{padding:1rem}.p-5{padding:1.25rem}.p-6{padding:1.5rem}.p-8{padding:2rem}.\!px-2{padding-left:.5rem!important;padding-right:.5rem!important}.\!px-2\.5{padding-left:.625rem!important;padding-right:.625rem!important}.\!px-3{padding-left:.75rem!important;padding-right:.75rem!important}.\!py-1{padding-top:.25rem!important;padding-bottom:.25rem!important}.\!py-1\.5{padding-top:.375rem!important;padding-bottom:.375rem!important}.px-1{padding-left:.25rem;padding-right:.25rem}.px-1\.5{padding-left:.375rem;padding-right:.375rem}.px-3{padding-left:.75rem;padding-right:.75rem}.px-4{padding-left:1rem;padding-right:1rem}.px-5{padding-left:1.25rem;padding-right:1.25rem}.px-6{padding-left:1.5rem;padding-right:1.5rem}.py-0\.5{padding-top:.125rem;padding-bottom:.125rem}.py-1{padding-top:.25rem;padding-bottom:.25rem}.py-1\.5{padding-top:.375rem;padding-bottom:.375rem}.py-10{padding-top:2.5rem;padding-bottom:2.5rem}.py-12{padding-top:3rem;padding-bottom:3rem}.py-16{padding-top:4rem;padding-bottom:4rem}.py-2{padding-top:.5rem;padding-bottom:.5rem}.py-2\.5{padding-top:.625rem;padding-bottom:.625rem}.py-3{padding-top:.75rem;padding-bottom:.75rem}.py-3\.5{padding-top:.875rem;padding-bottom:.875rem}.py-6{padding-top:1.5rem;padding-bottom:1.5rem}.py-8{padding-top:2rem;padding-bottom:2rem}.pb-1\.5{padding-bottom:.375rem}.pl-3{padding-left:.75rem}.pr-1\.5{padding-right:.375rem}.pt-4{padding-top:1rem}.pt-5{padding-top:1.25rem}.text-left{text-align:left}.text-center{text-align:center}.font-display{font-family:Space Grotesk,ui-sans-serif,system-ui,sans-serif}.font-mono{font-family:ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,Liberation Mono,Courier New,monospace}.text-2xl{font-size:1.5rem;line-height:2rem}.text-3xl{font-size:1.875rem;line-height:2.25rem}.text-6xl{font-size:3.75rem;line-height:1}.text-\[10px\]{font-size:10px}.text-\[11px\]{font-size:11px}.text-base{font-size:1rem;line-height:1.5rem}.text-lg{font-size:1.125rem;line-height:1.75rem}.text-sm{font-size:.875rem;line-height:1.25rem}.text-xl{font-size:1.25rem;line-height:1.75rem}.text-xs{font-size:.75rem;line-height:1rem}.font-medium{font-weight:500}.font-normal{font-weight:400}.font-semibold{font-weight:600}.uppercase{text-transform:uppercase}.capitalize{text-transform:capitalize}.italic{font-style:italic}.leading-relaxed{line-height:1.625}.leading-tight{line-height:1.25}.tracking-\[0\.3em\]{letter-spacing:.3em}.tracking-wide{letter-spacing:.025em}.tracking-wider{letter-spacing:.05em}.text-accent{--tw-text-opacity:1;color:rgb(232 163 61/var(--tw-text-opacity,1))}.text-base{--tw-text-opacity:1;color:rgb(18 20 26/var(--tw-text-opacity,1))}.text-ink{--tw-text-opacity:1;color:rgb(237 238 242/var(--tw-text-opacity,1))}.text-ink-faint{--tw-text-opacity:1;color:rgb(84 91 110/var(--tw-text-opacity,1))}.text-ink-muted{--tw-text-opacity:1;color:rgb(139 147 167/var(--tw-text-opacity,1))}.text-status-available{--tw-text-opacity:1;color:rgb(61 220 151/var(--tw-text-opacity,1))}.text-status-away{--tw-text-opacity:1;color:rgb(91 141 239/var(--tw-text-opacity,1))}.text-status-busy{--tw-text-opacity:1;color:rgb(242 99 123/var(--tw-text-opacity,1))}.text-status-busy\/90{color:rgba(242,99,123,.9)}.text-status-offline{--tw-text-opacity:1;color:rgb(91 100 120/var(--tw-text-opacity,1))}.text-status-unavailable{--tw-text-opacity:1;color:rgb(185 139 242/var(--tw-text-opacity,1))}.underline{text-decoration-line:underline}.opacity-30{opacity:.3}.opacity-50{opacity:.5}.opacity-60{opacity:.6}.shadow-card{--tw-shadow:0 1px 0 0 hsla(0,0%,100%,.02) inset,0 8px 24px -12px rgba(0,0,0,.5);--tw-shadow-colored:inset 0 1px 0 0 var(--tw-shadow-color),0 8px 24px -12px var(--tw-shadow-color);box-shadow:var(--tw-ring-offset-shadow,0 0 #0000),var(--tw-ring-shadow,0 0 #0000),var(--tw-shadow)}.filter{filter:var(--tw-blur) var(--tw-brightness) var(--tw-contrast) var(--tw-grayscale) var(--tw-hue-rotate) var(--tw-invert) var(--tw-saturate) var(--tw-sepia) var(--tw-drop-shadow)}.backdrop-blur{--tw-backdrop-blur:blur(8px)}.backdrop-blur,.backdrop-blur-sm{-webkit-backdrop-filter:var(--tw-backdrop-blur) var(--tw-backdrop-brightness) var(--tw-backdrop-contrast) var(--tw-backdrop-grayscale) var(--tw-backdrop-hue-rotate) var(--tw-backdrop-invert) var(--tw-backdrop-opacity) var(--tw-backdrop-saturate) var(--tw-backdrop-sepia);backdrop-filter:var(--tw-backdrop-blur) var(--tw-backdrop-brightness) var(--tw-backdrop-contrast) var(--tw-backdrop-grayscale) var(--tw-backdrop-hue-rotate) var(--tw-backdrop-invert) var(--tw-backdrop-opacity) var(--tw-backdrop-saturate) var(--tw-backdrop-sepia)}.backdrop-blur-sm{--tw-backdrop-blur:blur(4px)}.transition-colors{transition-property:color,background-color,border-color,text-decoration-color,fill,stroke;transition-timing-function:cubic-bezier(.4,0,.2,1);transition-duration:.15s}.transition-transform{transition-property:transform;transition-timing-function:cubic-bezier(.4,0,.2,1);transition-duration:.15s}.duration-200{transition-duration:.2s}html[data-view=mobile] .vm-topbar,html[data-view=tablet] .vm-topbar{display:flex!important}html[data-view=mobile] .vm-sidebar,html[data-view=tablet] .vm-sidebar{position:fixed!important;display:flex!important;transform:translateX(-100%)!important}html[data-view=mobile] .vm-sidebar.vm-open,html[data-view=tablet] .vm-sidebar.vm-open{transform:translateX(0)!important}html[data-view=mobile] .vm-main{padding:1rem!important}html[data-view=tablet] .vm-main{max-width:42rem!important;margin-inline:auto!important;padding:1.75rem 1.5rem!important}html[data-view=tablet] .vm-main .max-w-6xl{max-width:none!important}html[data-view=desktop] .vm-topbar{display:none!important}html[data-view=desktop] .vm-sidebar{position:static!important;display:flex!important;transform:none!important}html[data-view=desktop] .vm-main{padding:2.5rem!important}.last\:border-r-0:last-child{border-right-width:0}.hover\:border-accent:hover{--tw-border-opacity:1;border-color:rgb(232 163 61/var(--tw-border-opacity,1))}.hover\:border-accent\/50:hover{border-color:rgba(232,163,61,.5)}.hover\:border-ink-faint:hover{--tw-border-opacity:1;border-color:rgb(84 91 110/var(--tw-border-opacity,1))}.hover\:border-status-away\/50:hover{border-color:rgba(91,141,239,.5)}.hover\:bg-status-busy\/10:hover{background-color:rgba(242,99,123,.1)}.hover\:bg-surface-raised:hover{--tw-bg-opacity:1;background-color:rgb(35 39 51/var(--tw-bg-opacity,1))}.hover\:text-accent:hover{--tw-text-opacity:1;color:rgb(232 163 61/var(--tw-text-opacity,1))}.hover\:text-ink:hover{--tw-text-opacity:1;color:rgb(237 238 242/var(--tw-text-opacity,1))}.hover\:text-ink-muted:hover{--tw-text-opacity:1;color:rgb(139 147 167/var(--tw-text-opacity,1))}.hover\:text-status-busy:hover{--tw-text-opacity:1;color:rgb(242 99 123/var(--tw-text-opacity,1))}.hover\:underline:hover{text-decoration-line:underline}.focus\:ring-accent:focus{--tw-ring-opacity:1;--tw-ring-color:rgb(232 163 61/var(--tw-ring-opacity,1))}.focus\:ring-offset-base:focus{--tw-ring-offset-color:#12141a}.group:hover .group-hover\:text-accent{--tw-text-opacity:1;color:rgb(232 163 61/var(--tw-text-opacity,1))}@media (min-width:640px){.sm\:col-span-2{grid-column:span 2/span 2}.sm\:ml-\[8\.25rem\]{margin-left:8.25rem}.sm\:inline-flex{display:inline-flex}.sm\:hidden{display:none}.sm\:grid-cols-2{grid-template-columns:repeat(2,minmax(0,1fr))}.sm\:grid-cols-3{grid-template-columns:repeat(3,minmax(0,1fr))}.sm\:grid-cols-4{grid-template-columns:repeat(4,minmax(0,1fr))}.sm\:flex-row{flex-direction:row}.sm\:items-end{align-items:flex-end}.sm\:items-center{align-items:center}.sm\:justify-between{justify-content:space-between}.sm\:gap-2{gap:.5rem}.sm\:p-5{padding:1.25rem}.sm\:p-6{padding:1.5rem}.sm\:p-7{padding:1.75rem}.sm\:p-8{padding:2rem}.sm\:px-6{padding-left:1.5rem;padding-right:1.5rem}.sm\:py-14{padding-top:3.5rem;padding-bottom:3.5rem}.sm\:py-16{padding-top:4rem;padding-bottom:4rem}.sm\:text-2xl{font-size:1.5rem;line-height:2rem}}@media (min-width:1024px){.lg\:static{position:static}.lg\:col-span-1{grid-column:span 1/span 1}.lg\:col-span-2{grid-column:span 2/span 2}.lg\:block{display:block}.lg\:flex{display:flex}.lg\:grid{display:grid}.lg\:hidden{display:none}.lg\:min-h-0{min-height:0}.lg\:w-64{width:16rem}.lg\:shrink-0{flex-shrink:0}.lg\:translate-x-0{--tw-translate-x:0px;transform:translate(var(--tw-translate-x),var(--tw-translate-y)) rotate(var(--tw-rotate)) skewX(var(--tw-skew-x)) skewY(var(--tw-skew-y)) scaleX(var(--tw-scale-x)) scaleY(var(--tw-scale-y))}.lg\:grid-cols-2{grid-template-columns:repeat(2,minmax(0,1fr))}.lg\:grid-cols-3{grid-template-columns:repeat(3,minmax(0,1fr))}.lg\:flex-col{flex-direction:column}.lg\:justify-center{justify-content:center}.lg\:p-12{padding:3rem}.lg\:px-10{padding-left:2.5rem;padding-right:2.5rem}.lg\:px-8{padding-left:2rem;padding-right:2rem}.lg\:py-10{padding-top:2.5rem;padding-bottom:2.5rem}.lg\:text-left{text-align:left}}@media (min-width:1280px){.xl\:bottom-16{bottom:4rem}.xl\:top-16{top:4rem}.xl\:p-16{padding:4rem}}
CLAUDE_PATCH_EOF

mkdir -p "$APP_DIR/migrations/versions"
cat > "$APP_DIR/migrations/versions/32925cbc8dca_add_out_of_hours_bookings.py" << 'CLAUDE_PATCH_EOF'
"""add out of hours bookings

Revision ID: 32925cbc8dca
Revises: 3c9108a5b114
Create Date: 2026-08-12 22:58:04.262214

"""
from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision = '32925cbc8dca'
down_revision = '3c9108a5b114'
branch_labels = None
depends_on = None


def upgrade():
    # NOT NULL boolean columns start nullable so this works against tables
    # that may already have rows — backfilled to False below, then
    # tightened to NOT NULL once every row has a value.
    with op.batch_alter_table('bookings', schema=None) as batch_op:
        batch_op.add_column(sa.Column('is_out_of_hours', sa.Boolean(), nullable=True))
        batch_op.add_column(sa.Column('out_of_hours_fee_shown', sa.String(length=30), nullable=True))

    with op.batch_alter_table('settings', schema=None) as batch_op:
        batch_op.add_column(sa.Column('allow_out_of_hours_bookings', sa.Boolean(), nullable=True))
        batch_op.add_column(sa.Column('out_of_hours_booking_fee', sa.String(length=30), nullable=True))

    connection = op.get_bind()
    connection.execute(sa.text("UPDATE bookings SET is_out_of_hours = 0 WHERE is_out_of_hours IS NULL"))
    connection.execute(
        sa.text("UPDATE settings SET allow_out_of_hours_bookings = 0 WHERE allow_out_of_hours_bookings IS NULL")
    )

    with op.batch_alter_table('bookings', schema=None) as batch_op:
        batch_op.alter_column('is_out_of_hours', existing_type=sa.Boolean(), nullable=False)

    with op.batch_alter_table('settings', schema=None) as batch_op:
        batch_op.alter_column('allow_out_of_hours_bookings', existing_type=sa.Boolean(), nullable=False)


def downgrade():
    with op.batch_alter_table('settings', schema=None) as batch_op:
        batch_op.drop_column('out_of_hours_booking_fee')
        batch_op.drop_column('allow_out_of_hours_bookings')

    with op.batch_alter_table('bookings', schema=None) as batch_op:
        batch_op.drop_column('out_of_hours_fee_shown')
        batch_op.drop_column('is_out_of_hours')
CLAUDE_PATCH_EOF

echo "Files written."

bold() { printf "\033[1m%s\033[0m\n" "$1"; }
cd "$APP_DIR"
bold "== Database migration =="
if [ -x "$APP_DIR/.venv/bin/python" ]; then PY="$APP_DIR/.venv/bin/python"
elif [ -x "$APP_DIR/venv/bin/python" ]; then PY="$APP_DIR/venv/bin/python"
else PY="$(command -v python3)"; fi
export FLASK_APP=run.py
"$PY" -m flask db upgrade

bold "== Restarting $SERVICE_NAME =="
sudo systemctl restart "$SERVICE_NAME"

sleep 2
CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PORT}/book" 2>/dev/null || echo 000)
if [ "$CODE" = "200" ]; then bold "Done — booking page responding. Turn on the out-of-hours toggle in Settings when ready."
else echo "Did not respond as expected (HTTP $CODE) — check: sudo journalctl -u $SERVICE_NAME -n 50"; fi
