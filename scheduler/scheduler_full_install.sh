#!/usr/bin/env bash
# Full install: multi-recipient Discord pings + booking action buttons
# (reschedule / running late / complete / no-show).
# Overwrites the files this update touches, then installs + migrates + restarts.
# Run from your scheduler project root (e.g. ~/scheduler), venv active.
set -e

mkdir -p app app/models app/routes app/services app/templates/admin discord_bot migrations/versions

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
SCHEDEOF
echo "wrote: app/models/settings.py"

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
SCHEDEOF
echo "wrote: app/models/booking.py"

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


class DiscordRecipientForm(FlaskForm):
    discord_user_id = StringField(
        "Discord user ID",
        validators=[DataRequired(message="Enter a Discord user ID."), Length(max=32)],
    )
    label = StringField("Label (optional)", validators=[Optional(), Length(max=80)])

    def validate_discord_user_id(self, field):
        if not field.data.strip().isdigit():
            raise ValidationError("That doesn't look like a Discord user ID — it should be all digits.")


class RescheduleBookingForm(FlaskForm):
    event_date = DateField("New date", validators=[DataRequired(message="Enter a date.")])
    start_time = TimeField("New start time", validators=[DataRequired(message="Enter a start time.")])
    end_time = TimeField("New end time", validators=[DataRequired(message="Enter an end time.")])

    def validate_end_time(self, field):
        if self.start_time.data and field.data and field.data <= self.start_time.data:
            raise ValidationError("End time must be after the start time.")


class RunningLateForm(FlaskForm):
    minutes_late = IntegerField(
        "Minutes late (optional)",
        validators=[Optional(), NumberRange(min=1, max=480, message="1–480 minutes.")],
    )


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
echo "wrote: app/forms.py"

cat > app/routes/admin.py << 'SCHEDEOF'
from datetime import datetime, time as dt_time, timedelta, timezone as dt_timezone

from flask import Blueprint, abort, flash, redirect, render_template, request, url_for
from flask_login import current_user, login_required

from app import db
from app.forms import BookingOutOfHoursForm, BookingTypeForm, BreakForm, CSRFOnlyForm, CurrentTaskForm, DiscordRecipientForm, DiscordSettingsForm, DiscordTestForm, ISPFeeForm, NotificationSettingsForm, ProfileForm, RescheduleBookingForm, RunningLateForm, StatusOverrideForm, TimeOffForm
from app.models.availability import DAY_NAMES, Break, WorkingHours
from app.models.booking import ACTIVE_BOOKING_STATUSES, Booking, BookingType
from app.models.settings import MANUAL_STATUSES, DiscordRecipient, Settings
from app.models.time_off import TimeOff
from app.services.availability import ensure_working_hours_rows
from app.services.calendar import build_month_grid
from app.services.notifications import notify_cancelled_booking, notify_rescheduled_booking, notify_running_late
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


@admin_bp.route("/bookings/<int:booking_id>/complete", methods=["POST"])
@login_required
def complete_booking(booking_id):
    csrf_form = CSRFOnlyForm()
    if not csrf_form.validate_on_submit():
        abort(400)
    booking = Booking.query.filter_by(id=booking_id, user_id=current_user.id).first_or_404()
    booking.status = "completed"
    db.session.commit()
    flash(f"Booking with {booking.name} marked completed.", "success")
    return redirect(request.referrer or url_for("admin.bookings"))


@admin_bp.route("/bookings/<int:booking_id>/no-show", methods=["POST"])
@login_required
def mark_no_show(booking_id):
    csrf_form = CSRFOnlyForm()
    if not csrf_form.validate_on_submit():
        abort(400)
    booking = Booking.query.filter_by(id=booking_id, user_id=current_user.id).first_or_404()
    booking.status = "no_show"
    db.session.commit()
    flash(f"{booking.name} marked as a no-show.", "success")
    return redirect(request.referrer or url_for("admin.bookings"))


