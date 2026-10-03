#!/usr/bin/env bash
# Scheduler update: Discord bot + CalendarMaker public link.
# Only creates files that don't already exist -- never overwrites.
set -e

mkdir -p app app/models app/routes app/templates/admin app/templates/calendarmaker discord_bot migrations/versions

if [ -e "app/models/settings.py" ]; then
  echo "skip (exists): app/models/settings.py"
else
  cat > app/models/settings.py << 'SCHEDEOF'
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

    def __repr__(self):  # pragma: no cover
        return f"<Settings user_id={self.user_id} manual_status={self.manual_status}>"
SCHEDEOF
  echo "created: app/models/settings.py"
fi

if [ -e "app/models/booking.py" ]; then
  echo "skip (exists): app/models/booking.py"
else
  cat > app/models/booking.py << 'SCHEDEOF'
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

    # "Spam ping" — repeated DM nags (new bookings and out-of-hours bookings)
    # that keep firing until the admin hits Stop on the button in the DM.
    # See discord_bot/notifier.py run_ping_tick().
    discord_ping_active = db.Column(db.Boolean, nullable=False, default=False)
    discord_ping_count = db.Column(db.Integer, nullable=False, default=0)
    discord_ping_last_sent_at = db.Column(db.DateTime, nullable=True)
    # Snowflake ID (string) of the most recent ping DM — deleted when the
    # next ping goes out, so only the latest ping is ever visible.
    discord_ping_last_message_id = db.Column(db.String(32), nullable=True)

    def __repr__(self):  # pragma: no cover
        return f"<Booking {self.name} {self.start_datetime} [{self.status}]>"
SCHEDEOF
  echo "created: app/models/booking.py"
fi

if [ -e "app/models/calendar_maker.py" ]; then
  echo "skip (exists): app/models/calendar_maker.py"
else
  cat > app/models/calendar_maker.py << 'SCHEDEOF'
import secrets
from datetime import datetime, timezone as dt_timezone

from werkzeug.security import check_password_hash, generate_password_hash

from app import db


class SharedCalendar(db.Model):
    """A calendar created via /calendarmaker, identified by a random share link.

    Deliberately independent of the User/admin system — anyone can create
    one without an account. Access is controlled per-person via
    CalendarAccess (email + PIN) rather than a login.
    """

    __tablename__ = "shared_calendars"

    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(120), nullable=False, default="My Calendar")
    share_token = db.Column(db.String(32), nullable=False, unique=True, index=True)
    # A second, separate link: read-only, no PIN/email setup, nothing
    # identifying whoever's viewing it. Deliberately a different token
    # from share_token so handing out the public link never also hands
    # out the ability to join as a member.
    public_token = db.Column(db.String(32), nullable=False, unique=True, index=True)
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

    @staticmethod
    def generate_public_token():
        # Same shape as share_token — kept as a separate method (rather
        # than reusing generate_share_token everywhere) so the two are
        # obviously distinct concepts in code, not just in the database.
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
SCHEDEOF
  echo "created: app/models/calendar_maker.py"
fi

if [ -e "app/forms.py" ]; then
  echo "skip (exists): app/forms.py"
else
  cat > app/forms.py << 'SCHEDEOF'
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


class DiscordSettingsForm(FlaskForm):
    discord_user_id = StringField(
        "Your Discord user ID",
        validators=[Optional(), Length(max=32)],
    )
    notify_discord_new_booking = BooleanField("DM me when someone books time with me")
    notify_discord_cancellation = BooleanField("DM me when someone cancels a booking")
    notify_discord_reminders = BooleanField("DM me reminders (start of day, 1 hour before, 15 minutes before)")
    discord_spam_ping_enabled = BooleanField("Keep re-pinging new / out-of-hours bookings until I hit Stop")

    def validate_discord_user_id(self, field):
        value = (field.data or "").strip()
        if value and not value.isdigit():
            raise ValidationError("That doesn't look like a Discord user ID — it should be all digits.")


class DiscordTestForm(FlaskForm):
    pass


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
SCHEDEOF
  echo "created: app/forms.py"
fi

if [ -e "app/routes/admin.py" ]; then
  echo "skip (exists): app/routes/admin.py"
else
  cat > app/routes/admin.py << 'SCHEDEOF'
from datetime import datetime, time as dt_time, timedelta, timezone as dt_timezone

from flask import Blueprint, abort, flash, redirect, render_template, request, url_for
from flask_login import current_user, login_required

