#!/usr/bin/env bash
# Scheduler patch — housekeeping fix (UI patch + midnight fix + calendarmaker
# fix that never actually landed) + new ISP Support feature + Availability/Time
# Off explainer. Paste this whole block into a terminal on the server.
#
# Usage:
#   APP_DIR=/root/scheduler SERVICE_NAME=scheduler ./this_script.sh
# (defaults match your deploy.sh)
set -euo pipefail

APP_DIR="${APP_DIR:-/root/scheduler}"
SERVICE_NAME="${SERVICE_NAME:-scheduler}"
PORT="${PORT:-5076}"

[ -f "$APP_DIR/run.py" ] || { echo "APP_DIR ($APP_DIR) doesn't look like the scheduler app — set APP_DIR=/path first."; exit 1; }

ts=$(date +%Y%m%d%H%M%S)
echo "Backing up changed files to $APP_DIR/.pre-patch-backup-$ts ..."
mkdir -p "$APP_DIR/.pre-patch-backup-$ts"
[ -f "$APP_DIR/requirements.txt" ] && { mkdir -p "$APP_DIR/.pre-patch-backup-$ts/$(dirname requirements.txt)"; cp "$APP_DIR/requirements.txt" "$APP_DIR/.pre-patch-backup-$ts/requirements.txt"; } || true
[ -f "$APP_DIR/app/__init__.py" ] && { mkdir -p "$APP_DIR/.pre-patch-backup-$ts/$(dirname app/__init__.py)"; cp "$APP_DIR/app/__init__.py" "$APP_DIR/.pre-patch-backup-$ts/app/__init__.py"; } || true
[ -f "$APP_DIR/app/forms.py" ] && { mkdir -p "$APP_DIR/.pre-patch-backup-$ts/$(dirname app/forms.py)"; cp "$APP_DIR/app/forms.py" "$APP_DIR/.pre-patch-backup-$ts/app/forms.py"; } || true
[ -f "$APP_DIR/app/models/__init__.py" ] && { mkdir -p "$APP_DIR/.pre-patch-backup-$ts/$(dirname app/models/__init__.py)"; cp "$APP_DIR/app/models/__init__.py" "$APP_DIR/.pre-patch-backup-$ts/app/models/__init__.py"; } || true
[ -f "$APP_DIR/app/models/isp_support.py" ] && { mkdir -p "$APP_DIR/.pre-patch-backup-$ts/$(dirname app/models/isp_support.py)"; cp "$APP_DIR/app/models/isp_support.py" "$APP_DIR/.pre-patch-backup-$ts/app/models/isp_support.py"; } || true
[ -f "$APP_DIR/app/services/crypto.py" ] && { mkdir -p "$APP_DIR/.pre-patch-backup-$ts/$(dirname app/services/crypto.py)"; cp "$APP_DIR/app/services/crypto.py" "$APP_DIR/.pre-patch-backup-$ts/app/services/crypto.py"; } || true
[ -f "$APP_DIR/app/routes/isp_support.py" ] && { mkdir -p "$APP_DIR/.pre-patch-backup-$ts/$(dirname app/routes/isp_support.py)"; cp "$APP_DIR/app/routes/isp_support.py" "$APP_DIR/.pre-patch-backup-$ts/app/routes/isp_support.py"; } || true
[ -f "$APP_DIR/app/routes/admin.py" ] && { mkdir -p "$APP_DIR/.pre-patch-backup-$ts/$(dirname app/routes/admin.py)"; cp "$APP_DIR/app/routes/admin.py" "$APP_DIR/.pre-patch-backup-$ts/app/routes/admin.py"; } || true
[ -f "$APP_DIR/app/routes/calendarmaker.py" ] && { mkdir -p "$APP_DIR/.pre-patch-backup-$ts/$(dirname app/routes/calendarmaker.py)"; cp "$APP_DIR/app/routes/calendarmaker.py" "$APP_DIR/.pre-patch-backup-$ts/app/routes/calendarmaker.py"; } || true
[ -f "$APP_DIR/app/models/calendar_maker.py" ] && { mkdir -p "$APP_DIR/.pre-patch-backup-$ts/$(dirname app/models/calendar_maker.py)"; cp "$APP_DIR/app/models/calendar_maker.py" "$APP_DIR/.pre-patch-backup-$ts/app/models/calendar_maker.py"; } || true
[ -f "$APP_DIR/app/services/availability.py" ] && { mkdir -p "$APP_DIR/.pre-patch-backup-$ts/$(dirname app/services/availability.py)"; cp "$APP_DIR/app/services/availability.py" "$APP_DIR/.pre-patch-backup-$ts/app/services/availability.py"; } || true
[ -f "$APP_DIR/app/templates/base.html" ] && { mkdir -p "$APP_DIR/.pre-patch-backup-$ts/$(dirname app/templates/base.html)"; cp "$APP_DIR/app/templates/base.html" "$APP_DIR/.pre-patch-backup-$ts/app/templates/base.html"; } || true
[ -f "$APP_DIR/app/templates/layouts/admin.html" ] && { mkdir -p "$APP_DIR/.pre-patch-backup-$ts/$(dirname app/templates/layouts/admin.html)"; cp "$APP_DIR/app/templates/layouts/admin.html" "$APP_DIR/.pre-patch-backup-$ts/app/templates/layouts/admin.html"; } || true
[ -f "$APP_DIR/app/templates/partials/flash.html" ] && { mkdir -p "$APP_DIR/.pre-patch-backup-$ts/$(dirname app/templates/partials/flash.html)"; cp "$APP_DIR/app/templates/partials/flash.html" "$APP_DIR/.pre-patch-backup-$ts/app/templates/partials/flash.html"; } || true
[ -f "$APP_DIR/app/templates/partials/view_mode_modal.html" ] && { mkdir -p "$APP_DIR/.pre-patch-backup-$ts/$(dirname app/templates/partials/view_mode_modal.html)"; cp "$APP_DIR/app/templates/partials/view_mode_modal.html" "$APP_DIR/.pre-patch-backup-$ts/app/templates/partials/view_mode_modal.html"; } || true
[ -f "$APP_DIR/app/templates/admin/availability.html" ] && { mkdir -p "$APP_DIR/.pre-patch-backup-$ts/$(dirname app/templates/admin/availability.html)"; cp "$APP_DIR/app/templates/admin/availability.html" "$APP_DIR/.pre-patch-backup-$ts/app/templates/admin/availability.html"; } || true
[ -f "$APP_DIR/app/templates/admin/isp_support_list.html" ] && { mkdir -p "$APP_DIR/.pre-patch-backup-$ts/$(dirname app/templates/admin/isp_support_list.html)"; cp "$APP_DIR/app/templates/admin/isp_support_list.html" "$APP_DIR/.pre-patch-backup-$ts/app/templates/admin/isp_support_list.html"; } || true
[ -f "$APP_DIR/app/templates/admin/isp_support_detail.html" ] && { mkdir -p "$APP_DIR/.pre-patch-backup-$ts/$(dirname app/templates/admin/isp_support_detail.html)"; cp "$APP_DIR/app/templates/admin/isp_support_detail.html" "$APP_DIR/.pre-patch-backup-$ts/app/templates/admin/isp_support_detail.html"; } || true
[ -f "$APP_DIR/app/templates/public/isp_support_form.html" ] && { mkdir -p "$APP_DIR/.pre-patch-backup-$ts/$(dirname app/templates/public/isp_support_form.html)"; cp "$APP_DIR/app/templates/public/isp_support_form.html" "$APP_DIR/.pre-patch-backup-$ts/app/templates/public/isp_support_form.html"; } || true
[ -f "$APP_DIR/app/templates/public/isp_support_thanks.html" ] && { mkdir -p "$APP_DIR/.pre-patch-backup-$ts/$(dirname app/templates/public/isp_support_thanks.html)"; cp "$APP_DIR/app/templates/public/isp_support_thanks.html" "$APP_DIR/.pre-patch-backup-$ts/app/templates/public/isp_support_thanks.html"; } || true
[ -f "$APP_DIR/app/static/js/app.js" ] && { mkdir -p "$APP_DIR/.pre-patch-backup-$ts/$(dirname app/static/js/app.js)"; cp "$APP_DIR/app/static/js/app.js" "$APP_DIR/.pre-patch-backup-$ts/app/static/js/app.js"; } || true
[ -f "$APP_DIR/app/static/css/input.css" ] && { mkdir -p "$APP_DIR/.pre-patch-backup-$ts/$(dirname app/static/css/input.css)"; cp "$APP_DIR/app/static/css/input.css" "$APP_DIR/.pre-patch-backup-$ts/app/static/css/input.css"; } || true
[ -f "$APP_DIR/app/static/css/main.css" ] && { mkdir -p "$APP_DIR/.pre-patch-backup-$ts/$(dirname app/static/css/main.css)"; cp "$APP_DIR/app/static/css/main.css" "$APP_DIR/.pre-patch-backup-$ts/app/static/css/main.css"; } || true
[ -f "$APP_DIR/migrations/versions/c709f4333571_add_isp_support_requests.py" ] && { mkdir -p "$APP_DIR/.pre-patch-backup-$ts/$(dirname migrations/versions/c709f4333571_add_isp_support_requests.py)"; cp "$APP_DIR/migrations/versions/c709f4333571_add_isp_support_requests.py" "$APP_DIR/.pre-patch-backup-$ts/migrations/versions/c709f4333571_add_isp_support_requests.py"; } || true

# Clean up stray leftovers from earlier partial patch attempts, if present.
rm -rf "$APP_DIR/app/app"
rm -f "$APP_DIR"/app/routes/admin.py.bak.* "$APP_DIR"/app/templates/admin/availability.html.bak* "$APP_DIR"/app/templates/admin/availability.html.before-form-fix

mkdir -p "$APP_DIR"
cat > "$APP_DIR/requirements.txt" << 'CLAUDE_PATCH_EOF'
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
cryptography==44.0.0

# Add for production PostgreSQL:
# psycopg2-binary==2.9.10
# Add for production WSGI server:
# gunicorn==23.0.0
CLAUDE_PATCH_EOF

mkdir -p "$APP_DIR/app"
cat > "$APP_DIR/app/__init__.py" << 'CLAUDE_PATCH_EOF'
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
    isp_name = StringField(
        "ISP / Internet Service Provider name", validators=[DataRequired(message="Enter your ISP's name."), Length(max=200)]
    )
    problem_description = TextAreaField(
        "Describe the internet/service problem",
        validators=[DataRequired(message="Briefly describe the problem."), Length(max=4000)],
    )

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


class SupportRequestStatusForm(FlaskForm):
    status = SelectField(
        "Status",
        choices=[("new", "New"), ("contacted", "ISP contacted"), ("verifying", "Awaiting your verification"),
                 ("resolved", "Resolved"), ("closed", "Closed")],
        validators=[DataRequired()],
    )
    admin_notes = TextAreaField("Internal notes", validators=[Optional(), Length(max=4000)])
CLAUDE_PATCH_EOF

mkdir -p "$APP_DIR/app/models"
cat > "$APP_DIR/app/models/__init__.py" << 'CLAUDE_PATCH_EOF'
from app.models.user import User  # noqa: F401
from app.models.availability import WorkingHours, Break  # noqa: F401
from app.models.time_off import TimeOff  # noqa: F401
from app.models.settings import Settings  # noqa: F401
from app.models.booking import BookingType, Booking  # noqa: F401
from app.models.calendar_maker import SharedCalendar, CalendarAccess, CalendarEvent  # noqa: F401
from app.models.isp_support import SupportRequest, SupportAccessLog  # noqa: F401
CLAUDE_PATCH_EOF

mkdir -p "$APP_DIR/app/models"
cat > "$APP_DIR/app/models/isp_support.py" << 'CLAUDE_PATCH_EOF'
from datetime import datetime, timezone as dt_timezone

from app import db
from app.services.crypto import EncryptedString

STATUSES = ["new", "contacted", "verifying", "resolved", "closed"]
STATUS_LABELS = {
    "new": "New",
    "contacted": "ISP contacted",
    "verifying": "Awaiting your verification",
    "resolved": "Resolved",
    "closed": "Closed",
}


class SupportRequest(db.Model):
    """A customer's request + authorisation to contact their ISP on their
    behalf, per the ISP Support & Customer Authorisation policy.

    Fields the policy explicitly marks as sensitive-if-required
    (account/customer number, DOB, mother's maiden name, childhood
    nickname, security answers, other security info) are encrypted at
    rest via EncryptedString — see app/services/crypto.py. Passwords and
    one-time codes are never collected, so there's deliberately no column
    for them anywhere in this model.
    """

    __tablename__ = "support_requests"

    id = db.Column(db.Integer, primary_key=True)
    status = db.Column(db.String(20), nullable=False, default="new", index=True)
    submitted_at = db.Column(db.DateTime, default=lambda: datetime.now(dt_timezone.utc), index=True)
    resolved_at = db.Column(db.DateTime, nullable=True)

    # Contact / identification — not especially sensitive on their own.
    full_name = db.Column(db.String(200), nullable=False)
    email = db.Column(db.String(255), nullable=True)
    phone = db.Column(db.String(50), nullable=True)
    isp_name = db.Column(db.String(200), nullable=False)
    problem_description = db.Column(db.Text, nullable=False)

    # Account verification details — encrypted at rest.
    account_number = db.Column(EncryptedString, nullable=True)
    customer_number = db.Column(EncryptedString, nullable=True)
    full_address = db.Column(EncryptedString, nullable=True)
    service_address = db.Column(EncryptedString, nullable=True)
    date_of_birth = db.Column(EncryptedString, nullable=True)  # stored as free text, not a Date — optional field
    last_bill_date = db.Column(db.String(20), nullable=True)
    last_bill_amount = db.Column(db.String(20), nullable=True)

    # ISP-specific security questions — encrypted at rest.
    mothers_maiden_name = db.Column(EncryptedString, nullable=True)
    childhood_nickname = db.Column(EncryptedString, nullable=True)
    security_question = db.Column(db.String(255), nullable=True)
    security_answer = db.Column(EncryptedString, nullable=True)
    other_security_info = db.Column(EncryptedString, nullable=True)

    # Consent — every field required by the policy's authorisation section.
    consent_authorised = db.Column(db.Boolean, nullable=False, default=False)
    consent_accurate = db.Column(db.Boolean, nullable=False, default=False)
    consent_purpose = db.Column(db.Boolean, nullable=False, default=False)
    consent_additional_verification = db.Column(db.Boolean, nullable=False, default=False)
    consent_no_password_request = db.Column(db.Boolean, nullable=False, default=False)

    admin_notes = db.Column(db.Text, nullable=True)

    access_logs = db.relationship(
        "SupportAccessLog", backref="request", lazy="dynamic", cascade="all, delete-orphan"
    )

    @property
    def status_label(self):
        return STATUS_LABELS.get(self.status, self.status)


class SupportAccessLog(db.Model):
    """Records every time a staff account opens a support request's detail
    page — the "audit logs showing who accessed customer information"
    requirement from the policy.
    """

    __tablename__ = "support_access_logs"

    id = db.Column(db.Integer, primary_key=True)
    support_request_id = db.Column(db.Integer, db.ForeignKey("support_requests.id"), nullable=False, index=True)
    user_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False)
    accessed_at = db.Column(db.DateTime, default=lambda: datetime.now(dt_timezone.utc))

    user = db.relationship("User")
CLAUDE_PATCH_EOF

mkdir -p "$APP_DIR/app/services"
cat > "$APP_DIR/app/services/crypto.py" << 'CLAUDE_PATCH_EOF'
"""At-rest encryption for sensitive fields.

Used for the handful of ISP-support fields that are genuinely sensitive if
the database file itself is ever copied or leaked (DOB, mother's maiden
name, account numbers, security answers). This is symmetric encryption
with a key stored on disk next to the database — it protects a raw SQLite
file dump, not a fully-compromised server. It is deliberately NOT used for
anything the checklist says must never be stored at all (passwords, OTPs).
"""

import os

from cryptography.fernet import Fernet, InvalidToken
from sqlalchemy.types import TypeDecorator, LargeBinary