@admin_bp.route("/bookings/<int:booking_id>/running-late", methods=["POST"])
@login_required
def booking_running_late(booking_id):
    form = RunningLateForm()
    booking = Booking.query.filter_by(id=booking_id, user_id=current_user.id).first_or_404()
    if form.validate_on_submit():
        notify_running_late(booking, minutes_late=form.minutes_late.data)
        flash(f"{booking.name} has been notified you're running late.", "success")
    else:
        for field_errors in form.errors.values():
            for err in field_errors:
                flash(err, "error")
    return redirect(request.referrer or url_for("admin.bookings"))


@admin_bp.route("/bookings/<int:booking_id>/reschedule", methods=["GET", "POST"])
@login_required
def reschedule_booking(booking_id):
    booking = Booking.query.filter_by(id=booking_id, user_id=current_user.id).first_or_404()
    form = RescheduleBookingForm(
        event_date=booking.start_datetime.date(),
        start_time=booking.start_datetime.time(),
        end_time=booking.end_datetime.time(),
    )

    if form.validate_on_submit():
        old_start_display = booking.start_datetime.strftime("%A %d %B %Y")
        old_time_display = f"{booking.start_datetime.strftime('%H:%M')} - {booking.end_datetime.strftime('%H:%M')}"

        booking.start_datetime = datetime.combine(form.event_date.data, form.start_time.data)
        booking.end_datetime = datetime.combine(form.event_date.data, form.end_time.data)

        # New time means the day-of / hour-before / 15-min-before Discord
        # reminders need to fire again relative to it, not be considered
        # "already sent" from the old schedule.
        booking.discord_day_reminder_sent = False
        booking.discord_hour_reminder_sent = False
        booking.discord_15min_reminder_sent = False

        db.session.commit()
        notify_rescheduled_booking(booking, old_start_display, old_time_display)
        flash(f"Booking with {booking.name} moved to {form.event_date.data.strftime('%a %d %b')} at {form.start_time.data.strftime('%H:%M')}.", "success")
        return redirect(request.referrer or url_for("admin.bookings"))

    return render_template(
        "admin/reschedule_booking.html", form=form, booking=booking, active_page="bookings"
    )


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
    discord_recipient_form = DiscordRecipientForm()
    discord_recipients = DiscordRecipient.query.filter_by(user_id=current_user.id).order_by(DiscordRecipient.created_at).all()
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
        discord_recipient_form=discord_recipient_form,
        discord_recipients=discord_recipients,
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


@admin_bp.route("/settings/discord/recipients", methods=["POST"])
@login_required
def add_discord_recipient():
    form = DiscordRecipientForm()
    if form.validate_on_submit():
        discord_user_id = form.discord_user_id.data.strip()
        existing = DiscordRecipient.query.filter_by(user_id=current_user.id, discord_user_id=discord_user_id).first()
        if existing:
            flash("That Discord user ID is already on the list.", "error")
        else:
            db.session.add(
                DiscordRecipient(
                    user_id=current_user.id,
                    discord_user_id=discord_user_id,
                    label=(form.label.data or "").strip() or None,
                )
            )
            db.session.commit()
            flash("Added — they'll get every Discord notification and ping the same as you.", "success")
    else:
        for field_errors in form.errors.values():
            for err in field_errors:
                flash(err, "error")
    return redirect(url_for("admin.settings"))


@admin_bp.route("/settings/discord/recipients/<int:recipient_id>/delete", methods=["POST"])
@login_required
def delete_discord_recipient(recipient_id):
    csrf_form = CSRFOnlyForm()
    if not csrf_form.validate_on_submit():
        abort(400)
    recipient = DiscordRecipient.query.filter_by(id=recipient_id, user_id=current_user.id).first_or_404()
    db.session.delete(recipient)
    db.session.commit()
    flash("Removed.", "success")
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
echo "wrote: app/routes/admin.py"

cat > app/services/notifications.py << 'SCHEDEOF'
"""Turns booking events into emails.

Every send goes through app.services.email.send_email, and every send is
wrapped in a try/except here — a broken mail server should never block a
booking from being created or cancelled in the app itself. Failures are
logged so they're visible without becoming user-facing errors.
"""