from app import db
from app.forms import BookingOutOfHoursForm, BookingTypeForm, BreakForm, CSRFOnlyForm, CurrentTaskForm, DiscordSettingsForm, DiscordTestForm, ISPFeeForm, NotificationSettingsForm, ProfileForm, StatusOverrideForm, TimeOffForm
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
    discord_form = DiscordSettingsForm(
        discord_user_id=settings_row.discord_user_id or "",
        notify_discord_new_booking=settings_row.notify_discord_new_booking,
        notify_discord_cancellation=settings_row.notify_discord_cancellation,
        notify_discord_reminders=settings_row.notify_discord_reminders,
        discord_spam_ping_enabled=settings_row.discord_spam_ping_enabled,
    )
    discord_test_form = DiscordTestForm()
    status_url = url_for("public.status_page", _external=True)
    booking_url = url_for("public.booking_types", _external=True)
    widget_url = url_for("public.widget_script", _external=True)
    return render_template(
        "admin/settings.html",
        profile_form=profile_form,
        notif_form=notif_form,
        isp_fee_form=isp_fee_form,
        booking_ooh_form=booking_ooh_form,
        discord_form=discord_form,
        discord_test_form=discord_test_form,
        discord_user_id_set=bool(settings_row.discord_user_id),
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


@admin_bp.route("/settings/discord", methods=["POST"])
@login_required
def update_discord():
    form = DiscordSettingsForm()
    if form.validate_on_submit():
        settings_row = Settings.for_user(current_user)
        settings_row.discord_user_id = form.discord_user_id.data.strip() or None
        settings_row.notify_discord_new_booking = form.notify_discord_new_booking.data
        settings_row.notify_discord_cancellation = form.notify_discord_cancellation.data
        settings_row.notify_discord_reminders = form.notify_discord_reminders.data
        settings_row.discord_spam_ping_enabled = form.discord_spam_ping_enabled.data
        db.session.commit()
        flash("Discord settings updated.", "success")
    else:
        for field_errors in form.errors.values():
            for err in field_errors:
                flash(err, "error")
    return redirect(url_for("admin.settings"))


@admin_bp.route("/settings/discord/test", methods=["POST"])
@login_required
def discord_test():
    form = DiscordTestForm()
    settings_row = Settings.for_user(current_user)
    if form.validate_on_submit():
        if not settings_row.discord_user_id:
            flash("Add your Discord user ID first, then save, then send a test DM.", "error")
        else:
            settings_row.discord_test_requested_at = datetime.now(dt_timezone.utc)
            db.session.commit()
            flash("Test DM queued — check Discord in about a minute. Make sure you share a server with the bot or have DM'd it before, or Discord will block the message.", "success")
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
SCHEDEOF
  echo "created: app/routes/admin.py"
fi

if [ -e "app/routes/calendarmaker.py" ]; then
  echo "skip (exists): app/routes/calendarmaker.py"
else
  cat > app/routes/calendarmaker.py << 'SCHEDEOF'
from datetime import date, datetime, timedelta

from flask import Blueprint, flash, make_response, redirect, render_template, request, url_for

from app import db
from app.forms import (
    CalendarEventForm,
    CreateCalendarForm,
    PinLoginForm,
    RecoverCalendarForm,
    SetupAccessForm,
)
from app.models.calendar_maker import CalendarAccess, CalendarEvent, SharedCalendar
from app.services.calendar_access import (
    clear_pin_attempts,
    clear_unlock_cookie,
    get_device_access_id,
    get_unlocked_access_id,
    pin_is_locked_out,
    record_failed_pin_attempt,
    set_device_cookie,
    set_unlock_cookie,
)

calendarmaker_bp = Blueprint("calendarmaker", __name__, url_prefix="/calendarmaker")


def _get_calendar_or_404(share_token):
    return SharedCalendar.query.filter_by(share_token=share_token).first_or_404()


def _current_access(calendar):
    """The unlocked CalendarAccess for this browser+calendar, or None."""
    access_id = get_unlocked_access_id(request, calendar.share_token)
    if not access_id:
        return None
    return CalendarAccess.query.filter_by(id=access_id, shared_calendar_id=calendar.id).first()


@calendarmaker_bp.route("/", strict_slashes=False)
def welcome():
    return render_template("calendarmaker/welcome.html")


@calendarmaker_bp.route("/new", methods=["GET", "POST"])
def new_calendar():
    form = CreateCalendarForm()
    if form.validate_on_submit():
        calendar = SharedCalendar(
            name=(form.name.data or "My Calendar").strip() or "My Calendar",
            share_token=SharedCalendar.generate_share_token(),
            public_token=SharedCalendar.generate_public_token(),
        )
        db.session.add(calendar)
        db.session.commit()
        flash("Calendar created — set up your own access below to finish.", "success")
        return redirect(url_for("calendarmaker.access_gate", share_token=calendar.share_token))
    return render_template("calendarmaker/new.html", form=form)


@calendarmaker_bp.route("/c/<share_token>", methods=["GET", "POST"])
def access_gate(share_token):
    """The single entry point for a shared link. Depending on what this
    browser already proves, this shows one of three things:
      - already unlocked this session -> straight through to the calendar
      - recognized device, not yet unlocked -> PIN prompt
      - unrecognized device -> set up access (email + choose PIN), which
        also transparently becomes a PIN prompt if the email they enter
        already has access (covers "opened on a new device without the
        remembered cookie" without a separate code path).
    """
    calendar = _get_calendar_or_404(share_token)

    if _current_access(calendar):
        return redirect(url_for("calendarmaker.view_calendar", share_token=share_token))

    device_access_id = get_device_access_id(request, share_token)
    if device_access_id:
        access = CalendarAccess.query.filter_by(id=device_access_id, shared_calendar_id=calendar.id).first()
        if access:
            return _pin_prompt(calendar, access)

    return _setup_or_recognize(calendar)


def _pin_prompt(calendar, access):
    form = PinLoginForm()

    if form.validate_on_submit():
        if pin_is_locked_out(access.id):
            flash("Too many incorrect attempts. Please wait a few minutes and try again.", "error")
        elif access.check_pin(form.pin.data):
            clear_pin_attempts(access.id)
            access.last_accessed_at = datetime.utcnow()
            db.session.commit()
            resp = make_response(redirect(url_for("calendarmaker.view_calendar", share_token=calendar.share_token)))
            set_unlock_cookie(resp, calendar.share_token, access.id)
            set_device_cookie(resp, calendar.share_token, access.id)
            return resp
        else:
            record_failed_pin_attempt(access.id)
            flash("Incorrect PIN.", "error")

    return render_template(
        "calendarmaker/enter_pin.html", calendar=calendar, form=form, email=access.email
    )


def _setup_or_recognize(calendar):
    form = SetupAccessForm()

    if form.validate_on_submit():
        email = form.email.data.strip().lower()
        existing = CalendarAccess.query.filter_by(shared_calendar_id=calendar.id, email=email).first()

        if existing:
            # Someone who already has access, opening the link on a device
            # that doesn't have the "remembered" cookie. Treat their PIN
            # field as a login attempt against the existing record rather
            # than silently creating a second, conflicting one.
            if pin_is_locked_out(existing.id):
                flash("Too many incorrect attempts. Please wait a few minutes and try again.", "error")
            elif existing.check_pin(form.pin.data):
                clear_pin_attempts(existing.id)
                existing.last_accessed_at = datetime.utcnow()
                db.session.commit()
                resp = make_response(
                    redirect(url_for("calendarmaker.view_calendar", share_token=calendar.share_token))
                )
                set_unlock_cookie(resp, calendar.share_token, existing.id)
                set_device_cookie(resp, calendar.share_token, existing.id)
                return resp
            else:
                record_failed_pin_attempt(existing.id)
                flash("That email already has access to this calendar, but the PIN doesn't match.", "error")
        else:
            access = CalendarAccess(shared_calendar_id=calendar.id, email=email)
            access.set_pin(form.pin.data)
            access.last_accessed_at = datetime.utcnow()
            db.session.add(access)
            db.session.commit()
            flash("You're all set.", "success")
            resp = make_response(
                redirect(url_for("calendarmaker.view_calendar", share_token=calendar.share_token))
            )
            set_unlock_cookie(resp, calendar.share_token, access.id)
            set_device_cookie(resp, calendar.share_token, access.id)
            return resp

    return render_template("calendarmaker/setup_access.html", calendar=calendar, form=form)


@calendarmaker_bp.route("/c/<share_token>/calendar", methods=["GET", "POST"])
def view_calendar(share_token):
    calendar = _get_calendar_or_404(share_token)
    access = _current_access(calendar)
    if not access:
        return redirect(url_for("calendarmaker.access_gate", share_token=share_token))

    form = CalendarEventForm()
    if form.validate_on_submit():
        db.session.add(
            CalendarEvent(
                shared_calendar_id=calendar.id,
                title=form.title.data.strip(),
                event_date=form.event_date.data,
                start_time=form.start_time.data,
                end_time=form.end_time.data,
                notes=(form.notes.data or "").strip() or None,
                created_by_email=access.email,
            )
        )
        db.session.commit()
        flash("Event added.", "success")
        return redirect(url_for("calendarmaker.view_calendar", share_token=share_token))

    today = date.today()
    upcoming = (
        CalendarEvent.query.filter(
            CalendarEvent.shared_calendar_id == calendar.id,
            CalendarEvent.event_date >= today - timedelta(days=1),
        )
        .order_by(CalendarEvent.event_date, CalendarEvent.start_time)
        .all()
    )
    past = (
        CalendarEvent.query.filter(
            CalendarEvent.shared_calendar_id == calendar.id,
            CalendarEvent.event_date < today - timedelta(days=1),
        )
        .order_by(CalendarEvent.event_date.desc())
        .limit(20)
        .all()
    )

    share_url = url_for("calendarmaker.access_gate", share_token=share_token, _external=True)
    public_url = url_for("calendarmaker.public_view", public_token=calendar.public_token, _external=True)
    member_count = CalendarAccess.query.filter_by(shared_calendar_id=calendar.id).count()

    return render_template(
        "calendarmaker/calendar.html",
        calendar=calendar,
        access=access,
        form=form,
        upcoming=upcoming,
        past=past,
        share_url=share_url,
        public_url=public_url,
        member_count=member_count,
    )


@calendarmaker_bp.route("/pub/<public_token>")
def public_view(public_token):
    """Read-only, no PIN/email, no identity — anyone with the link can look
    but not touch. Deliberately kept separate from view_calendar/access_gate
    so this link never doubles as an invite to join as a member."""
    calendar = SharedCalendar.query.filter_by(public_token=public_token).first_or_404()

    today = date.today()
    upcoming = (
        CalendarEvent.query.filter(
            CalendarEvent.shared_calendar_id == calendar.id,
            CalendarEvent.event_date >= today - timedelta(days=1),
        )
        .order_by(CalendarEvent.event_date, CalendarEvent.start_time)
        .all()
    )
    past = (
        CalendarEvent.query.filter(
            CalendarEvent.shared_calendar_id == calendar.id,
            CalendarEvent.event_date < today - timedelta(days=1),
        )
        .order_by(CalendarEvent.event_date.desc())
        .limit(20)
        .all()
    )

    return render_template(
        "calendarmaker/public.html",
        calendar=calendar,
        upcoming=upcoming,
        past=past,
    )


@calendarmaker_bp.route("/c/<share_token>/events/<int:event_id>/delete", methods=["POST"])
def delete_event(share_token, event_id):
    calendar = _get_calendar_or_404(share_token)
    access = _current_access(calendar)
    if not access:
        return redirect(url_for("calendarmaker.access_gate", share_token=share_token))

    event = CalendarEvent.query.filter_by(id=event_id, shared_calendar_id=calendar.id).first_or_404()
    db.session.delete(event)
    db.session.commit()
    flash("Event removed.", "success")
    return redirect(url_for("calendarmaker.view_calendar", share_token=share_token))


@calendarmaker_bp.route("/c/<share_token>/lock", methods=["POST"])
def lock_calendar(share_token):
    calendar = _get_calendar_or_404(share_token)
    resp = make_response(redirect(url_for("calendarmaker.access_gate", share_token=share_token)))
    clear_unlock_cookie(resp, share_token)
    flash("Locked. Enter your PIN to access this calendar again.", "info")
    return resp


@calendarmaker_bp.route("/recover", methods=["GET", "POST"])
def recover():
    form = RecoverCalendarForm()
    results = None

    if form.validate_on_submit():
        email = form.email.data.strip().lower()
        accesses = (
            CalendarAccess.query.filter_by(email=email)
            .join(SharedCalendar)
            .order_by(SharedCalendar.created_at.desc())
            .all()
        )
        results = accesses
        if not accesses:
            flash("No calendars found for that email.", "info")

    return render_template("calendarmaker/recover.html", form=form, results=results)


@calendarmaker_bp.route("/recover/<int:access_id>/use")
def recover_use(access_id):
    """Reached from a recovery result: marks this browser as recognized for
    that access record (without unlocking it — a PIN is still required),
    so the person lands on the normal single-field PIN prompt instead of
    being sent back through the full email+choose-PIN setup form."""
    access = CalendarAccess.query.get_or_404(access_id)
    calendar = access.calendar
    resp = make_response(redirect(url_for("calendarmaker.access_gate", share_token=calendar.share_token)))
    set_device_cookie(resp, calendar.share_token, access.id)
    return resp
SCHEDEOF
  echo "created: app/routes/calendarmaker.py"
fi

if [ -e "app/__init__.py" ]; then
  echo "skip (exists): app/__init__.py"
else
  cat > app/__init__.py << 'SCHEDEOF'
import os

from flask import Flask
from flask_login import LoginManager
from flask_migrate import Migrate
from flask_sqlalchemy import SQLAlchemy
from flask_wtf import CSRFProtect

from config import config_by_name

db = SQLAlchemy()
migrate = Migrate()
login_manager = LoginManager()
csrf = CSRFProtect()


def create_app(config_name=None):
    config_name = config_name or os.environ.get("FLASK_ENV", "development")

    app = Flask(__name__, instance_relative_config=True)
    app.config.from_object(config_by_name[config_name])

    os.makedirs(app.instance_path, exist_ok=True)

    if config_name == "production":
        config_by_name["production"].validate()

    db.init_app(app)
    migrate.init_app(app, db)
    login_manager.init_app(app)
    csrf.init_app(app)

    from app.services.crypto import init_encryption
    init_encryption(app.instance_path)

    login_manager.login_view = "auth.login"
    login_manager.login_message = "Please sign in to continue."
    login_manager.login_message_category = "info"

    from app import models  # noqa: F401 - ensures every model is registered before migrations run
    from app.models.user import User

    @login_manager.user_loader
    def load_user(user_id):
        return db.session.get(User, int(user_id))

    from app.routes.auth import auth_bp
    from app.routes.admin import admin_bp
    from app.routes.public import public_bp
    from app.routes.calendarmaker import calendarmaker_bp
    from app.routes.isp_support import isp_support_bp

    app.register_blueprint(auth_bp)
    app.register_blueprint(admin_bp)
    app.register_blueprint(public_bp)
    app.register_blueprint(calendarmaker_bp)
    app.register_blueprint(isp_support_bp)

    register_cli(app)
    register_error_handlers(app)

    @app.context_processor
    def inject_globals():
        return {"app_name": "Scheduler"}

    return app


def register_error_handlers(app):
    from flask import flash, redirect, render_template, request, url_for
    from flask_login import current_user
    from flask_wtf.csrf import CSRFError

    @app.errorhandler(404)
    def not_found(e):
        return render_template("errors/404.html"), 404

    @app.errorhandler(500)
    def server_error(e):
        return render_template("errors/500.html"), 500

    @app.errorhandler(CSRFError)
    def csrf_error(e):
        # Without this, Flask-WTF's default is a bare, unstyled "400 Bad
        # Request" page with no nav and no way back — indistinguishable from
        # the app being broken. This turns it into a normal flash message and
        # sends the person back to the page they were on, so a save that
        # fails because a session expired reads as "try that again", not
        # "the site is down".
        flash("Your session expired — please try that again.", "error")
        if current_user.is_authenticated:
            fallback = url_for("admin.dashboard")
        else:
            fallback = url_for("public.booking_types")
        return redirect(request.referrer or fallback)


def register_cli(app):
    import click

    @app.cli.command("create-admin")
    @click.option("--email", prompt=True)
    @click.option("--name", prompt=True)
    @click.option("--password", prompt=True, hide_input=True, confirmation_prompt=True)
    def create_admin(email, name, password):
        """Create the admin user (this app supports a single admin account)."""
        from app.models.user import User

        if User.query.filter_by(email=email.lower().strip()).first():
            click.echo(f"A user with email {email} already exists.")
            return

        user = User(email=email.lower().strip(), name=name)
        user.set_password(password)
        db.session.add(user)
        db.session.commit()
        click.echo(f"Admin user '{name}' <{email}> created.")

    @app.cli.command("discord-bootstrap")
    def discord_bootstrap():
        """Run once, right after deploying the Discord bot.

        Marks every existing booking as already-notified for the "new
        booking" DM, so the bot's first poll doesn't flood you with a DM
        for every booking that already existed. Bookings still get their
        day-start / 1-hour / 15-minute reminder DMs as normal — this only
        skips the one-off "new booking" ping for pre-existing bookings.
        """
        from app.models.booking import Booking

        updated_new = Booking.query.filter_by(discord_new_notified=False).update(
            {"discord_new_notified": True}, synchronize_session=False
        )
        updated_cancel = Booking.query.filter_by(discord_cancel_notified=False).update(
            {"discord_cancel_notified": True}, synchronize_session=False
        )
        db.session.commit()
        click.echo(f"Marked {updated_new} existing booking(s) as already-notified, {updated_cancel} as already-notified of cancellation.")
SCHEDEOF
  echo "created: app/__init__.py"
fi

if [ -e "app/templates/admin/settings.html" ]; then
  echo "skip (exists): app/templates/admin/settings.html"
else
  cat > app/templates/admin/settings.html << 'SCHEDEOF'
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
    <h2 class="font-display text-base font-semibold text-ink mb-1">Discord notifications</h2>
    <p class="mb-4 text-sm text-ink-muted">
      Get DM'd on Discord instead of (or as well as) email — new bookings, cancellations, and
      reminders at the start of the day, 1 hour before, and 15 minutes before each booking.
      Requires the Discord bot to be running (see <code class="text-xs">discord_bot/README.md</code>).
      Right-click your name in Discord → <strong>Copy User ID</strong> (enable Developer Mode in
      Settings → Advanced first). The bot can only DM you if you share a server with it or have
      DM'd it before.
    </p>
    <form method="POST" action="{{ url_for('admin.update_discord') }}" novalidate>
      {{ discord_form.hidden_tag() }}

      <div class="mb-5">
        <label class="field-label" for="{{ discord_form.discord_user_id.id }}">{{ discord_form.discord_user_id.label.text }}</label>
        {{ discord_form.discord_user_id(class_="field-input font-mono", placeholder="e.g. 123456789012345678") }}
        {% for error in discord_form.discord_user_id.errors %}<p class="field-error">{{ error }}</p>{% endfor %}
      </div>

      <label class="mb-3 flex items-start gap-2.5 text-sm text-ink-muted">
        {{ discord_form.notify_discord_new_booking(class_="mt-0.5 rounded border-border bg-surface-raised text-accent focus:ring-accent focus:ring-offset-base") }}
        {{ discord_form.notify_discord_new_booking.label.text }}
      </label>
      <label class="mb-3 flex items-start gap-2.5 text-sm text-ink-muted">
        {{ discord_form.notify_discord_cancellation(class_="mt-0.5 rounded border-border bg-surface-raised text-accent focus:ring-accent focus:ring-offset-base") }}
        {{ discord_form.notify_discord_cancellation.label.text }}
      </label>
      <label class="mb-5 flex items-start gap-2.5 text-sm text-ink-muted">
        {{ discord_form.notify_discord_reminders(class_="mt-0.5 rounded border-border bg-surface-raised text-accent focus:ring-accent focus:ring-offset-base") }}
        {{ discord_form.notify_discord_reminders.label.text }}
      </label>
      <label class="mb-5 flex items-start gap-2.5 text-sm text-ink-muted">
        {{ discord_form.discord_spam_ping_enabled(class_="mt-0.5 rounded border-border bg-surface-raised text-accent focus:ring-accent focus:ring-offset-base") }}
        <span>{{ discord_form.discord_spam_ping_enabled.label.text }}
          <span class="block text-xs text-ink-muted mt-0.5">Repeats every 30s (each ping replaces the last) until you press the Stop button on the DM itself.</span>
        </span>
      </label>

      <button type="submit" class="btn-primary">Save Discord settings</button>
    </form>

    {% if discord_user_id_set %}
    <form method="POST" action="{{ url_for('admin.discord_test') }}" novalidate class="mt-3">
      {{ discord_test_form.hidden_tag() }}
      <button type="submit" class="btn-secondary">Send test DM</button>
    </form>
    {% endif %}
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
SCHEDEOF
  echo "created: app/templates/admin/settings.html"
fi

if [ -e "app/templates/calendarmaker/calendar.html" ]; then
  echo "skip (exists): app/templates/calendarmaker/calendar.html"
else
  cat > app/templates/calendarmaker/calendar.html << 'SCHEDEOF'
{% extends "base.html" %}
{% block title %}{{ calendar.name }} · {{ app_name }}{% endblock %}
{% block body %}
<div class="mx-auto max-w-2xl px-4 py-10 sm:py-14">

  <div class="mb-6 flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
    <div>
      <h1 class="font-display text-2xl font-semibold text-ink">{{ calendar.name }}</h1>
      <p class="mt-1 text-sm text-ink-muted">Signed in as {{ access.email }} · {{ member_count }} member{% if member_count != 1 %}s{% endif %}</p>
    </div>
    <form method="POST" action="{{ url_for('calendarmaker.lock_calendar', share_token=calendar.share_token) }}">
      <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
      <button type="submit" class="btn-secondary">Lock</button>
    </form>
  </div>

  {% include "partials/flash.html" %}

  <div class="card mb-6 p-5 sm:p-6">
    <p class="mb-2 text-xs font-semibold uppercase tracking-wide text-ink-muted">Invite link</p>
    <div class="flex gap-2">
      <input type="text" readonly value="{{ share_url }}" class="field-input font-mono text-xs" onclick="this.select()">
      <button type="button" class="btn-secondary shrink-0" onclick="navigator.clipboard.writeText('{{ share_url }}'); this.textContent='Copied!'; setTimeout(() => this.textContent='Copy', 1500);">Copy</button>
    </div>
    <p class="mt-2 text-xs text-ink-faint">Anyone with this link can join — they'll set their own PIN and email, and can add events.</p>

    <p class="mt-5 mb-2 text-xs font-semibold uppercase tracking-wide text-ink-muted">Public link</p>
    <div class="flex gap-2">
      <input type="text" readonly value="{{ public_url }}" class="field-input font-mono text-xs" onclick="this.select()">
      <button type="button" class="btn-secondary shrink-0" onclick="navigator.clipboard.writeText('{{ public_url }}'); this.textContent='Copied!'; setTimeout(() => this.textContent='Copy', 1500);">Copy</button>
    </div>
    <p class="mt-2 text-xs text-ink-faint">Read-only, no sign-up — for posting somewhere public. Anyone with this link can view events but can't add or remove anything.</p>
  </div>

  <div class="card mb-6 p-5 sm:p-6">
    <p class="mb-4 text-xs font-semibold uppercase tracking-wide text-ink-muted">Add an event</p>
    <form method="POST" novalidate>
      {{ form.hidden_tag() }}
      <div class="mb-3">
        <label class="field-label" for="{{ form.title.id }}">Title</label>
        {{ form.title(class_="field-input", placeholder="e.g. Team lunch") }}
        {% for error in form.title.errors %}<p class="field-error">{{ error }}</p>{% endfor %}
      </div>
      <div class="mb-3 grid grid-cols-3 gap-3">
        <div>
          <label class="field-label" for="{{ form.event_date.id }}">Date</label>
          {{ form.event_date(class_="field-input") }}
        </div>
        <div>
          <label class="field-label" for="{{ form.start_time.id }}">Start</label>
          {{ form.start_time(class_="field-input") }}
        </div>
        <div>
          <label class="field-label" for="{{ form.end_time.id }}">End</label>
          {{ form.end_time(class_="field-input") }}
        </div>
      </div>
      {% for error in form.event_date.errors + form.end_time.errors %}
        <p class="field-error -mt-2 mb-3">{{ error }}</p>
      {% endfor %}
      <div class="mb-4">
        <label class="field-label" for="{{ form.notes.id }}">Notes (optional)</label>
        {{ form.notes(class_="field-input", rows=2) }}
      </div>
      <button type="submit" class="btn-primary">Add event</button>
    </form>
  </div>

  <div class="card divide-y divide-border">
    {% if upcoming %}
      {% for e in upcoming %}
      <div class="flex items-center justify-between gap-4 p-4">
        <div class="min-w-0">
          <p class="font-medium text-ink">{{ e.title }}</p>
          <p class="mt-0.5 text-sm text-ink-muted">
            {{ e.event_date.strftime('%a %d %b %Y') }}
            {% if e.start_time %} · {{ e.start_time.strftime('%H:%M') }}{% if e.end_time %}–{{ e.end_time.strftime('%H:%M') }}{% endif %}{% endif %}
          </p>
          {% if e.notes %}<p class="mt-1 text-sm text-ink-faint">{{ e.notes }}</p>{% endif %}
          <p class="mt-1 text-xs text-ink-faint">Added by {{ e.created_by_email }}</p>
        </div>
        <form method="POST" action="{{ url_for('calendarmaker.delete_event', share_token=calendar.share_token, event_id=e.id) }}">
          <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
          <button type="submit" class="btn-ghost !px-2" aria-label="Remove">
            <svg xmlns="http://www.w3.org/2000/svg" class="h-[18px] w-[18px]" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="3 6 5 6 21 6"/><path d="M19 6l-1 14a2 2 0 01-2 2H8a2 2 0 01-2-2L5 6m5 0V4a2 2 0 012-2h0a2 2 0 012 2v2"/></svg>
          </button>
        </form>
      </div>
      {% endfor %}
    {% else %}
      <div class="p-8 text-center">
        <p class="text-sm text-ink-muted">No upcoming events yet.</p>
      </div>
    {% endif %}
  </div>

  {% if past %}
  <details class="mt-4">
    <summary class="cursor-pointer text-sm font-medium text-ink-muted hover:text-ink">Past events ({{ past|length }})</summary>
    <div class="card mt-2 divide-y divide-border">
      {% for e in past %}
      <div class="p-4 opacity-60">
        <p class="font-medium text-ink">{{ e.title }}</p>
        <p class="mt-0.5 text-sm text-ink-muted">{{ e.event_date.strftime('%a %d %b %Y') }}</p>
      </div>
      {% endfor %}
    </div>
  </details>
  {% endif %}

</div>
{% endblock %}
SCHEDEOF
  echo "created: app/templates/calendarmaker/calendar.html"
fi

if [ -e "app/templates/calendarmaker/public.html" ]; then
  echo "skip (exists): app/templates/calendarmaker/public.html"
else
  cat > app/templates/calendarmaker/public.html << 'SCHEDEOF'
{% extends "base.html" %}
{% block title %}{{ calendar.name }} · {{ app_name }}{% endblock %}
{% block body %}
<div class="mx-auto max-w-2xl px-4 py-10 sm:py-14">

  <div class="mb-6">
    <h1 class="font-display text-2xl font-semibold text-ink">{{ calendar.name }}</h1>
    <p class="mt-1 text-sm text-ink-muted">Public view — read-only</p>
  </div>

  {% include "partials/flash.html" %}

  <div class="card divide-y divide-border">
    {% if upcoming %}
      {% for e in upcoming %}
      <div class="p-4">
        <p class="font-medium text-ink">{{ e.title }}</p>
        <p class="mt-0.5 text-sm text-ink-muted">
          {{ e.event_date.strftime('%a %d %b %Y') }}
          {% if e.start_time %} · {{ e.start_time.strftime('%H:%M') }}{% if e.end_time %}–{{ e.end_time.strftime('%H:%M') }}{% endif %}{% endif %}
        </p>
        {% if e.notes %}<p class="mt-1 text-sm text-ink-faint">{{ e.notes }}</p>{% endif %}
      </div>
      {% endfor %}
    {% else %}
      <div class="p-8 text-center">
        <p class="text-sm text-ink-muted">No upcoming events yet.</p>
      </div>
    {% endif %}
  </div>

  {% if past %}
  <details class="mt-4">
    <summary class="cursor-pointer text-sm font-medium text-ink-muted hover:text-ink">Past events ({{ past|length }})</summary>
    <div class="card mt-2 divide-y divide-border">
      {% for e in past %}
      <div class="p-4 opacity-60">
        <p class="font-medium text-ink">{{ e.title }}</p>
        <p class="mt-0.5 text-sm text-ink-muted">{{ e.event_date.strftime('%a %d %b %Y') }}</p>
      </div>
      {% endfor %}
    </div>
  </details>
  {% endif %}

  <p class="mt-8 text-center text-xs text-ink-faint">Want to add events? Ask whoever shared this link for the invite link instead.</p>

</div>
{% endblock %}
SCHEDEOF
  echo "created: app/templates/calendarmaker/public.html"
fi

if [ -e "requirements.txt" ]; then
  echo "skip (exists): requirements.txt"
else
  cat > requirements.txt << 'SCHEDEOF'
Flask==3.1.3
Flask-SQLAlchemy==3.1.1
Flask-Migrate==4.1.0
Flask-Login==0.6.3
Flask-WTF==1.3.0
WTForms==3.2.2
email-validator==2.3.0
python-dotenv==1.2.2
Werkzeug==3.1.8
SQLAlchemy==2.0.51
alembic==1.19.1

# Discord bot (discord_bot/) — sends the same venv, run as its own process
discord.py==2.4.0

# Add for production PostgreSQL:
# psycopg2-binary==2.9.10
# Add for production WSGI server:
# gunicorn==23.0.0
SCHEDEOF
  echo "created: requirements.txt"
fi

if [ -e ".env.example" ]; then
  echo "skip (exists): .env.example"
else
  cat > .env.example << 'SCHEDEOF'
# Copy this file to .env and fill in real values. Never commit .env.

FLASK_ENV=development
SECRET_KEY=change-me-to-a-long-random-string

# SQLite is used automatically in development if DATABASE_URL is unset.
# For production, point this at PostgreSQL:
# DATABASE_URL=postgresql+psycopg2://scheduler:password@localhost:5432/scheduler
DATABASE_URL=

DEFAULT_TIMEZONE=Europe/London

# Email (wired up in Phase 4)
MAIL_PROVIDER=smtp
MAIL_FROM=no-reply@example.com
MAIL_FROM_NAME=Scheduler
MAIL_SERVER=localhost
MAIL_PORT=587
MAIL_USE_TLS=true
MAIL_USERNAME=
MAIL_PASSWORD=
# When unset/false, real SMTP is used. Leave unset in dev to log emails
# instead of sending them (see DevelopmentConfig in config.py).
MAIL_SUPPRESS_SEND=

# Discord bot (discord_bot/) — see discord_bot/README.md to create the
# bot application and invite it. Required for the bot to run at all.
DISCORD_BOT_TOKEN=
# How often (seconds) the bot checks for new bookings / due reminders.
DISCORD_POLL_INTERVAL_SECONDS=60
DISCORD_PING_INTERVAL_SECONDS=30
DISCORD_PING_CHECK_SECONDS=5
# Optional. If set, DMs include a "View in dashboard" link, e.g.
# https://scheduler.opslabsystems.cloud
DISCORD_APP_BASE_URL=
SCHEDEOF
  echo "created: .env.example"
fi

if [ -e "migrations/versions/7a1c9f2b3d4e_add_discord_notifications.py" ]; then
  echo "skip (exists): migrations/versions/7a1c9f2b3d4e_add_discord_notifications.py"
else
  cat > migrations/versions/7a1c9f2b3d4e_add_discord_notifications.py << 'SCHEDEOF'
"""Add Discord bot notification fields

Revision ID: 7a1c9f2b3d4e
Revises: 32925cbc8dca
Create Date: 2026-08-14 00:00:00.000000

"""
from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision = '7a1c9f2b3d4e'
down_revision = '32925cbc8dca'
branch_labels = None
depends_on = None


def upgrade():
    with op.batch_alter_table('settings', schema=None) as batch_op:
        batch_op.add_column(sa.Column('discord_user_id', sa.String(length=32), nullable=True))
        batch_op.add_column(sa.Column('notify_discord_new_booking', sa.Boolean(), nullable=False, server_default=sa.true()))
        batch_op.add_column(sa.Column('notify_discord_cancellation', sa.Boolean(), nullable=False, server_default=sa.true()))
        batch_op.add_column(sa.Column('notify_discord_reminders', sa.Boolean(), nullable=False, server_default=sa.true()))
        batch_op.add_column(sa.Column('discord_test_requested_at', sa.DateTime(), nullable=True))
        batch_op.add_column(sa.Column('discord_spam_ping_enabled', sa.Boolean(), nullable=False, server_default=sa.true()))

    with op.batch_alter_table('bookings', schema=None) as batch_op:
        batch_op.add_column(sa.Column('discord_new_notified', sa.Boolean(), nullable=False, server_default=sa.false()))
        batch_op.add_column(sa.Column('discord_cancel_notified', sa.Boolean(), nullable=False, server_default=sa.false()))
        batch_op.add_column(sa.Column('discord_day_reminder_sent', sa.Boolean(), nullable=False, server_default=sa.false()))
        batch_op.add_column(sa.Column('discord_hour_reminder_sent', sa.Boolean(), nullable=False, server_default=sa.false()))
        batch_op.add_column(sa.Column('discord_15min_reminder_sent', sa.Boolean(), nullable=False, server_default=sa.false()))
        batch_op.add_column(sa.Column('discord_ping_active', sa.Boolean(), nullable=False, server_default=sa.false()))
        batch_op.add_column(sa.Column('discord_ping_count', sa.Integer(), nullable=False, server_default='0'))
        batch_op.add_column(sa.Column('discord_ping_last_sent_at', sa.DateTime(), nullable=True))
        batch_op.add_column(sa.Column('discord_ping_last_message_id', sa.String(length=32), nullable=True))


def downgrade():
    with op.batch_alter_table('bookings', schema=None) as batch_op:
        batch_op.drop_column('discord_ping_last_message_id')
        batch_op.drop_column('discord_ping_last_sent_at')
        batch_op.drop_column('discord_ping_count')
        batch_op.drop_column('discord_ping_active')
        batch_op.drop_column('discord_15min_reminder_sent')
        batch_op.drop_column('discord_hour_reminder_sent')
        batch_op.drop_column('discord_day_reminder_sent')
        batch_op.drop_column('discord_cancel_notified')
        batch_op.drop_column('discord_new_notified')

    with op.batch_alter_table('settings', schema=None) as batch_op:
        batch_op.drop_column('discord_spam_ping_enabled')
        batch_op.drop_column('discord_test_requested_at')
        batch_op.drop_column('notify_discord_reminders')
        batch_op.drop_column('notify_discord_cancellation')
        batch_op.drop_column('notify_discord_new_booking')
        batch_op.drop_column('discord_user_id')
SCHEDEOF
  echo "created: migrations/versions/7a1c9f2b3d4e_add_discord_notifications.py"
fi

if [ -e "migrations/versions/e2f6a8c1b3d5_add_public_token_to_shared_calendars.py" ]; then
  echo "skip (exists): migrations/versions/e2f6a8c1b3d5_add_public_token_to_shared_calendars.py"
else
  cat > migrations/versions/e2f6a8c1b3d5_add_public_token_to_shared_calendars.py << 'SCHEDEOF'
"""Add public_token to shared_calendars

Revision ID: e2f6a8c1b3d5
Revises: 7a1c9f2b3d4e
Create Date: 2026-08-14 12:00:00.000000

"""
import secrets

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision = 'e2f6a8c1b3d5'
down_revision = '7a1c9f2b3d4e'
branch_labels = None
depends_on = None


def upgrade():
    # Add nullable first — existing rows have nothing to put here yet.
    with op.batch_alter_table('shared_calendars', schema=None) as batch_op:
        batch_op.add_column(sa.Column('public_token', sa.String(length=32), nullable=True))

    # Backfill every calendar that already exists with its own public
    # link, so nothing already-shared is left without one.
    conn = op.get_bind()
    shared_calendars = sa.table(
        'shared_calendars',
        sa.column('id', sa.Integer),
        sa.column('public_token', sa.String),
    )
    existing_ids = [row[0] for row in conn.execute(sa.select(shared_calendars.c.id))]
    for calendar_id in existing_ids:
        conn.execute(
            shared_calendars.update()
            .where(shared_calendars.c.id == calendar_id)
            .values(public_token=secrets.token_urlsafe(9))
        )

    # Now that every row has one, enforce not-null + uniqueness.
    with op.batch_alter_table('shared_calendars', schema=None) as batch_op:
        batch_op.alter_column('public_token', existing_type=sa.String(length=32), nullable=False)
        batch_op.create_unique_constraint('uq_shared_calendars_public_token', ['public_token'])


def downgrade():
    with op.batch_alter_table('shared_calendars', schema=None) as batch_op:
        batch_op.drop_constraint('uq_shared_calendars_public_token', type_='unique')
        batch_op.drop_column('public_token')
SCHEDEOF
  echo "created: migrations/versions/e2f6a8c1b3d5_add_public_token_to_shared_calendars.py"
fi

if [ -e "discord_bot/__init__.py" ]; then
  echo "skip (exists): discord_bot/__init__.py"
else
  cat > discord_bot/__init__.py << 'SCHEDEOF'

SCHEDEOF
  echo "created: discord_bot/__init__.py"
fi

if [ -e "discord_bot/embeds.py" ]; then
  echo "skip (exists): discord_bot/embeds.py"
else
  cat > discord_bot/embeds.py << 'SCHEDEOF'
"""Builds the discord.Embed objects sent by the notifier.

Kept separate from notifier.py so the "what it looks like" and "when it
gets sent" concerns don't tangle. Every embed follows the same shape —
title, a coloured left bar, a handful of inline fields, an optional notes
block, and a footer — so DMs read as one consistent, professional-looking
notification stream rather than a grab-bag of formats.
"""

import os
from datetime import datetime, timezone as dt_timezone

import discord

APP_NAME = "Scheduler"
BASE_URL = os.environ.get("DISCORD_APP_BASE_URL", "").rstrip("/")

COLOR_NEW = 0x22C55E       # green — something landed
COLOR_CANCELLED = 0xEF4444  # red — something was removed
COLOR_DAY = 0x3B82F6        # blue — informational, plenty of notice
COLOR_HOUR = 0xF59E0B       # amber — getting closer
COLOR_15MIN = 0xF97316       # orange — act now
COLOR_TEST = 0x8B5CF6        # purple — distinct from every real alert
COLOR_PING_NEW = 0xDC2626      # red — the repeated nag for a new booking
COLOR_PING_OOH = 0xB91C1C      # deeper red — out-of-hours nag, needs a decision


def _service_name(booking):
    return booking.booking_type.name if booking.booking_type else "Meeting"


def _duration_minutes(booking):
    delta = booking.end_datetime - booking.start_datetime
    return int(delta.total_seconds() // 60)


def _date_field(booking):
    return booking.start_datetime.strftime("%A %d %B %Y")


def _time_field(booking):
    return f"{booking.start_datetime.strftime('%H:%M')} \u2013 {booking.end_datetime.strftime('%H:%M')}"


def _manage_url(booking):
    if not BASE_URL:
        return None
    return f"{BASE_URL}/admin/bookings/{booking.id}"


def _base_embed(title, color, description=None):
    embed = discord.Embed(title=title, color=color, description=description, timestamp=datetime.now(dt_timezone.utc))
    embed.set_footer(text=APP_NAME)
    return embed


def _add_booking_fields(embed, booking, include_contact=True):
    embed.add_field(name="Service", value=f"{_service_name(booking)} ({_duration_minutes(booking)} min)", inline=True)
    embed.add_field(name="Date", value=_date_field(booking), inline=True)
    embed.add_field(name="Time", value=_time_field(booking), inline=True)
    if include_contact:
        contact = booking.email if not booking.phone else f"{booking.email}\n{booking.phone}"
        embed.add_field(name="Booked by", value=f"{booking.name}\n{contact}", inline=False)
    if booking.notes:
        note = booking.notes if len(booking.notes) <= 500 else booking.notes[:497] + "..."
        embed.add_field(name="Notes", value=note, inline=False)
    url = _manage_url(booking)
    if url:
        embed.add_field(name="\u200b", value=f"[View in dashboard]({url})", inline=False)
    return embed


def build_new_booking_embed(booking):
    embed = _base_embed("\U0001F4C5 New booking", COLOR_NEW, f"**{booking.name}** just booked time with you.")
    return _add_booking_fields(embed, booking)


def build_cancelled_embed(booking):
    embed = _base_embed("\u274C Booking cancelled", COLOR_CANCELLED, f"**{booking.name}** cancelled their booking.")
    return _add_booking_fields(embed, booking)


def build_day_start_embed(bookings):
    """One embed listing every booking for today, sent once when the day starts."""
    embed = _base_embed(
        f"\u2600\uFE0F Today's schedule \u2014 {len(bookings)} booking{'s' if len(bookings) != 1 else ''}",
        COLOR_DAY,
    )
    for booking in bookings:
        contact = booking.email if not booking.phone else f"{booking.email} \u00b7 {booking.phone}"
        embed.add_field(
            name=f"{booking.start_datetime.strftime('%H:%M')} \u2013 {_service_name(booking)}",
            value=f"{booking.name} ({contact})",
            inline=False,
        )
    return embed


def build_hour_reminder_embed(booking):
    embed = _base_embed("\u23F0 Starting in 1 hour", COLOR_HOUR, f"Your booking with **{booking.name}** starts in an hour.")
    return _add_booking_fields(embed, booking)


def build_15min_reminder_embed(booking):
    embed = _base_embed("\U0001F6A8 Starting in 15 minutes", COLOR_15MIN, f"Your booking with **{booking.name}** starts in 15 minutes.")
    return _add_booking_fields(embed, booking)


def build_ping_embed(booking, ping_number):
    """The repeated nag DM. Distinct red styling + a growing ping count so
    it's obviously different from the one-off new-booking embed, and the
    admin can see at a glance how long it's been going unacknowledged."""
    if booking.is_out_of_hours:
        title = "\u26A0\uFE0F OUT-OF-HOURS BOOKING \u2014 needs a look"
        color = COLOR_PING_OOH
        description = f"**{booking.name}** booked outside your working hours. Still unacknowledged."
    else:
        title = "\U0001F514 NEW BOOKING \u2014 needs a look"
        color = COLOR_PING_NEW
        description = f"**{booking.name}** booked with you. Still unacknowledged."

    embed = _base_embed(title, color, description)
    embed = _add_booking_fields(embed, booking)
    embed.add_field(name="\u200b", value=f"Ping #{ping_number} \u2014 press Stop below to silence this.", inline=False)
    return embed


def build_test_embed():
    embed = _base_embed(
        "\u2705 Test notification",
        COLOR_TEST,
        "If you can see this, your Discord ID is set up correctly and the bot can reach you.",
    )
    embed.add_field(
        name="What you'll get",
        value=(
            "\u2022 New booking alerts\n"
            "\u2022 Cancellation alerts\n"
            "\u2022 A daily schedule at the start of the day\n"
            "\u2022 A reminder 1 hour before each booking\n"
            "\u2022 A reminder 15 minutes before each booking\n"
            "\u2022 Repeated pings for new/out-of-hours bookings until you hit Stop"
        ),
        inline=False,
    )
    return embed
SCHEDEOF
  echo "created: discord_bot/embeds.py"
fi

if [ -e "discord_bot/notifier.py" ]; then
  echo "skip (exists): discord_bot/notifier.py"
else
  cat > discord_bot/notifier.py << 'SCHEDEOF'
"""Polls the Scheduler database and sends Discord DMs.

Runs inside the bot's own asyncio loop as a periodic task (see bot.py).
Polling — rather than the Flask app pushing events to the bot directly —
keeps the two processes fully decoupled: gunicorn workers never need to
know the bot exists, and the bot can be restarted, redeployed, or down
for a while without losing anything. Every DM type has a boolean
sent-flag on the row it's about, so a restart or a slow poll cycle never
produces a duplicate.

Every send is wrapped in try/except, same rule as app/services/email.py —
a Discord hiccup (rate limit, the admin left the shared server, whatever)
must never crash the poll loop or block the next booking's reminder.
"""

import logging
import os
from datetime import datetime, timedelta, timezone as dt_timezone

import discord

from app import db
from app.models.booking import ACTIVE_BOOKING_STATUSES, Booking
from app.models.settings import Settings
from app.services.status import local_now

from discord_bot.embeds import (
    build_15min_reminder_embed,
    build_cancelled_embed,
    build_day_start_embed,
    build_hour_reminder_embed,
    build_new_booking_embed,
    build_ping_embed,
    build_test_embed,
)
from discord_bot.views import StopPingView

logger = logging.getLogger("discord_bot.notifier")

HOUR_WINDOW = timedelta(hours=1)
FIFTEEN_MIN_WINDOW = timedelta(minutes=15)
PING_INTERVAL = timedelta(seconds=int(os.environ.get("DISCORD_PING_INTERVAL_SECONDS", "30")))


async def _dm(client, discord_user_id, embed, what, view=None):
    """Fetch the user and send them the embed. Logs and swallows failures —
    a bad ID, a revoked share-a-server, or a Discord outage should never
    take down the poll loop. Returns the sent Message, or None on failure."""
    try:
        user_id = int(discord_user_id)
    except (TypeError, ValueError):
        logger.warning("Skipping %s: discord_user_id %r isn't a valid ID", what, discord_user_id)
        return None
    try:
        discord_user = client.get_user(user_id) or await client.fetch_user(user_id)
        kwargs = {"embed": embed}
        if view is not None:
            kwargs["view"] = view
        message = await discord_user.send(**kwargs)
        logger.info("Sent %s to Discord user %s", what, user_id)
        return message
    except discord.Forbidden:
        logger.warning(
            "Couldn't DM %s for %s — they must share a server with the bot, or have DM'd it before.",
            user_id, what,
        )
    except discord.NotFound:
        logger.warning("Discord user ID %s not found (for %s) — check it's correct.", user_id, what)
    except Exception:  # noqa: BLE001 - a Discord failure must never break the poll loop
        logger.exception("Failed to send %s to Discord user %s", what, user_id)
    return None


async def _handle_test_requests(client):
    for settings_row in Settings.query.filter(Settings.discord_test_requested_at.isnot(None)).all():
        if settings_row.discord_user_id:
            await _dm(client, settings_row.discord_user_id, build_test_embed(), "test DM")
        settings_row.discord_test_requested_at = None
    db.session.commit()


async def _handle_new_bookings(client):
    bookings = Booking.query.filter(
        Booking.discord_new_notified.is_(False),
        Booking.status.in_(ACTIVE_BOOKING_STATUSES),
    ).all()
    for booking in bookings:
        settings_row = Settings.for_user(booking.user)
        if settings_row.discord_user_id and settings_row.notify_discord_new_booking:
            await _dm(client, settings_row.discord_user_id, build_new_booking_embed(booking), f"new-booking DM (#{booking.id})")
            if settings_row.discord_spam_ping_enabled:
                booking.discord_ping_active = True
                booking.discord_ping_count = 0
                booking.discord_ping_last_sent_at = None
                booking.discord_ping_last_message_id = None
        booking.discord_new_notified = True
    if bookings:
        db.session.commit()


async def _delete_dm_message(client, discord_user_id, message_id):
    if not message_id:
        return
    try:
        user_id = int(discord_user_id)
        discord_user = client.get_user(user_id) or await client.fetch_user(user_id)
        channel = discord_user.dm_channel or await discord_user.create_dm()
        message = await channel.fetch_message(int(message_id))
        await message.delete()
    except discord.NotFound:
        pass  # already gone — fine
    except Exception:  # noqa: BLE001 - cleanup failures shouldn't break anything else
        logger.exception("Failed to delete old ping message %s", message_id)


async def _handle_cancellations(client):
    bookings = Booking.query.filter(
        Booking.discord_cancel_notified.is_(False),
        Booking.status == "cancelled",
        Booking.cancelled_at.isnot(None),
    ).all()
    for booking in bookings:
        settings_row = Settings.for_user(booking.user)
        if settings_row.discord_user_id and settings_row.notify_discord_cancellation:
            await _dm(client, settings_row.discord_user_id, build_cancelled_embed(booking), f"cancellation DM (#{booking.id})")
        booking.discord_cancel_notified = True
        if booking.discord_ping_active:
            if settings_row.discord_user_id:
                await _delete_dm_message(client, settings_row.discord_user_id, booking.discord_ping_last_message_id)
            booking.discord_ping_active = False
            booking.discord_ping_last_message_id = None
    if bookings:
        db.session.commit()


async def _handle_day_start(client, users):
    for user in users:
        settings_row = Settings.for_user(user)
        if not (settings_row.discord_user_id and settings_row.notify_discord_reminders):
            continue
        now = local_now(user)
        todays = Booking.query.filter(
            Booking.user_id == user.id,
            Booking.status.in_(ACTIVE_BOOKING_STATUSES),
            Booking.discord_day_reminder_sent.is_(False),
            Booking.start_datetime >= datetime.combine(now.date(), datetime.min.time()),
            Booking.start_datetime < datetime.combine(now.date(), datetime.max.time()),
            Booking.start_datetime > now,
        ).order_by(Booking.start_datetime.asc()).all()
        if todays:
            await _dm(client, settings_row.discord_user_id, build_day_start_embed(todays), "day-start digest")
            for booking in todays:
                booking.discord_day_reminder_sent = True
            db.session.commit()


async def _handle_timed_reminders(client, users):
    for user in users:
        settings_row = Settings.for_user(user)
        if not (settings_row.discord_user_id and settings_row.notify_discord_reminders):
            continue
        now = local_now(user)

        hour_due = Booking.query.filter(
            Booking.user_id == user.id,
            Booking.status.in_(ACTIVE_BOOKING_STATUSES),
            Booking.discord_hour_reminder_sent.is_(False),
            Booking.start_datetime > now,
            Booking.start_datetime <= now + HOUR_WINDOW,
        ).all()
        for booking in hour_due:
            await _dm(client, settings_row.discord_user_id, build_hour_reminder_embed(booking), f"1-hour reminder (#{booking.id})")
            booking.discord_hour_reminder_sent = True

        fifteen_due = Booking.query.filter(
            Booking.user_id == user.id,
            Booking.status.in_(ACTIVE_BOOKING_STATUSES),
            Booking.discord_15min_reminder_sent.is_(False),
            Booking.start_datetime > now,
            Booking.start_datetime <= now + FIFTEEN_MIN_WINDOW,
        ).all()
        for booking in fifteen_due:
            await _dm(client, settings_row.discord_user_id, build_15min_reminder_embed(booking), f"15-minute reminder (#{booking.id})")
            booking.discord_15min_reminder_sent = True

        if hour_due or fifteen_due:
            db.session.commit()


async def run_ping_tick(app, client):
    """Fires the repeated 'spam ping' DMs. Called on its own fast timer
    (bot.py) — separate from the main poll() loop, since pings need a much
    shorter cadence than everything else.

    Ping 1 is sent immediately (from _handle_new_bookings). From ping 2
    onward, the previous ping message is deleted right before the new one
    goes out, so only ever one ping is visible at a time — right up until
    Stop is pressed, which is unbounded: nothing here ever turns
    discord_ping_active off on its own except a cancellation or the
    booking's start time passing.
    """
    with app.app_context():
        try:
            now_utc = datetime.now(dt_timezone.utc).replace(tzinfo=None)
            active = Booking.query.filter(Booking.discord_ping_active.is_(True)).all()
            for booking in active:
                settings_row = Settings.for_user(booking.user)
                if not settings_row.discord_user_id or not settings_row.discord_spam_ping_enabled:
                    booking.discord_ping_active = False
                    continue

                # Nothing left to nag about once it's started/cancelled/etc.
                if booking.status not in ACTIVE_BOOKING_STATUSES or booking.start_datetime <= local_now(booking.user):
                    booking.discord_ping_active = False
                    if booking.discord_ping_last_message_id:
                        await _delete_dm_message(client, settings_row.discord_user_id, booking.discord_ping_last_message_id)
                        booking.discord_ping_last_message_id = None
                    continue

                due_at = (booking.discord_ping_last_sent_at or datetime.min) + PING_INTERVAL
                if now_utc < due_at:
                    continue

                next_ping_number = booking.discord_ping_count + 1
                view = StopPingView(booking.id)
                message = await _dm(
                    client, settings_row.discord_user_id, build_ping_embed(booking, next_ping_number),
                    f"ping #{next_ping_number} (#{booking.id})", view=view,
                )
                if message is None:
                    # Couldn't send (Forbidden/etc) — stop trying rather than loop forever.
                    booking.discord_ping_active = False
                    continue

                client.add_view(view, message_id=message.id)

                # From ping 2 onward, delete the one before it.
                if next_ping_number >= 2 and booking.discord_ping_last_message_id:
                    await _delete_dm_message(client, settings_row.discord_user_id, booking.discord_ping_last_message_id)

                booking.discord_ping_count = next_ping_number
                booking.discord_ping_last_sent_at = now_utc
                booking.discord_ping_last_message_id = str(message.id)

            db.session.commit()
        except Exception:  # noqa: BLE001 - one bad tick must not kill the loop
            db.session.rollback()
            logger.exception("Discord bot ping tick failed")


async def resume_active_ping_views(app, client):
    """Called once from on_ready — re-registers a StopPingView for every
    session still marked active, so Stop keeps working after a restart
    even though the in-memory view objects from before are gone."""
    with app.app_context():
        active = Booking.query.filter(Booking.discord_ping_active.is_(True)).all()
        for booking in active:
            client.add_view(StopPingView(booking.id))
        if active:
            logger.info("Re-registered %d active ping session(s) after restart.", len(active))


async def poll(app, client):
    """One full poll cycle. Called on a timer from bot.py."""
    from app.models.user import User

    with app.app_context():
        try:
            users = User.query.all()
            await _handle_test_requests(client)
            await _handle_new_bookings(client)
            await _handle_cancellations(client)
            await _handle_day_start(client, users)
            await _handle_timed_reminders(client, users)
        except Exception:  # noqa: BLE001 - one bad poll must not kill the loop
            db.session.rollback()
            logger.exception("Discord bot poll cycle failed")
SCHEDEOF
  echo "created: discord_bot/notifier.py"
fi

if [ -e "discord_bot/bot.py" ]; then
  echo "skip (exists): discord_bot/bot.py"
else
  cat > discord_bot/bot.py << 'SCHEDEOF'
"""Entrypoint for the Scheduler Discord notification bot.

Run it as its own long-running process, separate from gunicorn:

    python -m discord_bot.bot

(from the project root, with the venv active and DISCORD_BOT_TOKEN set —
see discord_bot/README.md for the systemd unit.)

It logs in, then polls the database every POLL_INTERVAL_SECONDS (default
60) for anything that needs a DM: new bookings, cancellations, the
day-start digest, and the 1-hour / 15-minute reminders. See notifier.py
for the actual logic.
"""

import logging
import os
import sys

# So `python discord_bot/bot.py` works too, not just `python -m discord_bot.bot`.
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import discord
from discord.ext import tasks
from dotenv import load_dotenv

load_dotenv()

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger("discord_bot")

TOKEN = os.environ.get("DISCORD_BOT_TOKEN")
POLL_INTERVAL_SECONDS = int(os.environ.get("DISCORD_POLL_INTERVAL_SECONDS", "60"))
FLASK_ENV = os.environ.get("FLASK_ENV", "production")

if not TOKEN:
    logger.error("DISCORD_BOT_TOKEN is not set (check your .env). Exiting.")
    sys.exit(1)

from app import create_app  # noqa: E402 - needs sys.path fixed up first
from discord_bot import views  # noqa: E402
from discord_bot.notifier import poll, resume_active_ping_views, run_ping_tick  # noqa: E402

app = create_app(FLASK_ENV)
views.flask_app = app

intents = discord.Intents.default()
client = discord.Client(intents=intents)

PING_CHECK_SECONDS = int(os.environ.get("DISCORD_PING_CHECK_SECONDS", "5"))


@tasks.loop(seconds=POLL_INTERVAL_SECONDS)
async def poll_loop():
    await poll(app, client)


@tasks.loop(seconds=PING_CHECK_SECONDS)
async def ping_loop():
    await run_ping_tick(app, client)


@poll_loop.before_loop
async def before_poll_loop():
    await client.wait_until_ready()


@ping_loop.before_loop
async def before_ping_loop():
    await client.wait_until_ready()


@client.event
async def on_ready():
    logger.info("Logged in as %s (id=%s). Polling every %ss, pings checked every %ss.",
                client.user, client.user.id, POLL_INTERVAL_SECONDS, PING_CHECK_SECONDS)
    await resume_active_ping_views(app, client)
    if not poll_loop.is_running():
        poll_loop.start()
    if not ping_loop.is_running():
        ping_loop.start()


def main():
    client.run(TOKEN, log_handler=None)


if __name__ == "__main__":
    main()
SCHEDEOF
  echo "created: discord_bot/bot.py"
fi

if [ -e "discord_bot/views.py" ]; then
  echo "skip (exists): discord_bot/views.py"
else
  cat > discord_bot/views.py << 'SCHEDEOF'
"""The Stop button attached to every spam-ping DM.

One view instance per booking, with the booking id baked into the
button's custom_id (``stop_ping:<id>``) so it keeps working across bot
restarts — on_ready re-registers a fresh view for every still-active
session (see bot.py), and Discord routes the click by matching that
custom_id string, not by object identity.
"""

import logging
from datetime import datetime, timezone as dt_timezone

import discord

logger = logging.getLogger("discord_bot.views")

# Set by bot.py after create_app() — the view's callback needs an app
# context to touch the database, same as notifier.py.
flask_app = None


class StopPingView(discord.ui.View):
    def __init__(self, booking_id):
        super().__init__(timeout=None)
        self.booking_id = booking_id
        # Decorated children are rebuilt per-instance on __init__, so it's
        # safe to give this instance's button its own custom_id here.
        self.stop_button.custom_id = f"stop_ping:{booking_id}"

    @discord.ui.button(label="Stop pings", style=discord.ButtonStyle.danger, emoji="\U0001F6D1")
    async def stop_button(self, interaction: discord.Interaction, button: discord.ui.Button):
        from app import db
        from app.models.booking import Booking

        with flask_app.app_context():
            booking = db.session.get(Booking, self.booking_id)
            if booking is not None:
                booking.discord_ping_active = False
                booking.discord_ping_last_message_id = None
                db.session.commit()

        button.disabled = True
        button.label = "Stopped"
        embed = interaction.message.embeds[0] if interaction.message.embeds else None
        if embed is not None:
            embed.color = 0x6B7280  # neutral grey — no longer urgent
            embed.set_footer(text=f"Pings stopped \u00b7 {embed.footer.text or 'Scheduler'}")
        try:
            await interaction.response.edit_message(embed=embed, view=self)
        except discord.HTTPException:
            logger.exception("Failed to edit ping message after stop for booking %s", self.booking_id)
        self.stop()
SCHEDEOF
  echo "created: discord_bot/views.py"
fi

if [ -e "discord_bot/README.md" ]; then
  echo "skip (exists): discord_bot/README.md"
else
  cat > discord_bot/README.md << 'SCHEDEOF'
# Scheduler Discord bot

Separate long-running process that DMs the admin about bookings. Talks to
the same database as the Flask app, but runs independently — it does not
need gunicorn, nginx, or the web app to be up (though obviously bookings
only happen if the web app is up).

Sends DMs for:
- **New booking** — as soon as the poll loop notices one
- **Cancellation**
- **Day-start digest** — one DM listing everything booked for today, sent
  once the date rolls over (or on the next poll if the bot was down at
  midnight)
- **1 hour before** each booking
- **15 minutes before** each booking
- **Spam ping** — for new bookings and out-of-hours bookings, keeps DMing
  every `DISCORD_PING_INTERVAL_SECONDS` (default 30) with a **Stop pings**
  button on the message. From the 2nd ping onward the previous ping is
  deleted right before the next one is sent, so only the latest is ever
  visible. It keeps going — no cap — until Stop is pressed, the booking
  is cancelled, or its start time arrives. Toggle it off entirely in
  Admin → Settings → Discord notifications.

All times are the admin's own timezone (Settings → Profile → Timezone).

## 1. Create the bot in Discord

1. https://discord.com/developers/applications → **New Application**
2. **Bot** tab → **Reset Token**, copy it → this is `DISCORD_BOT_TOKEN`
3. No privileged intents needed — it only sends DMs, never reads messages
4. **OAuth2 → URL Generator** → scope `bot`, no permissions needed → open
   the generated URL and add it to any server you're also in (Discord
   only lets a bot DM someone it shares a server with, or who has DM'd it
   first)

## 2. Get your Discord user ID

Discord app → Settings → Advanced → enable **Developer Mode**. Then
right-click your own name anywhere → **Copy User ID**. Paste that into
Admin → Settings → Discord notifications.

## 3. Configure

Add to `.env` (same file the Flask app uses):

```
DISCORD_BOT_TOKEN=<paste from step 1>
DISCORD_POLL_INTERVAL_SECONDS=60
DISCORD_APP_BASE_URL=https://scheduler.opslabsystems.cloud   # optional
DISCORD_PING_INTERVAL_SECONDS=30   # gap between spam pings
DISCORD_PING_CHECK_SECONDS=5       # how often the bot checks if a ping is due
```

## 4. Migrate and bootstrap

```
source venv/bin/activate
flask db upgrade
flask discord-bootstrap   # run once — stops the bot flooding you with
                           # "new booking" DMs for bookings that already existed
```

## 5. Run it

**Manually (to test):**

```
source venv/bin/activate
python -m discord_bot.bot
```

Then in Admin → Settings → Discord notifications, save your Discord user
ID and click **Send test DM**.

**As a systemd service** — copy `scheduler-discord-bot.service` below to
`/etc/systemd/system/`, adjusting `WorkingDirectory` and the venv path if
your deploy path isn't `/opt/scheduler`:

```ini
[Unit]
Description=Scheduler Discord notification bot
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/scheduler
EnvironmentFile=/opt/scheduler/.env
ExecStart=/opt/scheduler/venv/bin/python -m discord_bot.bot
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

```
systemctl daemon-reload
systemctl enable --now scheduler-discord-bot
journalctl -u scheduler-discord-bot -f
```

## Redeploying

This is a live process, not something nginx serves — replacing the
files on disk does nothing until it's restarted:

```
systemctl restart scheduler-discord-bot
```

## Notes

- If `discord_user_id` is blank or "Send test DM" gives no result, check
  `journalctl -u scheduler-discord-bot` — a `discord.Forbidden` there
  means Discord is refusing the DM (not sharing a server / never DM'd
  the bot), not a bug.
- The bot and the gunicorn app share the same SQLite/Postgres database
  and the same `app/` models — no separate schema, no API between them.
- Every send-once action (new booking, cancellation, each reminder) is
  tracked by a boolean column on `Booking`, so a bot restart or a slow
  poll cycle never double-sends.
SCHEDEOF
  echo "created: discord_bot/README.md"
fi

if [ -e "discord_bot/scheduler-discord-bot.service" ]; then
  echo "skip (exists): discord_bot/scheduler-discord-bot.service"
else
  cat > discord_bot/scheduler-discord-bot.service << 'SCHEDEOF'
[Unit]
Description=Scheduler Discord notification bot
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/scheduler
EnvironmentFile=/opt/scheduler/.env
ExecStart=/opt/scheduler/venv/bin/python -m discord_bot.bot
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SCHEDEOF
  echo "created: discord_bot/scheduler-discord-bot.service"
fi

echo "Done. Now run: pip install -r requirements.txt --break-system-packages (or your venv equivalent), flask db upgrade, flask discord-bootstrap"