_KEY_ENV_VAR = "ISP_SUPPORT_ENC_KEY"
_fernet = None


def _load_or_create_key(instance_path):
    """Reuse a key from the environment if set, else a persisted key file.

    Keeping the key on disk (rather than requiring env-var setup) means
    this works out of the box on a fresh checkout, the same way Flask's
    own SECRET_KEY has a dev fallback — but it's still a real per-install
    random key, not a hardcoded one, and production deployments can
    override it via the environment.
    """
    env_key = os.environ.get(_KEY_ENV_VAR)
    if env_key:
        return env_key.encode()

    key_path = os.path.join(instance_path, "isp_support.key")
    if os.path.exists(key_path):
        with open(key_path, "rb") as f:
            return f.read().strip()

    key = Fernet.generate_key()
    os.makedirs(instance_path, exist_ok=True)
    with open(key_path, "wb") as f:
        f.write(key)
    try:
        os.chmod(key_path, 0o600)
    except OSError:
        pass
    return key


def init_encryption(instance_path):
    """Call once at app startup (from create_app) before any encrypted
    column is read or written."""
    global _fernet
    _fernet = Fernet(_load_or_create_key(instance_path))


def _require_fernet():
    if _fernet is None:
        raise RuntimeError(
            "Encryption not initialized — call init_encryption() from create_app() first."
        )
    return _fernet


class EncryptedString(TypeDecorator):
    """A String column that's encrypted at rest and transparent in Python.

    Reads/writes plain str in application code; stores encrypted bytes in
    the database. A blank/None value stays None (no point encrypting
    emptiness, and it keeps "not provided" distinguishable from "provided
    but empty").
    """

    impl = LargeBinary
    cache_ok = True

    def process_bind_param(self, value, dialect):
        if value is None or value == "":
            return None
        token = _require_fernet().encrypt(value.encode("utf-8"))
        return token

    def process_result_value(self, value, dialect):
        if value is None:
            return None
        try:
            return _require_fernet().decrypt(bytes(value)).decode("utf-8")
        except InvalidToken:
            # Key rotated/mismatched — surface as missing rather than a
            # hard crash on every page that lists requests.
            return None
CLAUDE_PATCH_EOF

mkdir -p "$APP_DIR/app/routes"
cat > "$APP_DIR/app/routes/isp_support.py" << 'CLAUDE_PATCH_EOF'
from flask import Blueprint, abort, flash, redirect, render_template, request, url_for
from flask_login import current_user, login_required

from app import db
from app.forms import CSRFOnlyForm, ISPSupportForm, SupportRequestStatusForm
from app.models.isp_support import STATUSES, SupportAccessLog, SupportRequest

isp_support_bp = Blueprint("isp_support", __name__)


@isp_support_bp.route("/support/isp", methods=["GET", "POST"])
def request_form():
    form = ISPSupportForm()
    if form.validate_on_submit():
        req = SupportRequest(
            full_name=form.full_name.data.strip(),
            email=(form.email.data or "").strip() or None,
            phone=(form.phone.data or "").strip() or None,
            isp_name=form.isp_name.data.strip(),
            problem_description=form.problem_description.data.strip(),
            account_number=(form.account_number.data or "").strip() or None,
            customer_number=(form.customer_number.data or "").strip() or None,
            full_address=(form.full_address.data or "").strip() or None,
            service_address=(form.service_address.data or "").strip() or None,
            date_of_birth=(form.date_of_birth.data or "").strip() or None,
            last_bill_date=(form.last_bill_date.data or "").strip() or None,
            last_bill_amount=(form.last_bill_amount.data or "").strip() or None,
            mothers_maiden_name=(form.mothers_maiden_name.data or "").strip() or None,
            childhood_nickname=(form.childhood_nickname.data or "").strip() or None,
            security_question=(form.security_question.data or "").strip() or None,
            security_answer=(form.security_answer.data or "").strip() or None,
            other_security_info=(form.other_security_info.data or "").strip() or None,
            consent_authorised=bool(form.consent_authorised.data),
            consent_accurate=bool(form.consent_accurate.data),
            consent_purpose=bool(form.consent_purpose.data),
            consent_additional_verification=bool(form.consent_additional_verification.data),
            consent_no_password_request=bool(form.consent_no_password_request.data),
        )
        db.session.add(req)
        db.session.commit()
        return redirect(url_for("isp_support.thank_you"))

    return render_template("public/isp_support_form.html", form=form)


@isp_support_bp.route("/support/isp/thank-you")
def thank_you():
    return render_template("public/isp_support_thanks.html")


@isp_support_bp.route("/admin/isp-support")
@login_required
def admin_list():
    status_filter = request.args.get("status", "").strip()
    query = SupportRequest.query
    if status_filter in STATUSES:
        query = query.filter_by(status=status_filter)
    requests_ = query.order_by(SupportRequest.submitted_at.desc()).all()
    return render_template(
        "admin/isp_support_list.html",
        requests=requests_,
        status_filter=status_filter,
        statuses=STATUSES,
        active_page="isp_support",
    )


@isp_support_bp.route("/admin/isp-support/<int:request_id>", methods=["GET", "POST"])
@login_required
def admin_detail(request_id):
    req = SupportRequest.query.get_or_404(request_id)

    # Audit log — every view of a request's details is recorded, per the
    # policy's access-log requirement.
    db.session.add(SupportAccessLog(support_request_id=req.id, user_id=current_user.id))
    db.session.commit()

    status_form = SupportRequestStatusForm(status=req.status, admin_notes=req.admin_notes or "")
    delete_form = CSRFOnlyForm()

    if request.method == "POST" and status_form.validate_on_submit():
        from datetime import datetime, timezone as dt_timezone

        req.status = status_form.status.data
        req.admin_notes = status_form.admin_notes.data.strip() if status_form.admin_notes.data else None
        if req.status in ("resolved", "closed") and not req.resolved_at:
            req.resolved_at = datetime.now(dt_timezone.utc)
        elif req.status not in ("resolved", "closed"):
            req.resolved_at = None
        db.session.commit()
        flash("Request updated.", "success")
        return redirect(url_for("isp_support.admin_detail", request_id=req.id))

    recent_access = req.access_logs.order_by(SupportAccessLog.accessed_at.desc()).limit(10).all()

    return render_template(
        "admin/isp_support_detail.html",
        req=req,
        status_form=status_form,
        delete_form=delete_form,
        recent_access=recent_access,
        active_page="isp_support",
    )


@isp_support_bp.route("/admin/isp-support/<int:request_id>/delete", methods=["POST"])
@login_required
def admin_delete(request_id):
    req = SupportRequest.query.get_or_404(request_id)
    db.session.delete(req)
    db.session.commit()
    flash("Request deleted.", "success")
    return redirect(url_for("isp_support.admin_list"))
CLAUDE_PATCH_EOF

mkdir -p "$APP_DIR/app/routes"
cat > "$APP_DIR/app/routes/admin.py" << 'CLAUDE_PATCH_EOF'
from datetime import datetime, time as dt_time, timedelta, timezone as dt_timezone

from flask import Blueprint, abort, flash, redirect, render_template, request, url_for
from flask_login import current_user, login_required

from app import db
from app.forms import BookingTypeForm, BreakForm, CSRFOnlyForm, CurrentTaskForm, NotificationSettingsForm, ProfileForm, StatusOverrideForm, TimeOffForm
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
    status_url = url_for("public.status_page", _external=True)
    booking_url = url_for("public.booking_types", _external=True)
    widget_url = url_for("public.widget_script", _external=True)
    return render_template(
        "admin/settings.html",
        profile_form=profile_form,
        notif_form=notif_form,
        active_page="settings",
        status_url=status_url,
        booking_url=booking_url,
        widget_url=widget_url,
    )


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