import logging

from flask import render_template, url_for

from app.models.settings import Settings
from app.services.email import send_email

logger = logging.getLogger(__name__)


def _booking_context(booking, extra=None):
    ctx = {
        "app_name": "Scheduler",
        "booking_type_name": booking.booking_type.name if booking.booking_type else "Meeting",
        "start_display": booking.start_datetime.strftime("%A %d %B %Y"),
        "time_display": f"{booking.start_datetime.strftime('%H:%M')} - {booking.end_datetime.strftime('%H:%M')}",
        "notes": booking.notes,
    }
    if extra:
        ctx.update(extra)
    return ctx


def _send(to_email, subject, **context):
    html_body = render_template("email/booking_notification.html", subject=subject, **context)
    text_lines = [
        context["heading"],
        "",
        context["intro"],
        "",
        context["booking_type_name"],
        context["start_display"],
        context["time_display"],
    ]
    if context.get("notes"):
        text_lines += ["", '"' + context["notes"] + '"']
    if context.get("cta_url"):
        text_lines += ["", context["cta_label"] + ": " + context["cta_url"]]
    text_body = "\n".join(text_lines)

    try:
        send_email(to_email, subject, html_body, text_body)
    except Exception:  # noqa: BLE001 - a mail failure must never break the booking flow
        logger.exception("Failed to send email '%s' to %s", subject, to_email)


def notify_new_booking(booking):
    """Sends the booker their confirmation, and the owner a heads-up, if enabled."""
    manage_url = url_for("public.manage_booking", token=booking.manage_token, _external=True)

    _send(
        booking.email,
        "Booking confirmed: " + (booking.booking_type.name if booking.booking_type else "Meeting"),
        **_booking_context(
            booking,
            {
                "heading": "You're booked in",
                "intro": "This confirms your booking with " + booking.user.name + ".",
                "cta_url": manage_url,
                "cta_label": "Manage this booking",
            },
        ),
    )

    settings = Settings.for_user(booking.user)
    if settings.notify_on_new_booking:
        _send(
            booking.user.email,
            "New booking: " + booking.name,
            **_booking_context(
                booking,
                {
                    "heading": "New booking",
                    "intro": booking.name + " (" + booking.email + ") just booked time with you.",
                },
            ),
        )


def notify_cancelled_booking(booking, cancelled_by):
    """cancelled_by is 'guest' or 'admin' — only the *other* party gets a heads-up."""
    settings = Settings.for_user(booking.user)

    if cancelled_by == "guest" and settings.notify_on_cancellation:
        _send(
            booking.user.email,
            "Cancelled: " + booking.name,
            **_booking_context(
                booking,
                {
                    "heading": "Booking cancelled",
                    "intro": booking.name + " (" + booking.email + ") cancelled their booking.",
                },
            ),
        )

    if cancelled_by == "admin":
        _send(
            booking.email,
            "Your booking has been cancelled",
            **_booking_context(
                booking,
                {
                    "heading": "Booking cancelled",
                    "intro": booking.user.name
                    + " cancelled this booking. Get in touch with them if you'd like to reschedule.",
                },
            ),
        )


def notify_rescheduled_booking(booking, old_start_display, old_time_display):
    """Tells the customer their booking moved to a new time. Only the
    customer needs this — the admin is the one who just made the change."""
    manage_url = url_for("public.manage_booking", token=booking.manage_token, _external=True)
    _send(
        booking.email,
        "Your booking has been rescheduled",
        **_booking_context(
            booking,
            {
                "heading": "Your booking moved",
                "intro": (
                    booking.user.name + " moved your booking from " + old_start_display
                    + " at " + old_time_display + " to the new time below."
                ),
                "cta_url": manage_url,
                "cta_label": "Manage this booking",
            },
        ),
    )


def notify_running_late(booking, minutes_late=None):
    """A one-off heads-up to the customer that the admin is running behind.
    Doesn't change the booking itself — purely informational."""
    if minutes_late:
        intro = f"{booking.user.name} is running about {minutes_late} minutes behind schedule for your booking."
    else:
        intro = f"{booking.user.name} is running a little behind schedule for your booking."
    _send(
        booking.email,
        "Running a little late",
        **_booking_context(
            booking,
            {
                "heading": "Running a bit late",
                "intro": intro,
            },
        ),
    )
SCHEDEOF
echo "wrote: app/services/notifications.py"

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

    <div class="mt-6 pt-6 border-t border-border">
      <p class="mb-1 text-sm font-medium text-ink">Also ping</p>
      <p class="mb-4 text-xs text-ink-muted">
        Anyone added here gets every Discord notification and every spam ping the same as you —
        each with their own Stop button, so one person stopping a ping doesn't stop it for anyone else.
      </p>

      {% if discord_recipients %}
      <div class="mb-4 space-y-2">
        {% for r in discord_recipients %}
        <div class="flex items-center justify-between gap-2 rounded-lg border border-border bg-surface-raised px-3 py-2">
          <div class="min-w-0">
            {% if r.label %}<p class="text-sm text-ink truncate">{{ r.label }}</p>{% endif %}
            <p class="text-xs text-ink-faint font-mono truncate">{{ r.discord_user_id }}</p>
          </div>
          <form method="POST" action="{{ url_for('admin.delete_discord_recipient', recipient_id=r.id) }}" class="shrink-0">
            <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
            <button type="submit" class="btn-ghost !px-2 text-xs" aria-label="Remove">Remove</button>
          </form>
        </div>
        {% endfor %}
      </div>
      {% endif %}

      <form method="POST" action="{{ url_for('admin.add_discord_recipient') }}" novalidate>
        {{ discord_recipient_form.hidden_tag() }}
        <div class="flex flex-col gap-2 sm:flex-row">
          {{ discord_recipient_form.discord_user_id(class_="field-input font-mono", placeholder="Discord user ID") }}
          {{ discord_recipient_form.label(class_="field-input", placeholder="Label (optional)") }}
          <button type="submit" class="btn-secondary shrink-0">Add</button>
        </div>
        {% for error in discord_recipient_form.discord_user_id.errors %}<p class="field-error">{{ error }}</p>{% endfor %}
      </form>
    </div>
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
echo "wrote: app/templates/admin/settings.html"

cat > app/templates/admin/bookings.html << 'SCHEDEOF'
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
               else 'border-status-busy/30 text-status-busy' if b.status in ('cancelled', 'no_show')
               else 'border-status-away/30 text-status-away' if b.status == 'completed'
               else 'border-border text-ink-faint' }}">
            {{ b.status.replace('_', ' ') }}
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
      {% if b.status not in ('cancelled', 'completed', 'no_show') %}
      <div class="flex flex-wrap gap-2 shrink-0">
        <a href="{{ url_for('admin.reschedule_booking', booking_id=b.id) }}" class="btn-secondary">Reschedule</a>
        <form method="POST" action="{{ url_for('admin.booking_running_late', booking_id=b.id) }}"
              onsubmit="document.getElementById('late-minutes-{{ b.id }}').value = prompt('Roughly how many minutes late? (leave blank to skip)') || ''; return true;">
          <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
          <input type="hidden" id="late-minutes-{{ b.id }}" name="minutes_late" value="">
          <button type="submit" class="btn-secondary">Running late</button>
        </form>
        <form method="POST" action="{{ url_for('admin.complete_booking', booking_id=b.id) }}">
          <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
          <button type="submit" class="btn-secondary">Mark completed</button>
        </form>
        <form method="POST" action="{{ url_for('admin.mark_no_show', booking_id=b.id) }}">
          <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
          <button type="submit" class="btn-secondary">No-show</button>
        </form>
        <form method="POST" action="{{ url_for('admin.cancel_booking', booking_id=b.id) }}"
              onsubmit="return confirm('Cancel this booking with {{ b.name }}?');">
          <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
          <button type="submit" class="btn-danger">Cancel</button>
        </form>
      </div>
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
SCHEDEOF
echo "wrote: app/templates/admin/bookings.html"