mkdir -p "$APP_DIR/app/routes"
cat > "$APP_DIR/app/routes/calendarmaker.py" << 'CLAUDE_PATCH_EOF'
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
    member_count = CalendarAccess.query.filter_by(shared_calendar_id=calendar.id).count()

    return render_template(
        "calendarmaker/calendar.html",
        calendar=calendar,
        access=access,
        form=form,
        upcoming=upcoming,
        past=past,
        share_url=share_url,
        member_count=member_count,
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
CLAUDE_PATCH_EOF

mkdir -p "$APP_DIR/app/models"
cat > "$APP_DIR/app/models/calendar_maker.py" << 'CLAUDE_PATCH_EOF'
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

mkdir -p "$APP_DIR/app/templates"
cat > "$APP_DIR/app/templates/base.html" << 'CLAUDE_PATCH_EOF'
<!DOCTYPE html>
<html lang="en" class="h-full">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>{% block title %}{{ app_name }}{% endblock %}</title>
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=Space+Grotesk:wght@500;600;700&display=swap" rel="stylesheet">
  <link rel="stylesheet" href="{{ url_for('static', filename='css/main.css') }}">
  <script>
    // Apply any saved display-mode choice before first paint, so there's
    // no flash of the wrong layout. Falls through to normal responsive
    // behavior if nothing has been chosen yet.
    (function () {
      try {
        var v = localStorage.getItem("schedulerViewMode");
        if (v && v !== "auto") {
          document.documentElement.setAttribute("data-view", v);
        }
      } catch (e) {}
    })();
  </script>
</head>
<body class="h-full bg-base text-ink">
  {% block body %}{% endblock %}
  <script src="{{ url_for('static', filename='js/app.js') }}"></script>
</body>
</html>
CLAUDE_PATCH_EOF

mkdir -p "$APP_DIR/app/templates/layouts"
cat > "$APP_DIR/app/templates/layouts/admin.html" << 'CLAUDE_PATCH_EOF'
{% extends "base.html" %}

{% block body %}
<div class="min-h-full lg:flex">

  <!-- Mobile topbar -->
  <header class="vm-topbar lg:hidden sticky top-0 z-30 flex items-center justify-between border-b border-border bg-base/95 backdrop-blur px-4 py-3">
    <a href="{{ url_for('admin.dashboard') }}" class="flex items-center gap-2 font-display font-semibold text-ink">
      <span class="status-dot bg-accent"></span>
      {{ app_name }}
    </a>
    <div class="flex items-center gap-1">
      <button id="view-mode-trigger" type="button" aria-label="Change display mode" title="Display" class="btn-ghost !px-2">
        <svg xmlns="http://www.w3.org/2000/svg" class="h-5 w-5" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="2" y="4" width="20" height="13" rx="1.5"/><line x1="8" y1="21" x2="16" y2="21"/><line x1="12" y1="17" x2="12" y2="21"/></svg>
      </button>
      <button id="nav-toggle" type="button" aria-label="Open menu" aria-expanded="false" class="btn-ghost !px-2">
        <svg xmlns="http://www.w3.org/2000/svg" class="h-5 w-5" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="3" y1="6" x2="21" y2="6"/><line x1="3" y1="12" x2="21" y2="12"/><line x1="3" y1="18" x2="21" y2="18"/></svg>
      </button>
    </div>
  </header>

  <!-- Sidebar -->
  <aside id="sidebar" class="vm-sidebar fixed inset-y-0 left-0 z-40 w-72 -translate-x-full border-r border-border bg-surface p-5 transition-transform duration-200 lg:static lg:translate-x-0 lg:flex lg:w-64 lg:flex-col lg:shrink-0">
    <div class="flex items-center justify-between mb-8">
      <a href="{{ url_for('admin.dashboard') }}" class="flex items-center gap-2 font-display text-lg font-semibold text-ink">
        <span class="status-dot bg-accent"></span>
        {{ app_name }}
      </a>
      <button id="nav-close" type="button" aria-label="Close menu" class="lg:hidden btn-ghost !px-2">
        <svg xmlns="http://www.w3.org/2000/svg" class="h-5 w-5" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>
      </button>
    </div>

    <nav class="flex-1 space-y-1">
      <a href="{{ url_for('admin.dashboard') }}" class="{{ 'nav-link-active' if active_page == 'dashboard' else 'nav-link' }}">
        <svg xmlns="http://www.w3.org/2000/svg" class="h-[18px] w-[18px]" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="7" height="9" rx="1.5"/><rect x="14" y="3" width="7" height="5" rx="1.5"/><rect x="14" y="12" width="7" height="9" rx="1.5"/><rect x="3" y="16" width="7" height="5" rx="1.5"/></svg>
        Dashboard
      </a>

      <p class="px-3 pt-5 pb-1.5 text-[11px] font-semibold uppercase tracking-wider text-ink-faint">Schedule</p>

      <a href="{{ url_for('admin.calendar_view') }}" class="{{ 'nav-link-active' if active_page == 'calendar' else 'nav-link' }}">
        <svg xmlns="http://www.w3.org/2000/svg" class="h-[18px] w-[18px]" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M8 2v3M16 2v3M3.5 8.5h17M4 5h16a1 1 0 011 1v14a1 1 0 01-1 1H4a1 1 0 01-1-1V6a1 1 0 011-1z"/></svg>
        Calendar
      </a>

      <a href="{{ url_for('admin.availability') }}" class="{{ 'nav-link-active' if active_page == 'availability' else 'nav-link' }}">
        <svg xmlns="http://www.w3.org/2000/svg" class="h-[18px] w-[18px]" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 7v5l3 2M12 21a9 9 0 100-18 9 9 0 000 18z"/></svg>
        Availability
      </a>

      <a href="{{ url_for('admin.time_off') }}" class="{{ 'nav-link-active' if active_page == 'time_off' else 'nav-link' }}">
        <svg xmlns="http://www.w3.org/2000/svg" class="h-[18px] w-[18px]" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 4h16v16H4zM4 9h16M9 4v5"/></svg>
        Time Off
      </a>

      <a href="{{ url_for('admin.bookings') }}" class="{{ 'nav-link-active' if active_page == 'bookings' else 'nav-link' }}">
        <svg xmlns="http://www.w3.org/2000/svg" class="h-[18px] w-[18px]" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M9 5H7a2 2 0 00-2 2v12a2 2 0 002 2h10a2 2 0 002-2V7a2 2 0 00-2-2h-2M9 5a2 2 0 002 2h2a2 2 0 002-2M9 5a2 2 0 012-2h2a2 2 0 012 2"/></svg>
        Bookings
      </a>

      <a href="{{ url_for('isp_support.admin_list') }}" class="{{ 'nav-link-active' if active_page == 'isp_support' else 'nav-link' }}">
        <svg xmlns="http://www.w3.org/2000/svg" class="h-[18px] w-[18px]" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M22 16.92v3a2 2 0 01-2.18 2 19.79 19.79 0 01-8.63-3.07 19.5 19.5 0 01-6-6 19.79 19.79 0 01-3.07-8.67A2 2 0 014.11 2h3a2 2 0 012 1.72c.127.96.362 1.903.7 2.81a2 2 0 01-.45 2.11L8.09 9.91a16 16 0 006 6l1.27-1.27a2 2 0 012.11-.45c.907.338 1.85.573 2.81.7A2 2 0 0122 16.92z"/></svg>
        ISP Support
      </a>

      <p class="px-3 pt-5 pb-1.5 text-[11px] font-semibold uppercase tracking-wider text-ink-faint">Configure</p>

      <a href="{{ url_for('admin.booking_types') }}" class="{{ 'nav-link-active' if active_page == 'booking_types' else 'nav-link' }}">
        <svg xmlns="http://www.w3.org/2000/svg" class="h-[18px] w-[18px]" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M20.59 13.41L11 22l-8-8L21.59 4.41A2 2 0 0122 6v6a1 1 0 01-.29.7z"/></svg>
        Booking Types
      </a>

      <span class="nav-link cursor-not-allowed opacity-60" title="Coming in a later phase">
        <svg xmlns="http://www.w3.org/2000/svg" class="h-[18px] w-[18px]" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M18 8a6 6 0 10-12 0c0 7-3 9-3 9h18s-3-2-3-9M13.73 21a2 2 0 01-3.46 0"/></svg>
        Notifications
        <span class="ml-auto text-[10px] font-medium uppercase tracking-wide text-ink-faint border border-border rounded px-1.5 py-0.5">Soon</span>
      </span>

      <a href="{{ url_for('admin.settings') }}" class="{{ 'nav-link-active' if active_page == 'settings' else 'nav-link' }}">
        <svg xmlns="http://www.w3.org/2000/svg" class="h-[18px] w-[18px]" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 15a3 3 0 100-6 3 3 0 000 6zM19.4 15a1.65 1.65 0 00.33 1.82l.06.06a2 2 0 11-2.83 2.83l-.06-.06a1.65 1.65 0 00-1.82-.33 1.65 1.65 0 00-1 1.51V21a2 2 0 01-4 0v-.09A1.65 1.65 0 009.6 19.4a1.65 1.65 0 00-1.82.33l-.06.06a2 2 0 11-2.83-2.83l.06-.06a1.65 1.65 0 00.33-1.82 1.65 1.65 0 00-1.51-1H3a2 2 0 010-4h.09A1.65 1.65 0 004.6 8.6a1.65 1.65 0 00-.33-1.82l-.06-.06a2 2 0 112.83-2.83l.06.06a1.65 1.65 0 001.82.33H9a1.65 1.65 0 001-1.51V3a2 2 0 014 0v.09a1.65 1.65 0 001 1.51 1.65 1.65 0 001.82-.33l.06-.06a2 2 0 112.83 2.83l-.06.06a1.65 1.65 0 00-.33 1.82V9c.51.19 1.19.51 1.51 1H21a2 2 0 010 4h-.09a1.65 1.65 0 00-1.51 1z"/></svg>
        Settings
      </a>
    </nav>

    <div class="mt-6 border-t border-border pt-4">
      <div class="flex items-center gap-3 px-1">
        <div class="flex h-9 w-9 shrink-0 items-center justify-center rounded-full bg-surface-raised border border-border font-display text-sm font-semibold text-ink">
          {{ current_user.name[:1]|upper }}
        </div>
        <div class="min-w-0 flex-1">
          <p class="truncate text-sm font-medium text-ink">{{ current_user.name }}</p>
          <p class="truncate text-xs text-ink-muted">{{ current_user.email }}</p>
        </div>
        <button id="view-mode-trigger-desktop" type="button" class="btn-ghost !px-2" title="Display" aria-label="Change display mode">
          <svg xmlns="http://www.w3.org/2000/svg" class="h-[18px] w-[18px]" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="2" y="4" width="20" height="13" rx="1.5"/><line x1="8" y1="21" x2="16" y2="21"/><line x1="12" y1="17" x2="12" y2="21"/></svg>
        </button>
        <a href="{{ url_for('auth.logout') }}" class="btn-ghost !px-2" title="Sign out" aria-label="Sign out">
          <svg xmlns="http://www.w3.org/2000/svg" class="h-[18px] w-[18px]" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M9 21H5a2 2 0 01-2-2V5a2 2 0 012-2h4"/><polyline points="16 17 21 12 16 7"/><line x1="21" y1="12" x2="9" y2="12"/></svg>
        </a>
      </div>
    </div>
  </aside>

  <div id="sidebar-backdrop" class="fixed inset-0 z-30 hidden bg-black/50 lg:hidden"></div>

  <!-- Content -->
  <main class="vm-main flex-1 min-w-0 px-4 py-6 sm:px-6 lg:px-10 lg:py-10">
    <div class="mx-auto max-w-6xl">
      {% include "partials/flash.html" %}
      {% block page_content %}{% endblock %}
    </div>
  </main>
</div>

{% include "partials/view_mode_modal.html" %}
{% endblock %}
CLAUDE_PATCH_EOF

mkdir -p "$APP_DIR/app/templates/partials"
cat > "$APP_DIR/app/templates/partials/flash.html" << 'CLAUDE_PATCH_EOF'
{% with messages = get_flashed_messages(with_categories=true) %}
  {% if messages %}
    {% set groups = [] %}
    {% for category, message in messages %}
      {% if groups and groups[-1].category == category %}
        {% set _ = groups[-1].msgs.append(message) %}
      {% else %}
        {% set _ = groups.append({'category': category, 'msgs': [message]}) %}
      {% endif %}
    {% endfor %}

    {% set styles = {
      'error': 'border-status-busy/30 bg-status-busy/10 text-status-busy',
      'success': 'border-status-available/30 bg-status-available/10 text-status-available',
      'info': 'border-border bg-surface-raised text-ink-muted',
    } %}
    {% set headings = {
      'error': 'Couldn\u2019t save everything',
      'success': 'Done',
      'info': 'Heads up',
    } %}

    <div class="mb-6 space-y-2">
      {% for g in groups %}
        <div class="rounded-lg border px-4 py-3 text-sm {{ styles.get(g.category, styles['info']) }}">
          {% if g.msgs|length == 1 %}
            <div class="flex items-start gap-2.5">
              <span class="mt-0.5 status-dot bg-current shrink-0"></span>
              <span>{{ g.msgs[0] }}</span>
            </div>
          {% else %}
            <div class="flex items-start gap-2.5 font-medium mb-1.5">
              <span class="mt-0.5 status-dot bg-current shrink-0"></span>
              <span>{{ headings.get(g.category, headings['info']) }} &mdash; {{ g.msgs|length }} item{{ 's' if g.msgs|length != 1 }}</span>
            </div>
            <ul class="ml-5 list-disc space-y-1">
              {% for m in g.msgs %}<li>{{ m }}</li>{% endfor %}
            </ul>
          {% endif %}
        </div>
      {% endfor %}
    </div>
  {% endif %}
{% endwith %}
CLAUDE_PATCH_EOF

mkdir -p "$APP_DIR/app/templates/partials"
cat > "$APP_DIR/app/templates/partials/view_mode_modal.html" << 'CLAUDE_PATCH_EOF'
<div id="view-mode-modal" class="fixed inset-0 z-50 hidden items-center justify-center bg-black/60 backdrop-blur-sm p-4">
  <div class="card w-full max-w-md p-6 sm:p-8">
    <div class="flex items-center gap-2.5 mb-1">
      <span class="status-dot bg-accent"></span>
      <p class="text-xs font-semibold uppercase tracking-wider text-ink-muted">Display</p>
    </div>
    <h2 class="font-display text-xl font-semibold text-ink mb-1.5">How do you want this to look?</h2>
    <p class="text-sm text-ink-muted mb-6">
      Choose a layout for this browser. You can change it any time from the
      "Display" button in the menu.
    </p>

    <div class="grid grid-cols-1 gap-2.5">
      <button type="button" data-view-choice="auto" class="view-mode-option group flex items-center gap-3.5 rounded-lg border border-border bg-surface-raised px-4 py-3.5 text-left hover:border-accent transition-colors">
        <svg xmlns="http://www.w3.org/2000/svg" class="h-5 w-5 shrink-0 text-ink-muted group-hover:text-accent" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 12a9 9 0 11-9-9c2.5 0 4.7 1 6.3 2.7M21 3v6h-6"/></svg>
        <span class="min-w-0 flex-1">
          <span class="block text-sm font-medium text-ink">Auto <span class="font-normal text-ink-faint">(recommended)</span></span>
          <span class="block text-xs text-ink-muted">Adapts to whatever screen you're using</span>
        </span>
      </button>

      <button type="button" data-view-choice="desktop" class="view-mode-option group flex items-center gap-3.5 rounded-lg border border-border bg-surface-raised px-4 py-3.5 text-left hover:border-accent transition-colors">
        <svg xmlns="http://www.w3.org/2000/svg" class="h-5 w-5 shrink-0 text-ink-muted group-hover:text-accent" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="2" y="4" width="20" height="13" rx="1.5"/><line x1="8" y1="21" x2="16" y2="21"/><line x1="12" y1="17" x2="12" y2="21"/></svg>
        <span class="min-w-0 flex-1">
          <span class="block text-sm font-medium text-ink">Desktop</span>
          <span class="block text-xs text-ink-muted">Sidebar always visible, wide layout</span>
        </span>
      </button>

      <button type="button" data-view-choice="tablet" class="view-mode-option group flex items-center gap-3.5 rounded-lg border border-border bg-surface-raised px-4 py-3.5 text-left hover:border-accent transition-colors">
        <svg xmlns="http://www.w3.org/2000/svg" class="h-5 w-5 shrink-0 text-ink-muted group-hover:text-accent" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="4" y="2" width="16" height="20" rx="2"/><line x1="10" y1="19" x2="14" y2="19"/></svg>
        <span class="min-w-0 flex-1">
          <span class="block text-sm font-medium text-ink">Tablet</span>
          <span class="block text-xs text-ink-muted">Centered column, bigger touch targets</span>
        </span>
      </button>

      <button type="button" data-view-choice="mobile" class="view-mode-option group flex items-center gap-3.5 rounded-lg border border-border bg-surface-raised px-4 py-3.5 text-left hover:border-accent transition-colors">
        <svg xmlns="http://www.w3.org/2000/svg" class="h-5 w-5 shrink-0 text-ink-muted group-hover:text-accent" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="7" y="2" width="10" height="20" rx="2"/><line x1="12" y1="18" x2="12.01" y2="18"/></svg>
        <span class="min-w-0 flex-1">
          <span class="block text-sm font-medium text-ink">Mobile</span>
          <span class="block text-xs text-ink-muted">Compact single column, menu tucked away</span>
        </span>
      </button>
    </div>

    <button type="button" id="view-mode-dismiss" class="mt-5 w-full text-center text-xs text-ink-faint hover:text-ink-muted">
      Skip — decide later
    </button>
  </div>
</div>
CLAUDE_PATCH_EOF

mkdir -p "$APP_DIR/app/templates/admin"
cat > "$APP_DIR/app/templates/admin/availability.html" << 'CLAUDE_PATCH_EOF'
{% extends "layouts/admin.html" %}
{% block title %}Availability · {{ app_name }}{% endblock %}
{% block page_content %}

<div class="mb-8 flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
  <div>
    <h1 class="font-display text-2xl font-semibold text-ink">Availability</h1>
    <p class="mt-1 text-sm text-ink-muted">Set which days you work, your hours, and any recurring breaks.</p>
    <p class="mt-1 text-xs text-ink-faint">Tip: set end time to 00:00 to mean midnight — working until the end of the day.</p>
  </div>
  <button
    type="submit"
    form="working-hours-form"
    class="btn-primary hidden sm:inline-flex shrink-0"
  >
    Save working hours
  </button>
</div>

<div class="card p-4 sm:p-5 mb-6 flex items-start gap-3">
  <span class="status-dot bg-ink-faint mt-1.5 shrink-0"></span>
  <p class="text-sm text-ink-muted">
    Anything outside the hours below — evenings, before opening, days you've
    left off entirely — counts as <span class="text-ink font-medium">out of hours</span>
    and is never offered as a booking slot. This page sets your normal
    <span class="text-ink font-medium">recurring weekly</span> pattern; for
    one-off exceptions on top of it — a holiday, a single day off, a
    half-day — use
    <a href="{{ url_for('admin.time_off') }}" class="text-accent hover:underline">Time Off</a>
    instead. They're kept separate so a single holiday doesn't require
    editing (and un-editing) your whole weekly schedule.
  </p>
</div>

<form id="working-hours-form"
      method="POST"
      action="{{ url_for('admin.availability') }}">
  {{ csrf_form.hidden_tag() }}
</form>

{% set weekday_labels = {0: 'Weekdays', 5: 'Weekend'} %}

<div class="space-y-8">
  {% for wh in working_hours %}
  {% if wh.day_of_week in weekday_labels %}
  <p class="text-[11px] font-semibold uppercase tracking-wider text-ink-faint {{ 'mt-2' if wh.day_of_week != 0 }}">
    {{ weekday_labels[wh.day_of_week] }}
  </p>
  {% endif %}

  {% set fs = form_state[wh.day_of_week] if form_state and wh.day_of_week in form_state else None %}
  {% set day_enabled = fs.enabled if fs else wh.enabled %}
  {% set day_start = fs.start if (fs and fs.start) else (wh.start_time.strftime('%H:%M') if wh.start_time else '09:00') %}
  {% set day_end = fs.end if (fs and fs.end) else (wh.end_time.strftime('%H:%M') if wh.end_time else '17:00') %}

  <div class="card p-5 sm:p-6{{ ' mt-3' if wh.day_of_week in weekday_labels else '' }}">
    <div class="flex flex-col gap-4 sm:flex-row sm:items-center">
      <label class="flex w-40 shrink-0 items-center gap-3">
        <span class="{{ 'day-badge-on' if day_enabled else 'day-badge' }}">{{ wh.day_name[:2] }}</span>
        <span class="min-w-0">
          <span class="block font-medium text-ink">{{ wh.day_name }}</span>
          <span class="block text-xs {{ 'text-accent' if day_enabled else 'text-ink-faint' }}">
            {{ 'Working' if day_enabled else 'Day off' }}
          </span>
        </span>
        <input
          type="checkbox"
          form="working-hours-form"
          name="day_{{ wh.day_of_week }}_enabled"
          {{ 'checked' if day_enabled }}
          class="ml-auto h-4 w-4 rounded border-border bg-surface-raised text-accent focus:ring-accent focus:ring-offset-base day-toggle"
          data-day="{{ wh.day_of_week }}"
        >
      </label>

      <div
        class="flex flex-1 flex-wrap items-center gap-3"
        id="day-{{ wh.day_of_week }}-times"
      >
        <input
          type="time"
          form="working-hours-form"
          name="day_{{ wh.day_of_week }}_start"
          value="{{ day_start }}"
          class="field-input w-32"
          {{ 'disabled' if not day_enabled }}
        >

        <span class="text-ink-faint">to</span>

        <input
          type="time"
          form="working-hours-form"
          name="day_{{ wh.day_of_week }}_end"
          value="{{ day_end }}"
          class="field-input w-32"
          {{ 'disabled' if not day_enabled }}
        >
      </div>
    </div>

    {% if wh.breaks %}
    <div class="mt-4 ml-0 sm:ml-[8.25rem] flex flex-wrap gap-2">
      {% for b in wh.breaks %}
      <span class="inline-flex items-center gap-2 rounded-full border border-border bg-surface-raised pl-3 pr-1.5 py-1 text-xs text-ink-muted">
        {{ b.label }} · {{ b.start_time.strftime('%H:%M') }}–{{ b.end_time.strftime('%H:%M') }}
        <form
          method="POST"
          action="{{ url_for('admin.delete_break', break_id=b.id) }}"
          class="inline"
        >
          {{ csrf_form.hidden_tag() }}
          <button
            type="submit"
            class="flex h-4 w-4 items-center justify-center rounded-full text-ink-faint hover:text-status-busy hover:bg-status-busy/10"
            aria-label="Remove break"
          >
            <svg xmlns="http://www.w3.org/2000/svg" class="h-2.5 w-2.5" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>
          </button>
        </form>
      </span>
      {% endfor %}
    </div>
    {% endif %}

    <details class="mt-3 ml-0 sm:ml-[8.25rem]">
      <summary class="cursor-pointer text-sm font-medium text-accent hover:underline w-fit">
        + Add a break
      </summary>

      <form
        method="POST"
        action="{{ url_for('admin.add_break') }}"
        class="mt-3 flex flex-wrap items-end gap-3"
      >
        {{ break_form.hidden_tag() }}

        <input
          type="hidden"
          name="day_of_week"
          value="{{ wh.day_of_week }}"
        >

        <div>
          <label class="field-label">Label</label>
          <input
            type="text"
            name="label"
            placeholder="Lunch"
            class="field-input w-32"
          >
        </div>

        <div>
          <label class="field-label">Starts</label>
          <input
            type="time"
            name="start_time"
            value="12:00"
            class="field-input w-28"
          >
        </div>

        <div>
          <label class="field-label">Ends</label>
          <input
            type="time"
            name="end_time"
            value="13:00"
            class="field-input w-28"
          >
        </div>

        <button type="submit" class="btn-secondary">
          Add break
        </button>
      </form>
    </details>
  </div>
  {% endfor %}
</div>

<div class="mt-6 sm:hidden">
  <button
    type="submit"
    form="working-hours-form"
    class="btn-primary w-full"
  >
    Save working hours
  </button>
</div>

<script>
  document.querySelectorAll(".day-toggle").forEach((toggle) => {
    toggle.addEventListener("change", () => {
      const day = toggle.dataset.day;
      const inputs = document.querySelectorAll(`#day-${day}-times input`);

      inputs.forEach((input) => {
        input.disabled = !toggle.checked;
      });
    });
  });
</script>

{% endblock %}
CLAUDE_PATCH_EOF

mkdir -p "$APP_DIR/app/templates/admin"
cat > "$APP_DIR/app/templates/admin/isp_support_list.html" << 'CLAUDE_PATCH_EOF'
{% extends "layouts/admin.html" %}
{% block title %}ISP Support · {{ app_name }}{% endblock %}
{% block page_content %}

<div class="mb-8">
  <h1 class="font-display text-2xl font-semibold text-ink">ISP Support Requests</h1>
  <p class="mt-1 text-sm text-ink-muted">Customer authorisations to contact their ISP on their behalf.</p>
</div>

<div class="mb-5 flex flex-wrap gap-2">
  <a href="{{ url_for('isp_support.admin_list') }}" class="{{ 'btn-secondary' if status_filter else 'btn-primary' }} !py-1.5 !px-3 text-xs">All</a>
  {% for s in statuses %}
  <a href="{{ url_for('isp_support.admin_list', status=s) }}" class="{{ 'btn-primary' if status_filter == s else 'btn-secondary' }} !py-1.5 !px-3 text-xs capitalize">{{ s }}</a>
  {% endfor %}
</div>

{% if requests %}
<div class="card divide-y divide-border">
  {% for r in requests %}
  <a href="{{ url_for('isp_support.admin_detail', request_id=r.id) }}" class="flex items-center justify-between gap-4 p-4 sm:p-5 hover:bg-surface-raised transition-colors">
    <div class="min-w-0">
      <p class="font-medium text-ink truncate">{{ r.full_name }} &middot; {{ r.isp_name }}</p>
      <p class="mt-0.5 text-xs text-ink-muted truncate">{{ r.problem_description }}</p>
    </div>
    <div class="flex items-center gap-3 shrink-0">
      <span class="status-pill !py-1 !px-2.5 text-xs border-border bg-surface-raised text-ink-muted">{{ r.status_label }}</span>
      <span class="text-xs text-ink-faint">{{ r.submitted_at.strftime('%d %b %Y') }}</span>
    </div>
  </a>
  {% endfor %}
</div>
{% else %}
<div class="card p-8 text-center">
  <p class="text-sm text-ink-muted">No requests{{ ' with that status' if status_filter else '' }} yet.</p>
</div>
{% endif %}

{% endblock %}
CLAUDE_PATCH_EOF

mkdir -p "$APP_DIR/app/templates/admin"
cat > "$APP_DIR/app/templates/admin/isp_support_detail.html" << 'CLAUDE_PATCH_EOF'
{% extends "layouts/admin.html" %}
{% block title %}{{ req.full_name }} · ISP Support · {{ app_name }}{% endblock %}
{% block page_content %}

<a href="{{ url_for('isp_support.admin_list') }}" class="text-sm text-ink-muted hover:text-ink">&larr; All requests</a>

<div class="mt-4 mb-8 flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
  <div>
    <h1 class="font-display text-2xl font-semibold text-ink">{{ req.full_name }}</h1>
    <p class="mt-1 text-sm text-ink-muted">{{ req.isp_name }} &middot; submitted {{ req.submitted_at.strftime('%d %b %Y at %H:%M') }}</p>
  </div>
  <span class="status-pill !py-1.5 !px-3 text-xs border-border bg-surface-raised text-ink-muted shrink-0">{{ req.status_label }}</span>
</div>

<div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
  <div class="lg:col-span-2 space-y-6">
    <div class="card p-5 sm:p-6">
      <p class="text-[11px] font-semibold uppercase tracking-wider text-ink-faint mb-3">Problem</p>
      <p class="text-sm text-ink whitespace-pre-line">{{ req.problem_description }}</p>
    </div>

    <div class="card p-5 sm:p-6">
      <p class="text-[11px] font-semibold uppercase tracking-wider text-ink-faint mb-3">Contact</p>
      <dl class="grid grid-cols-1 sm:grid-cols-2 gap-x-4 gap-y-3 text-sm">
        <div><dt class="text-ink-faint text-xs">Email</dt><dd class="text-ink">{{ req.email or '—' }}</dd></div>
        <div><dt class="text-ink-faint text-xs">Phone</dt><dd class="text-ink">{{ req.phone or '—' }}</dd></div>
      </dl>
    </div>

    {% if req.account_number or req.customer_number or req.full_address or req.service_address or req.date_of_birth or req.last_bill_date or req.last_bill_amount %}
    <div class="card p-5 sm:p-6">
      <p class="text-[11px] font-semibold uppercase tracking-wider text-ink-faint mb-3">Account verification details</p>
      <dl class="grid grid-cols-1 sm:grid-cols-2 gap-x-4 gap-y-3 text-sm">
        {% if req.account_number %}<div><dt class="text-ink-faint text-xs">Account number</dt><dd class="text-ink">{{ req.account_number }}</dd></div>{% endif %}
        {% if req.customer_number %}<div><dt class="text-ink-faint text-xs">Customer number</dt><dd class="text-ink">{{ req.customer_number }}</dd></div>{% endif %}
        {% if req.full_address %}<div class="sm:col-span-2"><dt class="text-ink-faint text-xs">Full address</dt><dd class="text-ink">{{ req.full_address }}</dd></div>{% endif %}
        {% if req.service_address %}<div class="sm:col-span-2"><dt class="text-ink-faint text-xs">Service address</dt><dd class="text-ink">{{ req.service_address }}</dd></div>{% endif %}
        {% if req.date_of_birth %}<div><dt class="text-ink-faint text-xs">Date of birth</dt><dd class="text-ink">{{ req.date_of_birth }}</dd></div>{% endif %}
        {% if req.last_bill_date %}<div><dt class="text-ink-faint text-xs">Last bill date</dt><dd class="text-ink">{{ req.last_bill_date }}</dd></div>{% endif %}
        {% if req.last_bill_amount %}<div><dt class="text-ink-faint text-xs">Last bill amount</dt><dd class="text-ink">{{ req.last_bill_amount }}</dd></div>{% endif %}
      </dl>
    </div>
    {% endif %}

    {% if req.mothers_maiden_name or req.childhood_nickname or req.security_question or req.security_answer or req.other_security_info %}
    <div class="card p-5 sm:p-6">
      <p class="text-[11px] font-semibold uppercase tracking-wider text-ink-faint mb-3">Security questions</p>
      <dl class="grid grid-cols-1 sm:grid-cols-2 gap-x-4 gap-y-3 text-sm">
        {% if req.mothers_maiden_name %}<div><dt class="text-ink-faint text-xs">Mother's maiden name</dt><dd class="text-ink">{{ req.mothers_maiden_name }}</dd></div>{% endif %}
        {% if req.childhood_nickname %}<div><dt class="text-ink-faint text-xs">Childhood nickname</dt><dd class="text-ink">{{ req.childhood_nickname }}</dd></div>{% endif %}
        {% if req.security_question %}<div class="sm:col-span-2"><dt class="text-ink-faint text-xs">Security question</dt><dd class="text-ink">{{ req.security_question }}</dd></div>{% endif %}
        {% if req.security_answer %}<div class="sm:col-span-2"><dt class="text-ink-faint text-xs">Answer</dt><dd class="text-ink">{{ req.security_answer }}</dd></div>{% endif %}
        {% if req.other_security_info %}<div class="sm:col-span-2"><dt class="text-ink-faint text-xs">Other security info</dt><dd class="text-ink whitespace-pre-line">{{ req.other_security_info }}</dd></div>{% endif %}
      </dl>
    </div>
    {% endif %}

    <div class="card p-5 sm:p-6">
      <p class="text-[11px] font-semibold uppercase tracking-wider text-ink-faint mb-3">Authorisation given</p>
      <ul class="space-y-1.5 text-sm text-ink-muted">
        <li class="flex items-center gap-2"><span class="status-dot {{ 'bg-status-available' if req.consent_authorised else 'bg-ink-faint' }}"></span> Authorised to provide this information</li>
        <li class="flex items-center gap-2"><span class="status-dot {{ 'bg-status-available' if req.consent_accurate else 'bg-ink-faint' }}"></span> Confirmed information is accurate</li>
        <li class="flex items-center gap-2"><span class="status-dot {{ 'bg-status-available' if req.consent_purpose else 'bg-ink-faint' }}"></span> Consented to use solely for contacting the ISP</li>
        <li class="flex items-center gap-2"><span class="status-dot {{ 'bg-status-available' if req.consent_additional_verification else 'bg-ink-faint' }}"></span> Understands additional verification may be needed</li>
        <li class="flex items-center gap-2"><span class="status-dot {{ 'bg-status-available' if req.consent_no_password_request else 'bg-ink-faint' }}"></span> Understands no password/OTP will ever be requested</li>
      </ul>
    </div>
  </div>

  <div class="space-y-6">
    <div class="card p-5 sm:p-6">
      <p class="text-[11px] font-semibold uppercase tracking-wider text-ink-faint mb-3">Update status</p>
      <form method="POST" action="{{ url_for('isp_support.admin_detail', request_id=req.id) }}" class="space-y-3">
        {{ status_form.hidden_tag() }}
        <div>
          {{ status_form.status(class_="field-input") }}
        </div>
        <div>
          <label class="field-label">Internal notes</label>
          {{ status_form.admin_notes(class_="field-input", rows=4, placeholder="Not shown to the customer") }}
        </div>
        <button type="submit" class="btn-primary w-full">Save</button>
      </form>
    </div>

    <div class="card p-5 sm:p-6">
      <p class="text-[11px] font-semibold uppercase tracking-wider text-ink-faint mb-3">Access log</p>
      {% if recent_access %}
      <ul class="space-y-2 text-xs text-ink-muted">
        {% for log in recent_access %}
        <li class="flex items-center justify-between gap-2">
          <span class="truncate">{{ log.user.name if log.user else 'Unknown' }}</span>
          <span class="text-ink-faint shrink-0">{{ log.accessed_at.strftime('%d %b, %H:%M') }}</span>
        </li>
        {% endfor %}
      </ul>
      {% else %}
      <p class="text-xs text-ink-faint">No access recorded yet.</p>
      {% endif %}
    </div>

    <div class="card p-5 sm:p-6">
      <p class="text-[11px] font-semibold uppercase tracking-wider text-ink-faint mb-3">Danger zone</p>
      <form method="POST" action="{{ url_for('isp_support.admin_delete', request_id=req.id) }}" onsubmit="return confirm('Permanently delete this request and all its data?');">
        {{ delete_form.hidden_tag() }}
        <button type="submit" class="btn-danger w-full">Delete request</button>
      </form>
    </div>
  </div>
</div>

{% endblock %}
CLAUDE_PATCH_EOF

mkdir -p "$APP_DIR/app/templates/public"
cat > "$APP_DIR/app/templates/public/isp_support_form.html" << 'CLAUDE_PATCH_EOF'
{% extends "base.html" %}
{% block title %}ISP Support Request · {{ app_name }}{% endblock %}
{% block body %}
<div class="mx-auto max-w-2xl px-4 py-12 sm:py-16">
  <div class="mb-8">
    <h1 class="font-display text-2xl font-semibold text-ink">ISP Support &amp; Customer Authorisation</h1>
    <p class="mt-2 text-sm text-ink-muted">
      If you're having an internet service problem I can't resolve myself, I may be able to
      contact your Internet Service Provider (ISP) on your behalf. To do that I need enough
      information to identify your account and for your ISP to discuss it with me.
    </p>
  </div>

  {% include "partials/flash.html" %}

  <div class="card p-5 sm:p-6 mb-6 text-sm text-ink-muted leading-relaxed space-y-2">
    <p class="font-medium text-ink">Please only fill in what your ISP has actually asked for.</p>
    <p>
      Full name, your ISP's name, and a description of the problem are the only required fields
      below. Everything else — account numbers, date of birth, security questions, billing
      details — should only be filled in if your specific ISP requires it for this request.
      If you're not sure what's needed, leave it blank and contact your ISP first.
    </p>
    <p>
      <strong class="text-ink">Never enter your ISP password, online banking details, payment-card
      security information, or one-time verification codes anywhere on this form.</strong>
      I will never ask you for these. If your ISP needs to send you a verification code, you'll
      need to be available to complete that step yourself directly with them.
    </p>
  </div>

  <form method="POST" action="{{ url_for('isp_support.request_form') }}" class="card p-5 sm:p-6 space-y-6">
    {{ form.hidden_tag() }}

    <div class="space-y-4">
      <p class="text-[11px] font-semibold uppercase tracking-wider text-ink-faint">Your details</p>

      <div>
        <label class="field-label" for="{{ form.full_name.id }}">{{ form.full_name.label.text }}</label>
        {{ form.full_name(class_="field-input") }}
        {% for e in form.full_name.errors %}<p class="field-error">{{ e }}</p>{% endfor %}
      </div>

      <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
        <div>
          <label class="field-label" for="{{ form.email.id }}">{{ form.email.label.text }}</label>
          {{ form.email(class_="field-input") }}
          {% for e in form.email.errors %}<p class="field-error">{{ e }}</p>{% endfor %}
        </div>
        <div>
          <label class="field-label" for="{{ form.phone.id }}">{{ form.phone.label.text }}</label>
          {{ form.phone(class_="field-input") }}
        </div>
      </div>

      <div>
        <label class="field-label" for="{{ form.isp_name.id }}">{{ form.isp_name.label.text }}</label>
        {{ form.isp_name(class_="field-input") }}
        {% for e in form.isp_name.errors %}<p class="field-error">{{ e }}</p>{% endfor %}
      </div>

      <div>
        <label class="field-label" for="{{ form.problem_description.id }}">{{ form.problem_description.label.text }}</label>
        {{ form.problem_description(class_="field-input min-h-[120px]", rows=4) }}
        {% for e in form.problem_description.errors %}<p class="field-error">{{ e }}</p>{% endfor %}
      </div>
    </div>

    <details class="border-t border-border pt-4">
      <summary class="cursor-pointer text-sm font-medium text-accent hover:underline w-fit">
        My ISP has asked for account verification details
      </summary>
      <div class="mt-4 space-y-4">
        <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
          <div>
            <label class="field-label" for="{{ form.account_number.id }}">{{ form.account_number.label.text }}</label>
            {{ form.account_number(class_="field-input") }}
          </div>
          <div>
            <label class="field-label" for="{{ form.customer_number.id }}">{{ form.customer_number.label.text }}</label>
            {{ form.customer_number(class_="field-input") }}
          </div>
        </div>

        <div>
          <label class="field-label" for="{{ form.full_address.id }}">{{ form.full_address.label.text }}</label>
          {{ form.full_address(class_="field-input") }}
        </div>
        <div>
          <label class="field-label" for="{{ form.service_address.id }}">{{ form.service_address.label.text }}</label>
          {{ form.service_address(class_="field-input") }}
        </div>

        <div class="grid grid-cols-1 sm:grid-cols-3 gap-4">
          <div>
            <label class="field-label" for="{{ form.date_of_birth.id }}">{{ form.date_of_birth.label.text }}</label>
            {{ form.date_of_birth(class_="field-input") }}
          </div>
          <div>
            <label class="field-label" for="{{ form.last_bill_date.id }}">{{ form.last_bill_date.label.text }}</label>
            {{ form.last_bill_date(class_="field-input") }}
          </div>
          <div>
            <label class="field-label" for="{{ form.last_bill_amount.id }}">{{ form.last_bill_amount.label.text }}</label>
            {{ form.last_bill_amount(class_="field-input") }}
          </div>
        </div>
      </div>
    </details>

    <details class="border-t border-border pt-4">
      <summary class="cursor-pointer text-sm font-medium text-accent hover:underline w-fit">
        My ISP has asked for a security question
      </summary>
      <div class="mt-4 space-y-4">
        <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
          <div>
            <label class="field-label" for="{{ form.mothers_maiden_name.id }}">{{ form.mothers_maiden_name.label.text }}</label>
            {{ form.mothers_maiden_name(class_="field-input") }}
          </div>
          <div>
            <label class="field-label" for="{{ form.childhood_nickname.id }}">{{ form.childhood_nickname.label.text }}</label>
            {{ form.childhood_nickname(class_="field-input") }}
          </div>
        </div>
        <div>
          <label class="field-label" for="{{ form.security_question.id }}">{{ form.security_question.label.text }}</label>
          {{ form.security_question(class_="field-input") }}
        </div>
        <div>
          <label class="field-label" for="{{ form.security_answer.id }}">{{ form.security_answer.label.text }}</label>
          {{ form.security_answer(class_="field-input") }}
        </div>
        <div>
          <label class="field-label" for="{{ form.other_security_info.id }}">{{ form.other_security_info.label.text }}</label>
          {{ form.other_security_info(class_="field-input", rows=3) }}
        </div>
      </div>
    </details>

    <div class="border-t border-border pt-4 space-y-3">
      <p class="text-[11px] font-semibold uppercase tracking-wider text-ink-faint">Authorisation</p>

      {% for field in [form.consent_authorised, form.consent_accurate, form.consent_purpose, form.consent_additional_verification, form.consent_no_password_request] %}
      <label class="flex items-start gap-3 text-sm text-ink-muted">
        {{ field(class_="mt-0.5 h-4 w-4 rounded border-border bg-surface-raised text-accent focus:ring-accent focus:ring-offset-base shrink-0") }}
        <span>{{ field.label.text }}</span>
      </label>
      {% for e in field.errors %}<p class="field-error ml-7">{{ e }}</p>{% endfor %}
      {% endfor %}
    </div>

    <button type="submit" class="btn-primary w-full">Submit request</button>
  </form>

  <p class="mt-6 text-center text-xs text-ink-faint">
    Read the full <a href="{{ url_for('isp_support.thank_you') }}#privacy" class="underline hover:text-ink-muted">privacy notice</a>
    for what's collected, why, and how to request deletion.
  </p>
</div>
{% endblock %}
CLAUDE_PATCH_EOF

mkdir -p "$APP_DIR/app/templates/public"
cat > "$APP_DIR/app/templates/public/isp_support_thanks.html" << 'CLAUDE_PATCH_EOF'
{% extends "base.html" %}
{% block title %}Request received · {{ app_name }}{% endblock %}
{% block body %}
<div class="mx-auto max-w-2xl px-4 py-12 sm:py-16">
  <div class="card p-6 sm:p-8 text-center mb-10">
    <span class="status-dot bg-status-available inline-block mb-3"></span>
    <h1 class="font-display text-2xl font-semibold text-ink">Request received</h1>
    <p class="mt-2 text-sm text-ink-muted">
      Thanks — I'll review what you've sent and be in touch about next steps. If your ISP
      needs you to complete verification yourself (for example a text or email code), I'll
      let you know so we can arrange a time.
    </p>
  </div>

  <div id="privacy" class="space-y-6 text-sm text-ink-muted leading-relaxed">
    <h2 class="font-display text-lg font-semibold text-ink">Privacy notice</h2>

    <div>
      <h3 class="font-medium text-ink mb-1">What we collect and why</h3>
      <p>
        We collect only the account-verification details your ISP specifically requires to
        discuss your account with us — for example your account number, full name, or a
        security question your ISP uses. We never ask for your ISP password, online banking
        details, payment-card security information, or one-time verification codes.
      </p>
    </div>

    <div>
      <h3 class="font-medium text-ink mb-1">How it's protected</h3>
      <p>
        The form is served over an encrypted (HTTPS) connection. Sensitive fields — account and
        customer numbers, date of birth, address, and any security question answers — are
        encrypted at rest in our database, separately from the rest of the record. Access to
        your request is limited to staff who need it to help with your issue, and every time
        someone opens your request it's recorded in an access log.
      </p>
    </div>

    <div>
      <h3 class="font-medium text-ink mb-1">How long we keep it</h3>
      <p>
        Requests are kept only as long as needed to resolve your issue and for a reasonable
        period afterwards in case the same problem recurs. You can ask us to delete your
        request at any time using the contact details you submitted it through.
      </p>
    </div>

    <div>
      <h3 class="font-medium text-ink mb-1">Who can access it</h3>
      <p>
        Only staff handling ISP support requests can view submitted information, and only for
        the purpose of contacting your ISP and assisting with your issue.
      </p>
    </div>

    <div>
      <h3 class="font-medium text-ink mb-1">Your rights</h3>
      <p>
        You can request a copy of the information we hold about your request, ask us to
        correct it, or ask us to delete it, subject to any legal requirement to keep records.
      </p>
    </div>
  </div>

  <div class="mt-10 text-center">
    <a href="{{ url_for('isp_support.request_form') }}" class="text-sm text-accent hover:underline">&larr; Back to the form</a>
  </div>
</div>
{% endblock %}
CLAUDE_PATCH_EOF

mkdir -p "$APP_DIR/app/static/js"
cat > "$APP_DIR/app/static/js/app.js" << 'CLAUDE_PATCH_EOF'
(function () {
  const sidebar = document.getElementById("sidebar");
  const backdrop = document.getElementById("sidebar-backdrop");
  const openBtn = document.getElementById("nav-toggle");
  const closeBtn = document.getElementById("nav-close");

  if (!sidebar || !backdrop || !openBtn) return;

  function openNav() {
    sidebar.classList.remove("-translate-x-full");
    sidebar.classList.add("vm-open");
    backdrop.classList.remove("hidden");
    openBtn.setAttribute("aria-expanded", "true");
  }

  function closeNav() {
    sidebar.classList.add("-translate-x-full");
    sidebar.classList.remove("vm-open");
    backdrop.classList.add("hidden");
    openBtn.setAttribute("aria-expanded", "false");
  }

  openBtn.addEventListener("click", openNav);
  closeBtn && closeBtn.addEventListener("click", closeNav);
  backdrop.addEventListener("click", closeNav);
  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape") closeNav();
  });
})();