cat > app/templates/admin/reschedule_booking.html << 'SCHEDEOF'
{% extends "layouts/admin.html" %}
{% block title %}Reschedule · {{ app_name }}{% endblock %}
{% block page_content %}

<div class="mb-8">
  <h1 class="font-display text-2xl font-semibold text-ink">Reschedule booking</h1>
  <p class="mt-1 text-sm text-ink-muted">
    {{ booking.name }} · currently {{ booking.start_datetime.strftime('%a %d %b %Y, %H:%M') }}–{{ booking.end_datetime.strftime('%H:%M') }}
  </p>
</div>

<div class="max-w-md">
  <div class="card p-6 sm:p-7">
    <form method="POST" novalidate>
      {{ form.hidden_tag() }}

      <div class="mb-4">
        <label class="field-label" for="{{ form.event_date.id }}">New date</label>
        {{ form.event_date(class_="field-input") }}
        {% for error in form.event_date.errors %}<p class="field-error">{{ error }}</p>{% endfor %}
      </div>

      <div class="mb-4 grid grid-cols-2 gap-3">
        <div>
          <label class="field-label" for="{{ form.start_time.id }}">New start</label>
          {{ form.start_time(class_="field-input") }}
        </div>
        <div>
          <label class="field-label" for="{{ form.end_time.id }}">New end</label>
          {{ form.end_time(class_="field-input") }}
        </div>
      </div>
      {% for error in form.end_time.errors %}<p class="field-error -mt-2 mb-3">{{ error }}</p>{% endfor %}

      <p class="mb-5 text-xs text-ink-faint">{{ booking.name }} will be emailed to let them know it moved.</p>

      <div class="flex gap-3">
        <button type="submit" class="btn-primary">Save new time</button>
        <a href="{{ url_for('admin.bookings') }}" class="btn-secondary">Cancel</a>
      </div>
    </form>
  </div>
</div>

{% endblock %}
SCHEDEOF
echo "wrote: app/templates/admin/reschedule_booking.html"

cat > discord_bot/notifier.py << 'SCHEDEOF'
"""Polls the Scheduler database and sends Discord DMs.

Runs inside the bot's own asyncio loop as a periodic task (see bot.py).
Polling — rather than the Flask app pushing events to the bot directly —
keeps the two processes fully decoupled: gunicorn workers never need to
know the bot exists, and the bot can be restarted, redeployed, or down
for a while without losing anything. Every DM type has a boolean
sent-flag on the row it's about, so a restart or a slow poll cycle never
produces a duplicate.

Every notification fans out to every ID in
Settings.all_discord_recipient_ids() — the primary discord_user_id plus
any DiscordRecipient rows — so a second person can be added to get the
same alerts and pings.

Every send is wrapped in try/except, same rule as app/services/email.py —
a Discord hiccup (rate limit, a recipient left the shared server,
whatever) must never crash the poll loop or block the next booking's
reminder.
"""

import logging
import os
from datetime import datetime, timedelta, timezone as dt_timezone

import discord

from app import db
from app.models.booking import ACTIVE_BOOKING_STATUSES, Booking, BookingPingState
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


async def _dm_all(client, settings_row, embed, what):
    """Send the same embed to every recipient (primary + DiscordRecipient
    rows). Fire-and-forget — used for notifications nothing needs to track
    or delete later (new booking, cancellation, reminders, test)."""
    for recipient_id in settings_row.all_discord_recipient_ids():
        await _dm(client, recipient_id, embed, what)


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


async def _handle_test_requests(client):
    for settings_row in Settings.query.filter(Settings.discord_test_requested_at.isnot(None)).all():
        await _dm_all(client, settings_row, build_test_embed(), "test DM")
        settings_row.discord_test_requested_at = None
    db.session.commit()