// --- Display mode (desktop / tablet / mobile) ---
// Lets someone force a layout for this browser regardless of actual screen
// size — offered as a one-time splash on first visit, and reachable any
// time after via the "Display" button in the topbar / sidebar.
(function () {
  const STORAGE_KEY = "schedulerViewMode";
  const modal = document.getElementById("view-mode-modal");
  if (!modal) return;

  const triggers = [
    document.getElementById("view-mode-trigger"),
    document.getElementById("view-mode-trigger-desktop"),
  ].filter(Boolean);
  const dismissBtn = document.getElementById("view-mode-dismiss");
  const options = modal.querySelectorAll(".view-mode-option");

  function currentChoice() {
    try {
      return localStorage.getItem(STORAGE_KEY);
    } catch (e) {
      return null;
    }
  }

  function applyChoice(value) {
    if (value && value !== "auto") {
      document.documentElement.setAttribute("data-view", value);
    } else {
      document.documentElement.removeAttribute("data-view");
    }
  }

  function saveChoice(value) {
    try {
      localStorage.setItem(STORAGE_KEY, value);
    } catch (e) {}
    applyChoice(value);
  }

  function openModal() {
    modal.classList.remove("hidden");
    modal.classList.add("flex");
  }

  function closeModal() {
    modal.classList.add("hidden");
    modal.classList.remove("flex");
  }

  options.forEach((btn) => {
    btn.addEventListener("click", () => {
      saveChoice(btn.dataset.viewChoice);
      closeModal();
    });
  });

  dismissBtn && dismissBtn.addEventListener("click", () => {
    try {
      localStorage.setItem(STORAGE_KEY, "auto");
    } catch (e) {}
    closeModal();
  });

  triggers.forEach((btn) => btn.addEventListener("click", openModal));

  modal.addEventListener("click", (e) => {
    if (e.target === modal) closeModal();
  });
  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape") closeModal();
  });

  // First-ever visit: nothing saved yet — show the splash.
  if (currentChoice() === null) {
    openModal();
  }
})();
CLAUDE_PATCH_EOF