async def _handle_new_bookings(client):
    bookings = Booking.query.filter(
        Booking.discord_new_notified.is_(False),
        Booking.status.in_(ACTIVE_BOOKING_STATUSES),
    ).all()
    for booking in bookings:
        settings_row = Settings.for_user(booking.user)
        recipients = settings_row.all_discord_recipient_ids()
        if recipients and settings_row.notify_discord_new_booking:
            await _dm_all(client, settings_row, build_new_booking_embed(booking), f"new-booking DM (#{booking.id})")
            if settings_row.discord_spam_ping_enabled:
                for recipient_id in recipients:
                    db.session.add(BookingPingState(booking_id=booking.id, discord_user_id=recipient_id, active=True))
        booking.discord_new_notified = True
    if bookings:
        db.session.commit()


async def _handle_cancellations(client):
    bookings = Booking.query.filter(
        Booking.discord_cancel_notified.is_(False),
        Booking.status == "cancelled",
        Booking.cancelled_at.isnot(None),
    ).all()
    for booking in bookings:
        settings_row = Settings.for_user(booking.user)
        if settings_row.all_discord_recipient_ids() and settings_row.notify_discord_cancellation:
            await _dm_all(client, settings_row, build_cancelled_embed(booking), f"cancellation DM (#{booking.id})")
        booking.discord_cancel_notified = True
        for ping_state in booking.ping_states:
            if ping_state.active:
                await _delete_dm_message(client, ping_state.discord_user_id, ping_state.last_message_id)
                ping_state.active = False
                ping_state.last_message_id = None
    if bookings:
        db.session.commit()


async def _handle_day_start(client, users):
    for user in users:
        settings_row = Settings.for_user(user)
        if not (settings_row.all_discord_recipient_ids() and settings_row.notify_discord_reminders):
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
            await _dm_all(client, settings_row, build_day_start_embed(todays), "day-start digest")
            for booking in todays:
                booking.discord_day_reminder_sent = True
            db.session.commit()


async def _handle_timed_reminders(client, users):
    for user in users:
        settings_row = Settings.for_user(user)
        if not (settings_row.all_discord_recipient_ids() and settings_row.notify_discord_reminders):
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
            await _dm_all(client, settings_row, build_hour_reminder_embed(booking), f"1-hour reminder (#{booking.id})")
            booking.discord_hour_reminder_sent = True

        fifteen_due = Booking.query.filter(
            Booking.user_id == user.id,
            Booking.status.in_(ACTIVE_BOOKING_STATUSES),
            Booking.discord_15min_reminder_sent.is_(False),
            Booking.start_datetime > now,
            Booking.start_datetime <= now + FIFTEEN_MIN_WINDOW,
        ).all()
        for booking in fifteen_due:
            await _dm_all(client, settings_row, build_15min_reminder_embed(booking), f"15-minute reminder (#{booking.id})")
            booking.discord_15min_reminder_sent = True

        if hour_due or fifteen_due:
            db.session.commit()