mkdir -p "$APP_DIR/app/static/css"
cat > "$APP_DIR/app/static/css/input.css" << 'CLAUDE_PATCH_EOF'
@tailwind base;
@tailwind components;
@tailwind utilities;

@layer base {
  html {
    @apply scroll-smooth;
  }
  body {
    @apply bg-base text-ink font-sans antialiased;
  }
  ::selection {
    @apply bg-accent/30 text-ink;
  }
  :focus-visible {
    @apply outline-none ring-2 ring-accent ring-offset-2 ring-offset-base rounded-sm;
  }
  h1, h2, h3, h4 {
    @apply font-display;
  }
}

@layer components {
  /* Card */
  .card {
    @apply bg-surface border border-border rounded-card shadow-card;
  }

  /* Buttons */
  .btn {
    @apply inline-flex items-center justify-center gap-2 rounded-lg px-4 py-2.5 text-sm font-medium
           transition-colors duration-150 disabled:opacity-50 disabled:cursor-not-allowed;
  }
  .btn-primary {
    @apply btn bg-accent text-base hover:bg-accent-hover;
  }
  .btn-secondary {
    @apply btn bg-surface-raised text-ink border border-border hover:border-ink-faint;
  }
  .btn-ghost {
    @apply btn text-ink-muted hover:text-ink hover:bg-surface-raised;
  }
  .btn-danger {
    @apply btn bg-status-busy/10 text-status-busy border border-status-busy/30 hover:bg-status-busy/20;
  }

  /* Form fields */
  .field-label {
    @apply block text-xs font-medium uppercase tracking-wide text-ink-muted mb-1.5;
  }
  .field-input {
    @apply w-full rounded-lg bg-surface-raised border border-border text-ink placeholder-ink-faint
           px-3.5 py-2.5 text-sm focus:border-accent transition-colors;
  }
  .field-error {
    @apply mt-1.5 text-xs text-status-busy;
  }

  /* Nav */
  .nav-link {
    @apply flex items-center gap-3 rounded-lg px-3 py-2.5 text-sm font-medium text-ink-muted
           hover:text-ink hover:bg-surface-raised transition-colors;
  }
  .nav-link-active {
    @apply nav-link text-ink bg-surface-raised;
  }

  /* Status pill — the app's signature motif */
  .status-dot {
    @apply inline-block h-2.5 w-2.5 rounded-full;
  }
  .status-pill {
    @apply inline-flex items-center gap-2 rounded-full border px-3 py-1.5 text-sm font-medium;
  }

  /* Day badge — used on Availability to give each weekday a visual anchor */
  .day-badge {
    @apply flex h-9 w-9 shrink-0 items-center justify-center rounded-lg
           bg-surface-raised border border-border text-xs font-semibold
           uppercase tracking-wide text-ink-muted;
  }
  .day-badge-on {
    @apply day-badge bg-accent/10 border-accent/30 text-accent;
  }
}

@layer utilities {
  /*
   * Forced display mode — set via the "Display" splash/switcher and stored
   * in localStorage as data-view on <html>. Independent of the actual
   * viewport: someone can force the mobile layout on a huge monitor, or
   * force the desktop layout on a phone, if that's what they prefer.
   * Absent data-view (unset / "auto") leaves normal responsive (lg:)
   * behavior untouched.
   */
  html[data-view="mobile"] .vm-topbar,
  html[data-view="tablet"] .vm-topbar {
    display: flex !important;
  }
  html[data-view="mobile"] .vm-sidebar,
  html[data-view="tablet"] .vm-sidebar {
    position: fixed !important;
    display: flex !important;
    transform: translateX(-100%) !important;
  }
  html[data-view="mobile"] .vm-sidebar.vm-open,
  html[data-view="tablet"] .vm-sidebar.vm-open {
    transform: translateX(0) !important;
  }
  html[data-view="mobile"] .vm-main {
    padding: 1rem !important;
  }
  html[data-view="tablet"] .vm-main {
    max-width: 42rem !important;
    margin-inline: auto !important;
    padding: 1.75rem 1.5rem !important;
  }
  html[data-view="tablet"] .vm-main .max-w-6xl {
    max-width: none !important;
  }

  html[data-view="desktop"] .vm-topbar {
    display: none !important;
  }
  html[data-view="desktop"] .vm-sidebar {
    position: static !important;
    display: flex !important;
    transform: none !important;
  }
  html[data-view="desktop"] .vm-main {
    padding: 2.5rem !important;
  }
}
CLAUDE_PATCH_EOF

mkdir -p "$APP_DIR/app/static/css"
cat > "$APP_DIR/app/static/css/main.css" << 'CLAUDE_PATCH_EOF'
*,:after,:before{--tw-border-spacing-x:0;--tw-border-spacing-y:0;--tw-translate-x:0;--tw-translate-y:0;--tw-rotate:0;--tw-skew-x:0;--tw-skew-y:0;--tw-scale-x:1;--tw-scale-y:1;--tw-pan-x: ;--tw-pan-y: ;--tw-pinch-zoom: ;--tw-scroll-snap-strictness:proximity;--tw-gradient-from-position: ;--tw-gradient-via-position: ;--tw-gradient-to-position: ;--tw-ordinal: ;--tw-slashed-zero: ;--tw-numeric-figure: ;--tw-numeric-spacing: ;--tw-numeric-fraction: ;--tw-ring-inset: ;--tw-ring-offset-width:0px;--tw-ring-offset-color:#fff;--tw-ring-color:rgba(59,130,246,.5);--tw-ring-offset-shadow:0 0 #0000;--tw-ring-shadow:0 0 #0000;--tw-shadow:0 0 #0000;--tw-shadow-colored:0 0 #0000;--tw-blur: ;--tw-brightness: ;--tw-contrast: ;--tw-grayscale: ;--tw-hue-rotate: ;--tw-invert: ;--tw-saturate: ;--tw-sepia: ;--tw-drop-shadow: ;--tw-backdrop-blur: ;--tw-backdrop-brightness: ;--tw-backdrop-contrast: ;--tw-backdrop-grayscale: ;--tw-backdrop-hue-rotate: ;--tw-backdrop-invert: ;--tw-backdrop-opacity: ;--tw-backdrop-saturate: ;--tw-backdrop-sepia: ;--tw-contain-size: ;--tw-contain-layout: ;--tw-contain-paint: ;--tw-contain-style: }::backdrop{--tw-border-spacing-x:0;--tw-border-spacing-y:0;--tw-translate-x:0;--tw-translate-y:0;--tw-rotate:0;--tw-skew-x:0;--tw-skew-y:0;--tw-scale-x:1;--tw-scale-y:1;--tw-pan-x: ;--tw-pan-y: ;--tw-pinch-zoom: ;--tw-scroll-snap-strictness:proximity;--tw-gradient-from-position: ;--tw-gradient-via-position: ;--tw-gradient-to-position: ;--tw-ordinal: ;--tw-slashed-zero: ;--tw-numeric-figure: ;--tw-numeric-spacing: ;--tw-numeric-fraction: ;--tw-ring-inset: ;--tw-ring-offset-width:0px;--tw-ring-offset-color:#fff;--tw-ring-color:rgba(59,130,246,.5);--tw-ring-offset-shadow:0 0 #0000;--tw-ring-shadow:0 0 #0000;--tw-shadow:0 0 #0000;--tw-shadow-colored:0 0 #0000;--tw-blur: ;--tw-brightness: ;--tw-contrast: ;--tw-grayscale: ;--tw-hue-rotate: ;--tw-invert: ;--tw-saturate: ;--tw-sepia: ;--tw-drop-shadow: ;--tw-backdrop-blur: ;--tw-backdrop-brightness: ;--tw-backdrop-contrast: ;--tw-backdrop-grayscale: ;--tw-backdrop-hue-rotate: ;--tw-backdrop-invert: ;--tw-backdrop-opacity: ;--tw-backdrop-saturate: ;--tw-backdrop-sepia: ;--tw-contain-size: ;--tw-contain-layout: ;--tw-contain-paint: ;--tw-contain-style: }/*! tailwindcss v3.4.19 | MIT License | https://tailwindcss.com*/*,:after,:before{box-sizing:border-box;border:0 solid #e5e7eb}:after,:before{--tw-content:""}:host,html{line-height:1.5;-webkit-text-size-adjust:100%;-moz-tab-size:4;-o-tab-size:4;tab-size:4;font-family:Inter,ui-sans-serif,system-ui,sans-serif;font-feature-settings:normal;font-variation-settings:normal;-webkit-tap-highlight-color:transparent}body{margin:0;line-height:inherit}hr{height:0;color:inherit;border-top-width:1px}abbr:where([title]){-webkit-text-decoration:underline dotted;text-decoration:underline dotted}h1,h2,h3,h4,h5,h6{font-size:inherit;font-weight:inherit}a{color:inherit;text-decoration:inherit}b,strong{font-weight:bolder}code,kbd,pre,samp{font-family:ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,Liberation Mono,Courier New,monospace;font-feature-settings:normal;font-variation-settings:normal;font-size:1em}small{font-size:80%}sub,sup{font-size:75%;line-height:0;position:relative;vertical-align:baseline}sub{bottom:-.25em}sup{top:-.5em}table{text-indent:0;border-color:inherit;border-collapse:collapse}button,input,optgroup,select,textarea{font-family:inherit;font-feature-settings:inherit;font-variation-settings:inherit;font-size:100%;font-weight:inherit;line-height:inherit;letter-spacing:inherit;color:inherit;margin:0;padding:0}button,select{text-transform:none}button,input:where([type=button]),input:where([type=reset]),input:where([type=submit]){-webkit-appearance:button;background-color:transparent;background-image:none}:-moz-focusring{outline:auto}:-moz-ui-invalid{box-shadow:none}progress{vertical-align:baseline}::-webkit-inner-spin-button,::-webkit-outer-spin-button{height:auto}[type=search]{-webkit-appearance:textfield;outline-offset:-2px}::-webkit-search-decoration{-webkit-appearance:none}::-webkit-file-upload-button{-webkit-appearance:button;font:inherit}summary{display:list-item}blockquote,dd,dl,figure,h1,h2,h3,h4,h5,h6,hr,p,pre{margin:0}fieldset{margin:0}fieldset,legend{padding:0}menu,ol,ul{list-style:none;margin:0;padding:0}dialog{padding:0}textarea{resize:vertical}input::-moz-placeholder,textarea::-moz-placeholder{opacity:1;color:#9ca3af}input::placeholder,textarea::placeholder{opacity:1;color:#9ca3af}[role=button],button{cursor:pointer}:disabled{cursor:default}audio,canvas,embed,iframe,img,object,svg,video{display:block;vertical-align:middle}img,video{max-width:100%;height:auto}[hidden]:where(:not([hidden=until-found])){display:none}input:where(:not([type])),input:where([type=date]),input:where([type=datetime-local]),input:where([type=email]),input:where([type=month]),input:where([type=number]),input:where([type=password]),input:where([type=search]),input:where([type=tel]),input:where([type=text]),input:where([type=time]),input:where([type=url]),input:where([type=week]),select,select:where([multiple]),textarea{-webkit-appearance:none;-moz-appearance:none;appearance:none;background-color:#fff;border-color:#6b7280;border-width:1px;border-radius:0;padding:.5rem .75rem;font-size:1rem;line-height:1.5rem;--tw-shadow:0 0 #0000}input:where(:not([type])):focus,input:where([type=date]):focus,input:where([type=datetime-local]):focus,input:where([type=email]):focus,input:where([type=month]):focus,input:where([type=number]):focus,input:where([type=password]):focus,input:where([type=search]):focus,input:where([type=tel]):focus,input:where([type=text]):focus,input:where([type=time]):focus,input:where([type=url]):focus,input:where([type=week]):focus,select:focus,select:where([multiple]):focus,textarea:focus{outline:2px solid transparent;outline-offset:2px;--tw-ring-inset:var(--tw-empty,/*!*/ /*!*/);--tw-ring-offset-width:0px;--tw-ring-offset-color:#fff;--tw-ring-color:#2563eb;--tw-ring-offset-shadow:var(--tw-ring-inset) 0 0 0 var(--tw-ring-offset-width) var(--tw-ring-offset-color);--tw-ring-shadow:var(--tw-ring-inset) 0 0 0 calc(1px + var(--tw-ring-offset-width)) var(--tw-ring-color);box-shadow:var(--tw-ring-offset-shadow),var(--tw-ring-shadow),var(--tw-shadow);border-color:#2563eb}input::-moz-placeholder,textarea::-moz-placeholder{color:#6b7280;opacity:1}input::placeholder,textarea::placeholder{color:#6b7280;opacity:1}::-webkit-datetime-edit-fields-wrapper{padding:0}::-webkit-date-and-time-value{min-height:1.5em;text-align:inherit}::-webkit-datetime-edit{display:inline-flex}::-webkit-datetime-edit,::-webkit-datetime-edit-day-field,::-webkit-datetime-edit-hour-field,::-webkit-datetime-edit-meridiem-field,::-webkit-datetime-edit-millisecond-field,::-webkit-datetime-edit-minute-field,::-webkit-datetime-edit-month-field,::-webkit-datetime-edit-second-field,::-webkit-datetime-edit-year-field{padding-top:0;padding-bottom:0}select{background-image:url("data:image/svg+xml;charset=utf-8,%3Csvg xmlns='http://www.w3.org/2000/svg' fill='none' viewBox='0 0 20 20'%3E%3Cpath stroke='%236b7280' stroke-linecap='round' stroke-linejoin='round' stroke-width='1.5' d='m6 8 4 4 4-4'/%3E%3C/svg%3E");background-position:right .5rem center;background-repeat:no-repeat;background-size:1.5em 1.5em;padding-right:2.5rem;-webkit-print-color-adjust:exact;print-color-adjust:exact}select:where([multiple]),select:where([size]:not([size="1"])){background-image:none;background-position:0 0;background-repeat:unset;background-size:initial;padding-right:.75rem;-webkit-print-color-adjust:unset;print-color-adjust:unset}input:where([type=checkbox]),input:where([type=radio]){-webkit-appearance:none;-moz-appearance:none;appearance:none;padding:0;-webkit-print-color-adjust:exact;print-color-adjust:exact;display:inline-block;vertical-align:middle;background-origin:border-box;-webkit-user-select:none;-moz-user-select:none;user-select:none;flex-shrink:0;height:1rem;width:1rem;color:#2563eb;background-color:#fff;border-color:#6b7280;border-width:1px;--tw-shadow:0 0 #0000}input:where([type=checkbox]){border-radius:0}input:where([type=radio]){border-radius:100%}input:where([type=checkbox]):focus,input:where([type=radio]):focus{outline:2px solid transparent;outline-offset:2px;--tw-ring-inset:var(--tw-empty,/*!*/ /*!*/);--tw-ring-offset-width:2px;--tw-ring-offset-color:#fff;--tw-ring-color:#2563eb;--tw-ring-offset-shadow:var(--tw-ring-inset) 0 0 0 var(--tw-ring-offset-width) var(--tw-ring-offset-color);--tw-ring-shadow:var(--tw-ring-inset) 0 0 0 calc(2px + var(--tw-ring-offset-width)) var(--tw-ring-color);box-shadow:var(--tw-ring-offset-shadow),var(--tw-ring-shadow),var(--tw-shadow)}input:where([type=checkbox]):checked,input:where([type=radio]):checked{border-color:transparent;background-color:currentColor;background-size:100% 100%;background-position:50%;background-repeat:no-repeat}input:where([type=checkbox]):checked{background-image:url("data:image/svg+xml;charset=utf-8,%3Csvg xmlns='http://www.w3.org/2000/svg' fill='%23fff' viewBox='0 0 16 16'%3E%3Cpath d='M12.207 4.793a1 1 0 0 1 0 1.414l-5 5a1 1 0 0 1-1.414 0l-2-2a1 1 0 0 1 1.414-1.414L6.5 9.086l4.293-4.293a1 1 0 0 1 1.414 0'/%3E%3C/svg%3E")}@media (forced-colors:active) {input:where([type=checkbox]):checked{-webkit-appearance:auto;-moz-appearance:auto;appearance:auto}}input:where([type=radio]):checked{background-image:url("data:image/svg+xml;charset=utf-8,%3Csvg xmlns='http://www.w3.org/2000/svg' fill='%23fff' viewBox='0 0 16 16'%3E%3Ccircle cx='8' cy='8' r='3'/%3E%3C/svg%3E")}@media (forced-colors:active) {input:where([type=radio]):checked{-webkit-appearance:auto;-moz-appearance:auto;appearance:auto}}input:where([type=checkbox]):checked:focus,input:where([type=checkbox]):checked:hover,input:where([type=radio]):checked:focus,input:where([type=radio]):checked:hover{border-color:transparent;background-color:currentColor}input:where([type=checkbox]):indeterminate{background-image:url("data:image/svg+xml;charset=utf-8,%3Csvg xmlns='http://www.w3.org/2000/svg' fill='none' viewBox='0 0 16 16'%3E%3Cpath stroke='%23fff' stroke-linecap='round' stroke-linejoin='round' stroke-width='2' d='M4 8h8'/%3E%3C/svg%3E");border-color:transparent;background-color:currentColor;background-size:100% 100%;background-position:50%;background-repeat:no-repeat}@media (forced-colors:active) {input:where([type=checkbox]):indeterminate{-webkit-appearance:auto;-moz-appearance:auto;appearance:auto}}input:where([type=checkbox]):indeterminate:focus,input:where([type=checkbox]):indeterminate:hover{border-color:transparent;background-color:currentColor}input:where([type=file]){background:unset;border-color:inherit;border-width:0;border-radius:0;padding:0;font-size:unset;line-height:inherit}input:where([type=file]):focus{outline:1px solid ButtonText;outline:1px auto -webkit-focus-ring-color}html{scroll-behavior:smooth}body{--tw-bg-opacity:1;background-color:rgb(18 20 26/var(--tw-bg-opacity,1));font-family:Inter,ui-sans-serif,system-ui,sans-serif;--tw-text-opacity:1;color:rgb(237 238 242/var(--tw-text-opacity,1));-webkit-font-smoothing:antialiased;-moz-osx-font-smoothing:grayscale}::-moz-selection{background-color:rgba(232,163,61,.3);--tw-text-opacity:1;color:rgb(237 238 242/var(--tw-text-opacity,1))}::selection{background-color:rgba(232,163,61,.3);--tw-text-opacity:1;color:rgb(237 238 242/var(--tw-text-opacity,1))}:focus-visible{border-radius:.125rem;outline:2px solid transparent;outline-offset:2px;--tw-ring-offset-shadow:var(--tw-ring-inset) 0 0 0 var(--tw-ring-offset-width) var(--tw-ring-offset-color);--tw-ring-shadow:var(--tw-ring-inset) 0 0 0 calc(2px + var(--tw-ring-offset-width)) var(--tw-ring-color);box-shadow:var(--tw-ring-offset-shadow),var(--tw-ring-shadow),var(--tw-shadow,0 0 #0000);--tw-ring-opacity:1;--tw-ring-color:rgb(232 163 61/var(--tw-ring-opacity,1));--tw-ring-offset-width:2px;--tw-ring-offset-color:#12141a}h1,h2,h3,h4{font-family:Space Grotesk,ui-sans-serif,system-ui,sans-serif}.card{border-radius:.875rem;border-width:1px;--tw-border-opacity:1;border-color:rgb(44 49 64/var(--tw-border-opacity,1));--tw-bg-opacity:1;background-color:rgb(27 30 39/var(--tw-bg-opacity,1));--tw-shadow:0 1px 0 0 hsla(0,0%,100%,.02) inset,0 8px 24px -12px rgba(0,0,0,.5);--tw-shadow-colored:inset 0 1px 0 0 var(--tw-shadow-color),0 8px 24px -12px var(--tw-shadow-color);box-shadow:var(--tw-ring-offset-shadow,0 0 #0000),var(--tw-ring-shadow,0 0 #0000),var(--tw-shadow)}.btn{display:inline-flex;align-items:center;justify-content:center;gap:.5rem;border-radius:.5rem;padding:.625rem 1rem;font-size:.875rem;line-height:1.25rem;font-weight:500;transition-property:color,background-color,border-color,text-decoration-color,fill,stroke;transition-timing-function:cubic-bezier(.4,0,.2,1);transition-duration:.15s}.btn:disabled{cursor:not-allowed;opacity:.5}.btn-primary{display:inline-flex;align-items:center;justify-content:center;gap:.5rem;border-radius:.5rem;padding:.625rem 1rem;font-size:.875rem;line-height:1.25rem;font-weight:500;transition-property:color,background-color,border-color,text-decoration-color,fill,stroke;transition-timing-function:cubic-bezier(.4,0,.2,1);transition-duration:.15s}.btn-primary:disabled{cursor:not-allowed;opacity:.5}.btn-primary{--tw-bg-opacity:1;background-color:rgb(232 163 61/var(--tw-bg-opacity,1));font-size:1rem;line-height:1.5rem;--tw-text-opacity:1;color:rgb(18 20 26/var(--tw-text-opacity,1))}.btn-primary:hover{--tw-bg-opacity:1;background-color:rgb(242 182 92/var(--tw-bg-opacity,1))}.btn-secondary{display:inline-flex;align-items:center;justify-content:center;gap:.5rem;border-radius:.5rem;padding:.625rem 1rem;font-size:.875rem;line-height:1.25rem;font-weight:500;transition-property:color,background-color,border-color,text-decoration-color,fill,stroke;transition-timing-function:cubic-bezier(.4,0,.2,1);transition-duration:.15s}.btn-secondary:disabled{cursor:not-allowed;opacity:.5}.btn-secondary{border-width:1px;--tw-border-opacity:1;border-color:rgb(44 49 64/var(--tw-border-opacity,1));--tw-bg-opacity:1;background-color:rgb(35 39 51/var(--tw-bg-opacity,1));--tw-text-opacity:1;color:rgb(237 238 242/var(--tw-text-opacity,1))}.btn-secondary:hover{--tw-border-opacity:1;border-color:rgb(84 91 110/var(--tw-border-opacity,1))}.btn-ghost{display:inline-flex;align-items:center;justify-content:center;gap:.5rem;border-radius:.5rem;padding:.625rem 1rem;font-size:.875rem;line-height:1.25rem;font-weight:500;transition-property:color,background-color,border-color,text-decoration-color,fill,stroke;transition-timing-function:cubic-bezier(.4,0,.2,1);transition-duration:.15s}.btn-ghost:disabled{cursor:not-allowed;opacity:.5}.btn-ghost{--tw-text-opacity:1;color:rgb(139 147 167/var(--tw-text-opacity,1))}.btn-ghost:hover{--tw-bg-opacity:1;background-color:rgb(35 39 51/var(--tw-bg-opacity,1));--tw-text-opacity:1;color:rgb(237 238 242/var(--tw-text-opacity,1))}.btn-danger{display:inline-flex;align-items:center;justify-content:center;gap:.5rem;border-radius:.5rem;padding:.625rem 1rem;font-size:.875rem;line-height:1.25rem;font-weight:500;transition-property:color,background-color,border-color,text-decoration-color,fill,stroke;transition-timing-function:cubic-bezier(.4,0,.2,1);transition-duration:.15s}.btn-danger:disabled{cursor:not-allowed;opacity:.5}.btn-danger{border-width:1px;border-color:rgba(242,99,123,.3);background-color:rgba(242,99,123,.1);--tw-text-opacity:1;color:rgb(242 99 123/var(--tw-text-opacity,1))}.btn-danger:hover{background-color:rgba(242,99,123,.2)}.field-label{margin-bottom:.375rem;display:block;font-size:.75rem;line-height:1rem;font-weight:500;text-transform:uppercase;letter-spacing:.025em;--tw-text-opacity:1;color:rgb(139 147 167/var(--tw-text-opacity,1))}.field-input{width:100%;border-radius:.5rem;border-width:1px;--tw-border-opacity:1;border-color:rgb(44 49 64/var(--tw-border-opacity,1));--tw-bg-opacity:1;background-color:rgb(35 39 51/var(--tw-bg-opacity,1));padding:.625rem .875rem;font-size:.875rem;line-height:1.25rem;--tw-text-opacity:1;color:rgb(237 238 242/var(--tw-text-opacity,1))}.field-input::-moz-placeholder{--tw-placeholder-opacity:1;color:rgb(84 91 110/var(--tw-placeholder-opacity,1))}.field-input::placeholder{--tw-placeholder-opacity:1;color:rgb(84 91 110/var(--tw-placeholder-opacity,1))}.field-input{transition-property:color,background-color,border-color,text-decoration-color,fill,stroke;transition-timing-function:cubic-bezier(.4,0,.2,1);transition-duration:.15s}.field-input:focus{--tw-border-opacity:1;border-color:rgb(232 163 61/var(--tw-border-opacity,1))}.field-error{margin-top:.375rem;font-size:.75rem;line-height:1rem;--tw-text-opacity:1;color:rgb(242 99 123/var(--tw-text-opacity,1))}.nav-link{display:flex;align-items:center;gap:.75rem;border-radius:.5rem;padding:.625rem .75rem;font-size:.875rem;line-height:1.25rem;font-weight:500;--tw-text-opacity:1;color:rgb(139 147 167/var(--tw-text-opacity,1));transition-property:color,background-color,border-color,text-decoration-color,fill,stroke;transition-timing-function:cubic-bezier(.4,0,.2,1);transition-duration:.15s}.nav-link:hover{--tw-bg-opacity:1;background-color:rgb(35 39 51/var(--tw-bg-opacity,1));--tw-text-opacity:1;color:rgb(237 238 242/var(--tw-text-opacity,1))}.nav-link-active{display:flex;align-items:center;gap:.75rem;border-radius:.5rem;padding:.625rem .75rem;font-size:.875rem;line-height:1.25rem;font-weight:500;color:rgb(139 147 167/var(--tw-text-opacity,1));transition-property:color,background-color,border-color,text-decoration-color,fill,stroke;transition-timing-function:cubic-bezier(.4,0,.2,1);transition-duration:.15s}.nav-link-active,.nav-link-active:hover{--tw-bg-opacity:1;background-color:rgb(35 39 51/var(--tw-bg-opacity,1));--tw-text-opacity:1;color:rgb(237 238 242/var(--tw-text-opacity,1))}.status-dot{display:inline-block;height:.625rem;width:.625rem;border-radius:9999px}.status-pill{display:inline-flex;align-items:center;gap:.5rem;border-radius:9999px;border-width:1px;padding:.375rem .75rem;font-size:.875rem;line-height:1.25rem;font-weight:500}.day-badge,.day-badge-on{display:flex;height:2.25rem;width:2.25rem;flex-shrink:0;align-items:center;justify-content:center;border-radius:.5rem;border-width:1px;--tw-border-opacity:1;border-color:rgb(44 49 64/var(--tw-border-opacity,1));--tw-bg-opacity:1;background-color:rgb(35 39 51/var(--tw-bg-opacity,1));font-size:.75rem;line-height:1rem;font-weight:600;text-transform:uppercase;letter-spacing:.025em;--tw-text-opacity:1;color:rgb(139 147 167/var(--tw-text-opacity,1))}.day-badge-on{border-color:rgba(232,163,61,.3);background-color:rgba(232,163,61,.1);color:rgb(232 163 61/var(--tw-text-opacity,1))}.pointer-events-none{pointer-events:none}.visible{visibility:visible}.static{position:static}.fixed{position:fixed}.absolute{position:absolute}.relative{position:relative}.sticky{position:sticky}.inset-0{inset:0}.inset-x-0{left:0;right:0}.inset-y-0{top:0;bottom:0}.left-0{left:0}.top-0{top:0}.z-30{z-index:30}.z-40{z-index:40}.z-50{z-index:50}.mx-auto{margin-left:auto;margin-right:auto}.-mt-2{margin-top:-.5rem}.mb-1{margin-bottom:.25rem}.mb-1\.5{margin-bottom:.375rem}.mb-10{margin-bottom:2.5rem}.mb-2{margin-bottom:.5rem}.mb-3{margin-bottom:.75rem}.mb-4{margin-bottom:1rem}.mb-5{margin-bottom:1.25rem}.mb-6{margin-bottom:1.5rem}.mb-8{margin-bottom:2rem}.ml-0{margin-left:0}.ml-2{margin-left:.5rem}.ml-5{margin-left:1.25rem}.ml-7{margin-left:1.75rem}.ml-auto{margin-left:auto}.mt-0\.5{margin-top:.125rem}.mt-1{margin-top:.25rem}.mt-1\.5{margin-top:.375rem}.mt-10{margin-top:2.5rem}.mt-2{margin-top:.5rem}.mt-3{margin-top:.75rem}.mt-4{margin-top:1rem}.mt-5{margin-top:1.25rem}.mt-6{margin-top:1.5rem}.mt-8{margin-top:2rem}.block{display:block}.inline-block{display:inline-block}.inline{display:inline}.flex{display:flex}.inline-flex{display:inline-flex}.table{display:table}.grid{display:grid}.hidden{display:none}.h-10{height:2.5rem}.h-12{height:3rem}.h-16{height:4rem}.h-2{height:.5rem}.h-2\.5{height:.625rem}.h-3{height:.75rem}.h-3\.5{height:.875rem}.h-4{height:1rem}.h-5{height:1.25rem}.h-6{height:1.5rem}.h-72{height:18rem}.h-9{height:2.25rem}.h-\[18px\]{height:18px}.h-full{height:100%}.min-h-\[120px\]{min-height:120px}.min-h-full{min-height:100%}.min-h-screen{min-height:100vh}.w-10{width:2.5rem}.w-12{width:3rem}.w-16{width:4rem}.w-2{width:.5rem}.w-2\.5{width:.625rem}.w-28{width:7rem}.w-3{width:.75rem}.w-3\.5{width:.875rem}.w-32{width:8rem}.w-4{width:1rem}.w-40{width:10rem}.w-5{width:1.25rem}.w-6{width:1.5rem}.w-72{width:18rem}.w-9{width:2.25rem}.w-\[18px\]{width:18px}.w-fit{width:-moz-fit-content;width:fit-content}.w-full{width:100%}.min-w-0{min-width:0}.max-w-2xl{max-width:42rem}.max-w-6xl{max-width:72rem}.max-w-lg{max-width:32rem}.max-w-md{max-width:28rem}.max-w-sm{max-width:24rem}.max-w-xs{max-width:20rem}.flex-1{flex:1 1 0%}.shrink-0{flex-shrink:0}.-translate-x-full{--tw-translate-x:-100%;transform:translate(var(--tw-translate-x),var(--tw-translate-y)) rotate(var(--tw-rotate)) skewX(var(--tw-skew-x)) skewY(var(--tw-skew-y)) scaleX(var(--tw-scale-x)) scaleY(var(--tw-scale-y))}@keyframes pulseSoft{0%,to{opacity:1}50%{opacity:.45}}.animate-pulse-soft{animation:pulseSoft 2.2s ease-in-out infinite}.cursor-not-allowed{cursor:not-allowed}.cursor-pointer{cursor:pointer}.list-disc{list-style-type:disc}.grid-cols-1{grid-template-columns:repeat(1,minmax(0,1fr))}.grid-cols-2{grid-template-columns:repeat(2,minmax(0,1fr))}.grid-cols-3{grid-template-columns:repeat(3,minmax(0,1fr))}.grid-cols-7{grid-template-columns:repeat(7,minmax(0,1fr))}.flex-col{flex-direction:column}.flex-wrap{flex-wrap:wrap}.items-start{align-items:flex-start}.items-end{align-items:flex-end}.items-center{align-items:center}.justify-center{justify-content:center}.justify-between{justify-content:space-between}.gap-1{gap:.25rem}.gap-1\.5{gap:.375rem}.gap-2{gap:.5rem}.gap-2\.5{gap:.625rem}.gap-3{gap:.75rem}.gap-3\.5{gap:.875rem}.gap-4{gap:1rem}.gap-6{gap:1.5rem}.gap-x-4{-moz-column-gap:1rem;column-gap:1rem}.gap-y-1\.5{row-gap:.375rem}.gap-y-3{row-gap:.75rem}.space-y-1>:not([hidden])~:not([hidden]){--tw-space-y-reverse:0;margin-top:calc(.25rem*(1 - var(--tw-space-y-reverse)));margin-bottom:calc(.25rem*var(--tw-space-y-reverse))}.space-y-1\.5>:not([hidden])~:not([hidden]){--tw-space-y-reverse:0;margin-top:calc(.375rem*(1 - var(--tw-space-y-reverse)));margin-bottom:calc(.375rem*var(--tw-space-y-reverse))}.space-y-2>:not([hidden])~:not([hidden]){--tw-space-y-reverse:0;margin-top:calc(.5rem*(1 - var(--tw-space-y-reverse)));margin-bottom:calc(.5rem*var(--tw-space-y-reverse))}.space-y-2\.5>:not([hidden])~:not([hidden]){--tw-space-y-reverse:0;margin-top:calc(.625rem*(1 - var(--tw-space-y-reverse)));margin-bottom:calc(.625rem*var(--tw-space-y-reverse))}.space-y-3>:not([hidden])~:not([hidden]){--tw-space-y-reverse:0;margin-top:calc(.75rem*(1 - var(--tw-space-y-reverse)));margin-bottom:calc(.75rem*var(--tw-space-y-reverse))}.space-y-4>:not([hidden])~:not([hidden]){--tw-space-y-reverse:0;margin-top:calc(1rem*(1 - var(--tw-space-y-reverse)));margin-bottom:calc(1rem*var(--tw-space-y-reverse))}.space-y-6>:not([hidden])~:not([hidden]){--tw-space-y-reverse:0;margin-top:calc(1.5rem*(1 - var(--tw-space-y-reverse)));margin-bottom:calc(1.5rem*var(--tw-space-y-reverse))}.space-y-8>:not([hidden])~:not([hidden]){--tw-space-y-reverse:0;margin-top:calc(2rem*(1 - var(--tw-space-y-reverse)));margin-bottom:calc(2rem*var(--tw-space-y-reverse))}.divide-y>:not([hidden])~:not([hidden]){--tw-divide-y-reverse:0;border-top-width:calc(1px*(1 - var(--tw-divide-y-reverse)));border-bottom-width:calc(1px*var(--tw-divide-y-reverse))}.divide-border>:not([hidden])~:not([hidden]){--tw-divide-opacity:1;border-color:rgb(44 49 64/var(--tw-divide-opacity,1))}.self-start{align-self:flex-start}.overflow-hidden,.truncate{overflow:hidden}.truncate{text-overflow:ellipsis;white-space:nowrap}.whitespace-pre-line{white-space:pre-line}.rounded{border-radius:.25rem}.rounded-full{border-radius:9999px}.rounded-lg{border-radius:.5rem}.rounded-md{border-radius:.375rem}.border{border-width:1px}.border-b{border-bottom-width:1px}.border-r{border-right-width:1px}.border-t{border-top-width:1px}.border-accent\/30{border-color:rgba(232,163,61,.3)}.border-accent\/40{border-color:rgba(232,163,61,.4)}.border-accent\/50{border-color:rgba(232,163,61,.5)}.border-border{--tw-border-opacity:1;border-color:rgb(44 49 64/var(--tw-border-opacity,1))}.border-status-available{--tw-border-opacity:1;border-color:rgb(61 220 151/var(--tw-border-opacity,1))}.border-status-available\/30{border-color:rgba(61,220,151,.3)}.border-status-away{--tw-border-opacity:1;border-color:rgb(91 141 239/var(--tw-border-opacity,1))}.border-status-busy{--tw-border-opacity:1;border-color:rgb(242 99 123/var(--tw-border-opacity,1))}.border-status-busy\/30{border-color:rgba(242,99,123,.3)}.border-status-offline{--tw-border-opacity:1;border-color:rgb(91 100 120/var(--tw-border-opacity,1))}.border-status-unavailable{--tw-border-opacity:1;border-color:rgb(185 139 242/var(--tw-border-opacity,1))}.bg-accent{--tw-bg-opacity:1;background-color:rgb(232 163 61/var(--tw-bg-opacity,1))}.bg-accent-muted{--tw-bg-opacity:1;background-color:rgb(58 45 24/var(--tw-bg-opacity,1))}.bg-accent-muted\/40{background-color:rgba(58,45,24,.4)}.bg-base{--tw-bg-opacity:1;background-color:rgb(18 20 26/var(--tw-bg-opacity,1))}.bg-base\/95{background-color:rgba(18,20,26,.95)}.bg-black\/50{background-color:rgba(0,0,0,.5)}.bg-black\/60{background-color:rgba(0,0,0,.6)}.bg-current{background-color:currentColor}.bg-ink-faint{--tw-bg-opacity:1;background-color:rgb(84 91 110/var(--tw-bg-opacity,1))}.bg-status-available{--tw-bg-opacity:1;background-color:rgb(61 220 151/var(--tw-bg-opacity,1))}.bg-status-available\/10{background-color:rgba(61,220,151,.1)}.bg-status-away{--tw-bg-opacity:1;background-color:rgb(91 141 239/var(--tw-bg-opacity,1))}.bg-status-away\/10{background-color:rgba(91,141,239,.1)}.bg-status-busy{--tw-bg-opacity:1;background-color:rgb(242 99 123/var(--tw-bg-opacity,1))}.bg-status-busy\/10{background-color:rgba(242,99,123,.1)}.bg-status-offline{--tw-bg-opacity:1;background-color:rgb(91 100 120/var(--tw-bg-opacity,1))}.bg-status-unavailable{--tw-bg-opacity:1;background-color:rgb(185 139 242/var(--tw-bg-opacity,1))}.bg-surface{--tw-bg-opacity:1;background-color:rgb(27 30 39/var(--tw-bg-opacity,1))}.bg-surface-raised{--tw-bg-opacity:1;background-color:rgb(35 39 51/var(--tw-bg-opacity,1))}.bg-gradient-to-b{background-image:linear-gradient(to bottom,var(--tw-gradient-stops))}.bg-gradient-to-br{background-image:linear-gradient(to bottom right,var(--tw-gradient-stops))}.from-accent-muted\/40{--tw-gradient-from:rgba(58,45,24,.4) var(--tw-gradient-from-position);--tw-gradient-to:rgba(58,45,24,0) var(--tw-gradient-to-position);--tw-gradient-stops:var(--tw-gradient-from),var(--tw-gradient-to)}.from-accent-muted\/50{--tw-gradient-from:rgba(58,45,24,.5) var(--tw-gradient-from-position);--tw-gradient-to:rgba(58,45,24,0) var(--tw-gradient-to-position);--tw-gradient-stops:var(--tw-gradient-from),var(--tw-gradient-to)}.via-transparent{--tw-gradient-to:transparent var(--tw-gradient-to-position);--tw-gradient-stops:var(--tw-gradient-from),transparent var(--tw-gradient-via-position),var(--tw-gradient-to)}.to-transparent{--tw-gradient-to:transparent var(--tw-gradient-to-position)}.p-1{padding:.25rem}.p-2{padding:.5rem}.p-4{padding:1rem}.p-5{padding:1.25rem}.p-6{padding:1.5rem}.p-8{padding:2rem}.\!px-2{padding-left:.5rem!important;padding-right:.5rem!important}.\!px-2\.5{padding-left:.625rem!important;padding-right:.625rem!important}.\!px-3{padding-left:.75rem!important;padding-right:.75rem!important}.\!py-1{padding-top:.25rem!important;padding-bottom:.25rem!important}.\!py-1\.5{padding-top:.375rem!important;padding-bottom:.375rem!important}.px-1{padding-left:.25rem;padding-right:.25rem}.px-1\.5{padding-left:.375rem;padding-right:.375rem}.px-3{padding-left:.75rem;padding-right:.75rem}.px-4{padding-left:1rem;padding-right:1rem}.px-6{padding-left:1.5rem;padding-right:1.5rem}.py-0\.5{padding-top:.125rem;padding-bottom:.125rem}.py-1{padding-top:.25rem;padding-bottom:.25rem}.py-1\.5{padding-top:.375rem;padding-bottom:.375rem}.py-10{padding-top:2.5rem;padding-bottom:2.5rem}.py-12{padding-top:3rem;padding-bottom:3rem}.py-16{padding-top:4rem;padding-bottom:4rem}.py-2{padding-top:.5rem;padding-bottom:.5rem}.py-2\.5{padding-top:.625rem;padding-bottom:.625rem}.py-3{padding-top:.75rem;padding-bottom:.75rem}.py-3\.5{padding-top:.875rem;padding-bottom:.875rem}.py-6{padding-top:1.5rem;padding-bottom:1.5rem}.py-8{padding-top:2rem;padding-bottom:2rem}.pb-1\.5{padding-bottom:.375rem}.pl-3{padding-left:.75rem}.pr-1\.5{padding-right:.375rem}.pt-4{padding-top:1rem}.pt-5{padding-top:1.25rem}.text-left{text-align:left}.text-center{text-align:center}.font-display{font-family:Space Grotesk,ui-sans-serif,system-ui,sans-serif}.font-mono{font-family:ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,Liberation Mono,Courier New,monospace}.text-2xl{font-size:1.5rem;line-height:2rem}.text-3xl{font-size:1.875rem;line-height:2.25rem}.text-6xl{font-size:3.75rem;line-height:1}.text-\[10px\]{font-size:10px}.text-\[11px\]{font-size:11px}.text-base{font-size:1rem;line-height:1.5rem}.text-lg{font-size:1.125rem;line-height:1.75rem}.text-sm{font-size:.875rem;line-height:1.25rem}.text-xl{font-size:1.25rem;line-height:1.75rem}.text-xs{font-size:.75rem;line-height:1rem}.font-medium{font-weight:500}.font-normal{font-weight:400}.font-semibold{font-weight:600}.uppercase{text-transform:uppercase}.capitalize{text-transform:capitalize}.italic{font-style:italic}.leading-relaxed{line-height:1.625}.leading-tight{line-height:1.25}.tracking-\[0\.3em\]{letter-spacing:.3em}.tracking-wide{letter-spacing:.025em}.tracking-wider{letter-spacing:.05em}.text-accent{--tw-text-opacity:1;color:rgb(232 163 61/var(--tw-text-opacity,1))}.text-base{--tw-text-opacity:1;color:rgb(18 20 26/var(--tw-text-opacity,1))}.text-ink{--tw-text-opacity:1;color:rgb(237 238 242/var(--tw-text-opacity,1))}.text-ink-faint{--tw-text-opacity:1;color:rgb(84 91 110/var(--tw-text-opacity,1))}.text-ink-muted{--tw-text-opacity:1;color:rgb(139 147 167/var(--tw-text-opacity,1))}.text-status-available{--tw-text-opacity:1;color:rgb(61 220 151/var(--tw-text-opacity,1))}.text-status-away{--tw-text-opacity:1;color:rgb(91 141 239/var(--tw-text-opacity,1))}.text-status-busy{--tw-text-opacity:1;color:rgb(242 99 123/var(--tw-text-opacity,1))}.text-status-offline{--tw-text-opacity:1;color:rgb(91 100 120/var(--tw-text-opacity,1))}.text-status-unavailable{--tw-text-opacity:1;color:rgb(185 139 242/var(--tw-text-opacity,1))}.underline{text-decoration-line:underline}.opacity-30{opacity:.3}.opacity-50{opacity:.5}.opacity-60{opacity:.6}.shadow-card{--tw-shadow:0 1px 0 0 hsla(0,0%,100%,.02) inset,0 8px 24px -12px rgba(0,0,0,.5);--tw-shadow-colored:inset 0 1px 0 0 var(--tw-shadow-color),0 8px 24px -12px var(--tw-shadow-color);box-shadow:var(--tw-ring-offset-shadow,0 0 #0000),var(--tw-ring-shadow,0 0 #0000),var(--tw-shadow)}.filter{filter:var(--tw-blur) var(--tw-brightness) var(--tw-contrast) var(--tw-grayscale) var(--tw-hue-rotate) var(--tw-invert) var(--tw-saturate) var(--tw-sepia) var(--tw-drop-shadow)}.backdrop-blur{--tw-backdrop-blur:blur(8px)}.backdrop-blur,.backdrop-blur-sm{-webkit-backdrop-filter:var(--tw-backdrop-blur) var(--tw-backdrop-brightness) var(--tw-backdrop-contrast) var(--tw-backdrop-grayscale) var(--tw-backdrop-hue-rotate) var(--tw-backdrop-invert) var(--tw-backdrop-opacity) var(--tw-backdrop-saturate) var(--tw-backdrop-sepia);backdrop-filter:var(--tw-backdrop-blur) var(--tw-backdrop-brightness) var(--tw-backdrop-contrast) var(--tw-backdrop-grayscale) var(--tw-backdrop-hue-rotate) var(--tw-backdrop-invert) var(--tw-backdrop-opacity) var(--tw-backdrop-saturate) var(--tw-backdrop-sepia)}.backdrop-blur-sm{--tw-backdrop-blur:blur(4px)}.transition-colors{transition-property:color,background-color,border-color,text-decoration-color,fill,stroke;transition-timing-function:cubic-bezier(.4,0,.2,1);transition-duration:.15s}.transition-transform{transition-property:transform;transition-timing-function:cubic-bezier(.4,0,.2,1);transition-duration:.15s}.duration-200{transition-duration:.2s}html[data-view=mobile] .vm-topbar,html[data-view=tablet] .vm-topbar{display:flex!important}html[data-view=mobile] .vm-sidebar,html[data-view=tablet] .vm-sidebar{position:fixed!important;display:flex!important;transform:translateX(-100%)!important}html[data-view=mobile] .vm-sidebar.vm-open,html[data-view=tablet] .vm-sidebar.vm-open{transform:translateX(0)!important}html[data-view=mobile] .vm-main{padding:1rem!important}html[data-view=tablet] .vm-main{max-width:42rem!important;margin-inline:auto!important;padding:1.75rem 1.5rem!important}html[data-view=tablet] .vm-main .max-w-6xl{max-width:none!important}html[data-view=desktop] .vm-topbar{display:none!important}html[data-view=desktop] .vm-sidebar{position:static!important;display:flex!important;transform:none!important}html[data-view=desktop] .vm-main{padding:2.5rem!important}.last\:border-r-0:last-child{border-right-width:0}.hover\:border-accent:hover{--tw-border-opacity:1;border-color:rgb(232 163 61/var(--tw-border-opacity,1))}.hover\:border-ink-faint:hover{--tw-border-opacity:1;border-color:rgb(84 91 110/var(--tw-border-opacity,1))}.hover\:bg-status-busy\/10:hover{background-color:rgba(242,99,123,.1)}.hover\:bg-surface-raised:hover{--tw-bg-opacity:1;background-color:rgb(35 39 51/var(--tw-bg-opacity,1))}.hover\:text-accent:hover{--tw-text-opacity:1;color:rgb(232 163 61/var(--tw-text-opacity,1))}.hover\:text-ink:hover{--tw-text-opacity:1;color:rgb(237 238 242/var(--tw-text-opacity,1))}.hover\:text-ink-muted:hover{--tw-text-opacity:1;color:rgb(139 147 167/var(--tw-text-opacity,1))}.hover\:text-status-busy:hover{--tw-text-opacity:1;color:rgb(242 99 123/var(--tw-text-opacity,1))}.hover\:underline:hover{text-decoration-line:underline}.focus\:ring-accent:focus{--tw-ring-opacity:1;--tw-ring-color:rgb(232 163 61/var(--tw-ring-opacity,1))}.focus\:ring-offset-base:focus{--tw-ring-offset-color:#12141a}.group:hover .group-hover\:text-accent{--tw-text-opacity:1;color:rgb(232 163 61/var(--tw-text-opacity,1))}@media (min-width:640px){.sm\:col-span-2{grid-column:span 2/span 2}.sm\:ml-\[8\.25rem\]{margin-left:8.25rem}.sm\:inline-flex{display:inline-flex}.sm\:hidden{display:none}.sm\:grid-cols-2{grid-template-columns:repeat(2,minmax(0,1fr))}.sm\:grid-cols-3{grid-template-columns:repeat(3,minmax(0,1fr))}.sm\:grid-cols-4{grid-template-columns:repeat(4,minmax(0,1fr))}.sm\:flex-row{flex-direction:row}.sm\:items-end{align-items:flex-end}.sm\:items-center{align-items:center}.sm\:justify-between{justify-content:space-between}.sm\:gap-2{gap:.5rem}.sm\:p-5{padding:1.25rem}.sm\:p-6{padding:1.5rem}.sm\:p-7{padding:1.75rem}.sm\:p-8{padding:2rem}.sm\:px-6{padding-left:1.5rem;padding-right:1.5rem}.sm\:py-14{padding-top:3.5rem;padding-bottom:3.5rem}.sm\:py-16{padding-top:4rem;padding-bottom:4rem}.sm\:text-2xl{font-size:1.5rem;line-height:2rem}}@media (min-width:1024px){.lg\:static{position:static}.lg\:col-span-1{grid-column:span 1/span 1}.lg\:col-span-2{grid-column:span 2/span 2}.lg\:block{display:block}.lg\:flex{display:flex}.lg\:grid{display:grid}.lg\:hidden{display:none}.lg\:min-h-0{min-height:0}.lg\:w-64{width:16rem}.lg\:shrink-0{flex-shrink:0}.lg\:translate-x-0{--tw-translate-x:0px;transform:translate(var(--tw-translate-x),var(--tw-translate-y)) rotate(var(--tw-rotate)) skewX(var(--tw-skew-x)) skewY(var(--tw-skew-y)) scaleX(var(--tw-scale-x)) scaleY(var(--tw-scale-y))}.lg\:grid-cols-2{grid-template-columns:repeat(2,minmax(0,1fr))}.lg\:grid-cols-3{grid-template-columns:repeat(3,minmax(0,1fr))}.lg\:flex-col{flex-direction:column}.lg\:justify-between{justify-content:space-between}.lg\:p-12{padding:3rem}.lg\:px-10{padding-left:2.5rem;padding-right:2.5rem}.lg\:px-8{padding-left:2rem;padding-right:2rem}.lg\:py-10{padding-top:2.5rem;padding-bottom:2.5rem}.lg\:text-left{text-align:left}}@media (min-width:1280px){.xl\:p-16{padding:4rem}.xl\:text-4xl{font-size:2.25rem;line-height:2.5rem}}
CLAUDE_PATCH_EOF

mkdir -p "$APP_DIR/migrations/versions"
cat > "$APP_DIR/migrations/versions/c709f4333571_add_isp_support_requests.py" << 'CLAUDE_PATCH_EOF'
"""add isp support requests

Revision ID: c709f4333571
Revises: cd6ab1fa54de
Create Date: 2026-08-12 22:10:31.102548

"""
from alembic import op
import sqlalchemy as sa
import app.services.crypto


# revision identifiers, used by Alembic.
revision = 'c709f4333571'
down_revision = 'cd6ab1fa54de'
branch_labels = None
depends_on = None


def upgrade():
    # ### commands auto generated by Alembic - please adjust! ###
    op.create_table('support_requests',
    sa.Column('id', sa.Integer(), nullable=False),
    sa.Column('status', sa.String(length=20), nullable=False),
    sa.Column('submitted_at', sa.DateTime(), nullable=True),
    sa.Column('resolved_at', sa.DateTime(), nullable=True),
    sa.Column('full_name', sa.String(length=200), nullable=False),
    sa.Column('email', sa.String(length=255), nullable=True),
    sa.Column('phone', sa.String(length=50), nullable=True),
    sa.Column('isp_name', sa.String(length=200), nullable=False),
    sa.Column('problem_description', sa.Text(), nullable=False),
    sa.Column('account_number', app.services.crypto.EncryptedString(), nullable=True),
    sa.Column('customer_number', app.services.crypto.EncryptedString(), nullable=True),
    sa.Column('full_address', app.services.crypto.EncryptedString(), nullable=True),
    sa.Column('service_address', app.services.crypto.EncryptedString(), nullable=True),
    sa.Column('date_of_birth', app.services.crypto.EncryptedString(), nullable=True),
    sa.Column('last_bill_date', sa.String(length=20), nullable=True),
    sa.Column('last_bill_amount', sa.String(length=20), nullable=True),
    sa.Column('mothers_maiden_name', app.services.crypto.EncryptedString(), nullable=True),
    sa.Column('childhood_nickname', app.services.crypto.EncryptedString(), nullable=True),
    sa.Column('security_question', sa.String(length=255), nullable=True),
    sa.Column('security_answer', app.services.crypto.EncryptedString(), nullable=True),
    sa.Column('other_security_info', app.services.crypto.EncryptedString(), nullable=True),
    sa.Column('consent_authorised', sa.Boolean(), nullable=False),
    sa.Column('consent_accurate', sa.Boolean(), nullable=False),
    sa.Column('consent_purpose', sa.Boolean(), nullable=False),
    sa.Column('consent_additional_verification', sa.Boolean(), nullable=False),
    sa.Column('consent_no_password_request', sa.Boolean(), nullable=False),
    sa.Column('admin_notes', sa.Text(), nullable=True),
    sa.PrimaryKeyConstraint('id')
    )
    with op.batch_alter_table('support_requests', schema=None) as batch_op:
        batch_op.create_index(batch_op.f('ix_support_requests_status'), ['status'], unique=False)
        batch_op.create_index(batch_op.f('ix_support_requests_submitted_at'), ['submitted_at'], unique=False)

    op.create_table('support_access_logs',
    sa.Column('id', sa.Integer(), nullable=False),
    sa.Column('support_request_id', sa.Integer(), nullable=False),
    sa.Column('user_id', sa.Integer(), nullable=False),
    sa.Column('accessed_at', sa.DateTime(), nullable=True),
    sa.ForeignKeyConstraint(['support_request_id'], ['support_requests.id'], ),
    sa.ForeignKeyConstraint(['user_id'], ['users.id'], ),
    sa.PrimaryKeyConstraint('id')
    )
    with op.batch_alter_table('support_access_logs', schema=None) as batch_op:
        batch_op.create_index(batch_op.f('ix_support_access_logs_support_request_id'), ['support_request_id'], unique=False)

    # ### end Alembic commands ###


def downgrade():
    # ### commands auto generated by Alembic - please adjust! ###
    with op.batch_alter_table('support_access_logs', schema=None) as batch_op:
        batch_op.drop_index(batch_op.f('ix_support_access_logs_support_request_id'))

    op.drop_table('support_access_logs')
    with op.batch_alter_table('support_requests', schema=None) as batch_op:
        batch_op.drop_index(batch_op.f('ix_support_requests_submitted_at'))
        batch_op.drop_index(batch_op.f('ix_support_requests_status'))

    op.drop_table('support_requests')
    # ### end Alembic commands ###
CLAUDE_PATCH_EOF

echo "Files written."

bold() { printf '\033[1m%s\033[0m\n' "$1"; }

cd "$APP_DIR"

bold "== Python dependencies =="
if [ -x "$APP_DIR/.venv/bin/python" ]; then PY="$APP_DIR/.venv/bin/python"
elif [ -x "$APP_DIR/venv/bin/python" ]; then PY="$APP_DIR/venv/bin/python"
else PY="$(command -v python3)"; fi
"$PY" -m pip install --quiet -r requirements.txt

bold "== Database migration =="
export FLASK_APP=run.py
"$PY" -m flask db upgrade

bold "== Restarting $SERVICE_NAME =="
sudo systemctl restart "$SERVICE_NAME"

sleep 2
CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PORT}/auth/login" 2>/dev/null || echo 000)
if [ "$CODE" = "200" ]; then bold "Done — app responding on port $PORT."
else echo "App did not respond as expected (HTTP $CODE) — check: sudo journalctl -u $SERVICE_NAME -n 50"; fi