async def run_ping_tick(app, client):
    """Fires the repeated 'spam ping' DMs — one independent session per
    recipient per booking (BookingPingState). Called on its own fast
    timer (bot.py), separate from the main poll() loop, since pings need
    a much shorter cadence than everything else.

    Ping 1 is sent immediately (from _handle_new_bookings, one
    BookingPingState row created per recipient). From ping 2 onward, each
    recipient's previous ping message is deleted right before their next
    one goes out, so only ever one ping is visible per person at a time —
    right up until that person presses Stop, which only affects their own
    session, not anyone else's.
    """
    with app.app_context():
        try:
            now_utc = datetime.now(dt_timezone.utc).replace(tzinfo=None)
            active_states = BookingPingState.query.filter(BookingPingState.active.is_(True)).all()
            for state in active_states:
                booking = state.booking
                settings_row = Settings.for_user(booking.user)
                if not settings_row.discord_spam_ping_enabled:
                    state.active = False
                    continue

                # Nothing left to nag about once it's started/cancelled/etc.
                if booking.status not in ACTIVE_BOOKING_STATUSES or booking.start_datetime <= local_now(booking.user):
                    state.active = False
                    if state.last_message_id:
                        await _delete_dm_message(client, state.discord_user_id, state.last_message_id)
                        state.last_message_id = None
                    continue

                due_at = (state.last_sent_at or datetime.min) + PING_INTERVAL
                if now_utc < due_at:
                    continue

                next_ping_number = state.count + 1
                view = StopPingView(booking.id, state.discord_user_id)
                message = await _dm(
                    client, state.discord_user_id, build_ping_embed(booking, next_ping_number),
                    f"ping #{next_ping_number} (#{booking.id} -> {state.discord_user_id})", view=view,
                )
                if message is None:
                    # Couldn't send (Forbidden/etc) — stop trying rather than loop forever.
                    state.active = False
                    continue

                client.add_view(view, message_id=message.id)

                # From ping 2 onward, delete the one before it.
                if next_ping_number >= 2 and state.last_message_id:
                    await _delete_dm_message(client, state.discord_user_id, state.last_message_id)

                state.count = next_ping_number
                state.last_sent_at = now_utc
                state.last_message_id = str(message.id)

            db.session.commit()
        except Exception:  # noqa: BLE001 - one bad tick must not kill the loop
            db.session.rollback()
            logger.exception("Discord bot ping tick failed")


async def resume_active_ping_views(app, client):
    """Called once from on_ready — re-registers a StopPingView for every
    session still marked active, so Stop keeps working after a restart
    even though the in-memory view objects from before are gone."""
    with app.app_context():
        active_states = BookingPingState.query.filter(BookingPingState.active.is_(True)).all()
        for state in active_states:
            client.add_view(StopPingView(state.booking_id, state.discord_user_id))
        if active_states:
            logger.info("Re-registered %d active ping session(s) after restart.", len(active_states))


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
echo "wrote: discord_bot/notifier.py"

cat > discord_bot/views.py << 'SCHEDEOF'
"""The Stop button attached to every spam-ping DM.

One view instance per (booking, recipient) pair, with both ids baked
into the button's custom_id (``stop_ping:<booking_id>:<discord_user_id>``)
so it keeps working across bot restarts, and so each recipient's Stop
button only ever stops *their own* ping session — not anyone else's.
on_ready re-registers a fresh view for every still-active session (see
bot.py), and Discord routes the click by matching that custom_id string,
not by object identity.
"""

import logging

import discord

logger = logging.getLogger("discord_bot.views")

# Set by bot.py after create_app() — the view's callback needs an app
# context to touch the database, same as notifier.py.
flask_app = None


class StopPingView(discord.ui.View):
    def __init__(self, booking_id, discord_user_id):
        super().__init__(timeout=None)
        self.booking_id = booking_id
        self.discord_user_id = str(discord_user_id)
        # Decorated children are rebuilt per-instance on __init__, so it's
        # safe to give this instance's button its own custom_id here.
        self.stop_button.custom_id = f"stop_ping:{booking_id}:{self.discord_user_id}"

    @discord.ui.button(label="Stop pings", style=discord.ButtonStyle.danger, emoji="\U0001F6D1")
    async def stop_button(self, interaction: discord.Interaction, button: discord.ui.Button):
        from app import db
        from app.models.booking import BookingPingState

        with flask_app.app_context():
            state = BookingPingState.query.filter_by(
                booking_id=self.booking_id, discord_user_id=self.discord_user_id
            ).first()
            if state is not None:
                state.active = False
                state.last_message_id = None
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
            logger.exception(
                "Failed to edit ping message after stop for booking %s / recipient %s",
                self.booking_id, self.discord_user_id,
            )
        self.stop()
SCHEDEOF
echo "wrote: discord_bot/views.py"

cat > migrations/versions/f4d9b2c7a1e6_multi_recipient_pings_and_actions.py << 'SCHEDEOF'
"""Multi-recipient Discord pings + dashboard action support

Revision ID: f4d9b2c7a1e6
Revises: e2f6a8c1b3d5
Create Date: 2026-08-14 15:00:00.000000

"""
from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision = 'f4d9b2c7a1e6'
down_revision = 'e2f6a8c1b3d5'
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        'discord_recipients',
        sa.Column('id', sa.Integer(), nullable=False),
        sa.Column('user_id', sa.Integer(), nullable=False),
        sa.Column('discord_user_id', sa.String(length=32), nullable=False),
        sa.Column('label', sa.String(length=80), nullable=True),
        sa.Column('created_at', sa.DateTime(), nullable=True),
        sa.ForeignKeyConstraint(['user_id'], ['users.id'], ),
        sa.PrimaryKeyConstraint('id'),
        sa.UniqueConstraint('user_id', 'discord_user_id', name='uq_discord_recipient'),
    )
    with op.batch_alter_table('discord_recipients', schema=None) as batch_op:
        batch_op.create_index(batch_op.f('ix_discord_recipients_user_id'), ['user_id'], unique=False)

    op.create_table(
        'booking_ping_states',
        sa.Column('id', sa.Integer(), nullable=False),
        sa.Column('booking_id', sa.Integer(), nullable=False),
        sa.Column('discord_user_id', sa.String(length=32), nullable=False),
        sa.Column('active', sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column('count', sa.Integer(), nullable=False, server_default='0'),
        sa.Column('last_sent_at', sa.DateTime(), nullable=True),
        sa.Column('last_message_id', sa.String(length=32), nullable=True),
        sa.ForeignKeyConstraint(['booking_id'], ['bookings.id'], ),
        sa.PrimaryKeyConstraint('id'),
        sa.UniqueConstraint('booking_id', 'discord_user_id', name='uq_booking_ping_recipient'),
    )
    with op.batch_alter_table('booking_ping_states', schema=None) as batch_op:
        batch_op.create_index(batch_op.f('ix_booking_ping_states_booking_id'), ['booking_id'], unique=False)

    # Old single-recipient ping tracking on Booking is superseded by
    # booking_ping_states above — nothing currently running depends on
    # these values surviving, so they're dropped rather than migrated.
    with op.batch_alter_table('bookings', schema=None) as batch_op:
        batch_op.drop_column('discord_ping_last_message_id')
        batch_op.drop_column('discord_ping_last_sent_at')
        batch_op.drop_column('discord_ping_count')
        batch_op.drop_column('discord_ping_active')


def downgrade():
    with op.batch_alter_table('bookings', schema=None) as batch_op:
        batch_op.add_column(sa.Column('discord_ping_active', sa.Boolean(), nullable=False, server_default=sa.false()))
        batch_op.add_column(sa.Column('discord_ping_count', sa.Integer(), nullable=False, server_default='0'))
        batch_op.add_column(sa.Column('discord_ping_last_sent_at', sa.DateTime(), nullable=True))
        batch_op.add_column(sa.Column('discord_ping_last_message_id', sa.String(length=32), nullable=True))

    with op.batch_alter_table('booking_ping_states', schema=None) as batch_op:
        batch_op.drop_index(batch_op.f('ix_booking_ping_states_booking_id'))
    op.drop_table('booking_ping_states')

    with op.batch_alter_table('discord_recipients', schema=None) as batch_op:
        batch_op.drop_index(batch_op.f('ix_discord_recipients_user_id'))
    op.drop_table('discord_recipients')
SCHEDEOF
echo "wrote: migrations/versions/f4d9b2c7a1e6_multi_recipient_pings_and_actions.py"

echo "--- installing dependencies ---"
pip install -r requirements.txt --break-system-packages || pip install -r requirements.txt

echo "--- running migrations ---"
flask db upgrade

echo "--- restarting the Discord bot service ---"
systemctl restart scheduler-discord.service

echo "Done. Restart your gunicorn/web service too (whatever it is named) so the new admin routes and templates load."
