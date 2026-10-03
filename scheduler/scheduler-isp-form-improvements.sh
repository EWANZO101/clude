#!/usr/bin/env bash
# Scheduler patch — ISP support form improvements:
#  - The password/OTP warning is now its own red warning box (was buried in
#    a neutral info card)
#  - ISP name is now a dropdown of common UK providers (BT, Sky, Virgin Media,
#    TalkTalk, EE, Vodafone, Plusnet, NOW, Zen, Hyperoptic, Community Fibre,
#    Gigaclear, YouFibre, Toob, Trooli, Giganet, Brsk, Wessex Internet, Shell
#    Energy, Utility Warehouse, Onestream) with an "Other" option that reveals
#    a free-text field for anyone not listed — there's no single official
#    Ofcom-published ISP list to pull from, so this is a common-providers list
#    with a fallback rather than a live feed
#  - Fixed a real validation bug found while testing: picking "Other" without
#    typing a name used to submit successfully with a blank ISP name
#  - Settings page: the out-of-hours fee description now says explicitly it
#    only affects the ISP support form, not ordinary bookings
# Paste this whole block into a terminal on the server.
set -euo pipefail

APP_DIR="${APP_DIR:-/root/scheduler}"
SERVICE_NAME="${SERVICE_NAME:-scheduler}"
PORT="${PORT:-5076}"

[ -f "$APP_DIR/run.py" ] || { echo "APP_DIR ($APP_DIR) doesn't look like the scheduler app — set APP_DIR=/path first."; exit 1; }

ts=$(date +%Y%m%d%H%M%S)
mkdir -p "$APP_DIR/.pre-patch-backup-$ts"
[ -f "$APP_DIR/app/forms.py" ] && { mkdir -p "$APP_DIR/.pre-patch-backup-$ts/$(dirname app/forms.py)"; cp "$APP_DIR/app/forms.py" "$APP_DIR/.pre-patch-backup-$ts/app/forms.py"; } || true
[ -f "$APP_DIR/app/routes/isp_support.py" ] && { mkdir -p "$APP_DIR/.pre-patch-backup-$ts/$(dirname app/routes/isp_support.py)"; cp "$APP_DIR/app/routes/isp_support.py" "$APP_DIR/.pre-patch-backup-$ts/app/routes/isp_support.py"; } || true
[ -f "$APP_DIR/app/templates/public/isp_support_form.html" ] && { mkdir -p "$APP_DIR/.pre-patch-backup-$ts/$(dirname app/templates/public/isp_support_form.html)"; cp "$APP_DIR/app/templates/public/isp_support_form.html" "$APP_DIR/.pre-patch-backup-$ts/app/templates/public/isp_support_form.html"; } || true
[ -f "$APP_DIR/app/templates/admin/settings.html" ] && { mkdir -p "$APP_DIR/.pre-patch-backup-$ts/$(dirname app/templates/admin/settings.html)"; cp "$APP_DIR/app/templates/admin/settings.html" "$APP_DIR/.pre-patch-backup-$ts/app/templates/admin/settings.html"; } || true
[ -f "$APP_DIR/app/static/css/main.css" ] && { mkdir -p "$APP_DIR/.pre-patch-backup-$ts/$(dirname app/static/css/main.css)"; cp "$APP_DIR/app/static/css/main.css" "$APP_DIR/.pre-patch-backup-$ts/app/static/css/main.css"; } || true

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
CLAUDE_PATCH_EOF

mkdir -p "$APP_DIR/app/routes"
cat > "$APP_DIR/app/routes/isp_support.py" << 'CLAUDE_PATCH_EOF'
from flask import Blueprint, abort, flash, redirect, render_template, request, session, url_for
from flask_login import current_user, login_required

from app import db
from app.forms import CSRFOnlyForm, ISPFeeForm, ISPSupportForm, SupportRequestLookupForm, SupportRequestStatusForm
from app.models.isp_support import STATUSES, SupportAccessLog, SupportRequest
from app.models.settings import Settings
from app.models.user import User
from app.services.availability import compute_available_intervals
from app.services.status import local_now

isp_support_bp = Blueprint("isp_support", __name__)


def _is_out_of_hours(owner):
    """Whether right now falls outside `owner`'s normal working hours.

    Reuses the same availability engine the booking system reads from, so
    "out of hours" here means exactly what it means on the Availability
    page — not a separate/duplicated notion of business hours.
    """
    if owner is None:
        return False
    now = local_now(owner)
    intervals = compute_available_intervals(owner, now.date())
    return not any(start <= now < end for start, end in intervals)


@isp_support_bp.route("/support/isp", methods=["GET", "POST"])
def request_form():
    owner = User.get_primary()
    fee = None
    out_of_hours = False
    if owner is not None:
        settings_row = Settings.for_user(owner)
        fee = settings_row.isp_out_of_hours_fee or None
        out_of_hours = _is_out_of_hours(owner)

    form = ISPSupportForm()

    if form.validate_on_submit():
        fee_ack_needed = out_of_hours and fee
        if fee_ack_needed and not form.consent_out_of_hours_fee.data:
            flash(f"Please confirm you accept the {fee} out-of-hours fee to continue.", "error")
        else:
            resolved_isp_name = (
                (form.isp_name_other.data or "").strip()
                if form.isp_name.data == "other"
                else form.isp_name.data
            )
            req = SupportRequest(
                full_name=form.full_name.data.strip(),
                email=(form.email.data or "").strip() or None,
                phone=(form.phone.data or "").strip() or None,
                isp_name=resolved_isp_name,
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
                submitted_out_of_hours=bool(fee_ack_needed),
                out_of_hours_fee_shown=fee if fee_ack_needed else None,
            )
            db.session.add(req)
            db.session.commit()
            session["isp_support_last_reference"] = req.reference
            return redirect(url_for("isp_support.thank_you"))

    return render_template(
        "public/isp_support_form.html", form=form, out_of_hours=out_of_hours, fee=fee
    )


@isp_support_bp.route("/support/isp/thank-you")
def thank_you():
    reference = session.pop("isp_support_last_reference", None)
    return render_template("public/isp_support_thanks.html", reference=reference)


@isp_support_bp.route("/support/isp/status", methods=["GET", "POST"])
def check_status():
    form = SupportRequestLookupForm()
    result = None
    searched = False

    if form.validate_on_submit():
        searched = True
        result = SupportRequest.query.filter_by(
            reference=form.reference.data.strip().upper(),
        ).first()
        if result and (result.email or "").strip().lower() != form.email.data.strip().lower():
            result = None
        if not result:
            flash("No request found with that reference code and email.", "error")

    return render_template("public/isp_support_status.html", form=form, result=result, searched=searched)


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

  {% if out_of_hours and fee %}
  <div class="card p-4 sm:p-5 mb-6 border-status-away/30 bg-status-away/10 flex items-start gap-3">
    <span class="status-dot bg-status-away mt-1.5 shrink-0"></span>
    <p class="text-sm text-ink">
      It's currently outside normal hours, so an out-of-hours fee of
      <span class="font-medium">{{ fee }}</span> applies to this request. You'll be asked to
      confirm you accept this before submitting.
    </p>
  </div>
  {% endif %}

  <div class="card p-5 sm:p-6 mb-4 text-sm text-ink-muted leading-relaxed space-y-2">
    <p class="font-medium text-ink">Please only fill in what your ISP has actually asked for.</p>
    <p>
      Full name, your ISP's name, and a description of the problem are the only required fields
      below. Everything else — account numbers, date of birth, security questions, billing
      details — should only be filled in if your specific ISP requires it for this request.
      If you're not sure what's needed, leave it blank and contact your ISP first.
    </p>
  </div>

  <div class="rounded-lg border border-status-busy/40 bg-status-busy/10 p-5 sm:p-6 mb-6">
    <div class="flex items-start gap-3">
      <svg xmlns="http://www.w3.org/2000/svg" class="h-5 w-5 shrink-0 text-status-busy mt-0.5" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M10.29 3.86L1.82 18a2 2 0 001.71 3h16.94a2 2 0 001.71-3L13.71 3.86a2 2 0 00-3.42 0z"/><line x1="12" y1="9" x2="12" y2="13"/><line x1="12" y1="17" x2="12.01" y2="17"/></svg>
      <div class="text-sm leading-relaxed">
        <p class="font-semibold text-status-busy mb-1">Never enter your ISP password, online banking details, payment-card security information, or one-time verification codes anywhere on this form.</p>
        <p class="text-status-busy/90">
          I will never ask you for these. If your ISP needs to send you a verification code,
          you'll need to be available to complete that step yourself directly with them.
        </p>
      </div>
    </div>
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
        {{ form.isp_name(class_="field-input", id="isp-name-select") }}
        {% for e in form.isp_name.errors %}<p class="field-error">{{ e }}</p>{% endfor %}
      </div>

      <div id="isp-name-other-wrap" class="hidden">
        <label class="field-label" for="{{ form.isp_name_other.id }}">{{ form.isp_name_other.label.text }}</label>
        {{ form.isp_name_other(class_="field-input", id="isp-name-other") }}
        {% for e in form.isp_name_other.errors %}<p class="field-error">{{ e }}</p>{% endfor %}
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

      {% if out_of_hours and fee %}
      <label class="flex items-start gap-3 text-sm text-ink-muted">
        {{ form.consent_out_of_hours_fee(class_="mt-0.5 h-4 w-4 rounded border-border bg-surface-raised text-accent focus:ring-accent focus:ring-offset-base shrink-0") }}
        <span>I understand a <strong class="text-ink">{{ fee }}</strong> out-of-hours fee applies to this request and I agree to it.</span>
      </label>
      {% endif %}
    </div>

    <button type="submit" class="btn-primary w-full">Submit request</button>
  </form>

  <div class="mt-6 flex flex-col items-center gap-2 text-center text-xs text-ink-faint">
    <p>
      Read the full <a href="{{ url_for('isp_support.thank_you') }}#privacy" class="underline hover:text-ink-muted">privacy notice</a>
      for what's collected, why, and how to request deletion.
    </p>
    <p>
      Already submitted a request?
      <a href="{{ url_for('isp_support.check_status') }}" class="underline hover:text-ink-muted">Check its status</a>
    </p>
    <p>
      Looking for something else?
      <a href="{{ url_for('public.booking_types') }}" class="underline hover:text-ink-muted">Book an appointment</a>
      or
      <a href="{{ url_for('calendarmaker.welcome') }}" class="underline hover:text-ink-muted">create a shared calendar</a>
    </p>
  </div>
</div>

<script>
  (function () {
    var select = document.getElementById("isp-name-select");
    var wrap = document.getElementById("isp-name-other-wrap");
    if (!select || !wrap) return;

    function sync() {
      wrap.classList.toggle("hidden", select.value !== "other");
    }

    select.addEventListener("change", sync);
    sync();
  })();
</script>
{% endblock %}
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

mkdir -p "$APP_DIR/app/static/css"
cat > "$APP_DIR/app/static/css/main.css" << 'CLAUDE_PATCH_EOF'
*,:after,:before{--tw-border-spacing-x:0;--tw-border-spacing-y:0;--tw-translate-x:0;--tw-translate-y:0;--tw-rotate:0;--tw-skew-x:0;--tw-skew-y:0;--tw-scale-x:1;--tw-scale-y:1;--tw-pan-x: ;--tw-pan-y: ;--tw-pinch-zoom: ;--tw-scroll-snap-strictness:proximity;--tw-gradient-from-position: ;--tw-gradient-via-position: ;--tw-gradient-to-position: ;--tw-ordinal: ;--tw-slashed-zero: ;--tw-numeric-figure: ;--tw-numeric-spacing: ;--tw-numeric-fraction: ;--tw-ring-inset: ;--tw-ring-offset-width:0px;--tw-ring-offset-color:#fff;--tw-ring-color:rgba(59,130,246,.5);--tw-ring-offset-shadow:0 0 #0000;--tw-ring-shadow:0 0 #0000;--tw-shadow:0 0 #0000;--tw-shadow-colored:0 0 #0000;--tw-blur: ;--tw-brightness: ;--tw-contrast: ;--tw-grayscale: ;--tw-hue-rotate: ;--tw-invert: ;--tw-saturate: ;--tw-sepia: ;--tw-drop-shadow: ;--tw-backdrop-blur: ;--tw-backdrop-brightness: ;--tw-backdrop-contrast: ;--tw-backdrop-grayscale: ;--tw-backdrop-hue-rotate: ;--tw-backdrop-invert: ;--tw-backdrop-opacity: ;--tw-backdrop-saturate: ;--tw-backdrop-sepia: ;--tw-contain-size: ;--tw-contain-layout: ;--tw-contain-paint: ;--tw-contain-style: }::backdrop{--tw-border-spacing-x:0;--tw-border-spacing-y:0;--tw-translate-x:0;--tw-translate-y:0;--tw-rotate:0;--tw-skew-x:0;--tw-skew-y:0;--tw-scale-x:1;--tw-scale-y:1;--tw-pan-x: ;--tw-pan-y: ;--tw-pinch-zoom: ;--tw-scroll-snap-strictness:proximity;--tw-gradient-from-position: ;--tw-gradient-via-position: ;--tw-gradient-to-position: ;--tw-ordinal: ;--tw-slashed-zero: ;--tw-numeric-figure: ;--tw-numeric-spacing: ;--tw-numeric-fraction: ;--tw-ring-inset: ;--tw-ring-offset-width:0px;--tw-ring-offset-color:#fff;--tw-ring-color:rgba(59,130,246,.5);--tw-ring-offset-shadow:0 0 #0000;--tw-ring-shadow:0 0 #0000;--tw-shadow:0 0 #0000;--tw-shadow-colored:0 0 #0000;--tw-blur: ;--tw-brightness: ;--tw-contrast: ;--tw-grayscale: ;--tw-hue-rotate: ;--tw-invert: ;--tw-saturate: ;--tw-sepia: ;--tw-drop-shadow: ;--tw-backdrop-blur: ;--tw-backdrop-brightness: ;--tw-backdrop-contrast: ;--tw-backdrop-grayscale: ;--tw-backdrop-hue-rotate: ;--tw-backdrop-invert: ;--tw-backdrop-opacity: ;--tw-backdrop-saturate: ;--tw-backdrop-sepia: ;--tw-contain-size: ;--tw-contain-layout: ;--tw-contain-paint: ;--tw-contain-style: }/*! tailwindcss v3.4.19 | MIT License | https://tailwindcss.com*/*,:after,:before{box-sizing:border-box;border:0 solid #e5e7eb}:after,:before{--tw-content:""}:host,html{line-height:1.5;-webkit-text-size-adjust:100%;-moz-tab-size:4;-o-tab-size:4;tab-size:4;font-family:Inter,ui-sans-serif,system-ui,sans-serif;font-feature-settings:normal;font-variation-settings:normal;-webkit-tap-highlight-color:transparent}body{margin:0;line-height:inherit}hr{height:0;color:inherit;border-top-width:1px}abbr:where([title]){-webkit-text-decoration:underline dotted;text-decoration:underline dotted}h1,h2,h3,h4,h5,h6{font-size:inherit;font-weight:inherit}a{color:inherit;text-decoration:inherit}b,strong{font-weight:bolder}code,kbd,pre,samp{font-family:ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,Liberation Mono,Courier New,monospace;font-feature-settings:normal;font-variation-settings:normal;font-size:1em}small{font-size:80%}sub,sup{font-size:75%;line-height:0;position:relative;vertical-align:baseline}sub{bottom:-.25em}sup{top:-.5em}table{text-indent:0;border-color:inherit;border-collapse:collapse}button,input,optgroup,select,textarea{font-family:inherit;font-feature-settings:inherit;font-variation-settings:inherit;font-size:100%;font-weight:inherit;line-height:inherit;letter-spacing:inherit;color:inherit;margin:0;padding:0}button,select{text-transform:none}button,input:where([type=button]),input:where([type=reset]),input:where([type=submit]){-webkit-appearance:button;background-color:transparent;background-image:none}:-moz-focusring{outline:auto}:-moz-ui-invalid{box-shadow:none}progress{vertical-align:baseline}::-webkit-inner-spin-button,::-webkit-outer-spin-button{height:auto}[type=search]{-webkit-appearance:textfield;outline-offset:-2px}::-webkit-search-decoration{-webkit-appearance:none}::-webkit-file-upload-button{-webkit-appearance:button;font:inherit}summary{display:list-item}blockquote,dd,dl,figure,h1,h2,h3,h4,h5,h6,hr,p,pre{margin:0}fieldset{margin:0}fieldset,legend{padding:0}menu,ol,ul{list-style:none;margin:0;padding:0}dialog{padding:0}textarea{resize:vertical}input::-moz-placeholder,textarea::-moz-placeholder{opacity:1;color:#9ca3af}input::placeholder,textarea::placeholder{opacity:1;color:#9ca3af}[role=button],button{cursor:pointer}:disabled{cursor:default}audio,canvas,embed,iframe,img,object,svg,video{display:block;vertical-align:middle}img,video{max-width:100%;height:auto}[hidden]:where(:not([hidden=until-found])){display:none}input:where(:not([type])),input:where([type=date]),input:where([type=datetime-local]),input:where([type=email]),input:where([type=month]),input:where([type=number]),input:where([type=password]),input:where([type=search]),input:where([type=tel]),input:where([type=text]),input:where([type=time]),input:where([type=url]),input:where([type=week]),select,select:where([multiple]),textarea{-webkit-appearance:none;-moz-appearance:none;appearance:none;background-color:#fff;border-color:#6b7280;border-width:1px;border-radius:0;padding:.5rem .75rem;font-size:1rem;line-height:1.5rem;--tw-shadow:0 0 #0000}input:where(:not([type])):focus,input:where([type=date]):focus,input:where([type=datetime-local]):focus,input:where([type=email]):focus,input:where([type=month]):focus,input:where([type=number]):focus,input:where([type=password]):focus,input:where([type=search]):focus,input:where([type=tel]):focus,input:where([type=text]):focus,input:where([type=time]):focus,input:where([type=url]):focus,input:where([type=week]):focus,select:focus,select:where([multiple]):focus,textarea:focus{outline:2px solid transparent;outline-offset:2px;--tw-ring-inset:var(--tw-empty,/*!*/ /*!*/);--tw-ring-offset-width:0px;--tw-ring-offset-color:#fff;--tw-ring-color:#2563eb;--tw-ring-offset-shadow:var(--tw-ring-inset) 0 0 0 var(--tw-ring-offset-width) var(--tw-ring-offset-color);--tw-ring-shadow:var(--tw-ring-inset) 0 0 0 calc(1px + var(--tw-ring-offset-width)) var(--tw-ring-color);box-shadow:var(--tw-ring-offset-shadow),var(--tw-ring-shadow),var(--tw-shadow);border-color:#2563eb}input::-moz-placeholder,textarea::-moz-placeholder{color:#6b7280;opacity:1}input::placeholder,textarea::placeholder{color:#6b7280;opacity:1}::-webkit-datetime-edit-fields-wrapper{padding:0}::-webkit-date-and-time-value{min-height:1.5em;text-align:inherit}::-webkit-datetime-edit{display:inline-flex}::-webkit-datetime-edit,::-webkit-datetime-edit-day-field,::-webkit-datetime-edit-hour-field,::-webkit-datetime-edit-meridiem-field,::-webkit-datetime-edit-millisecond-field,::-webkit-datetime-edit-minute-field,::-webkit-datetime-edit-month-field,::-webkit-datetime-edit-second-field,::-webkit-datetime-edit-year-field{padding-top:0;padding-bottom:0}select{background-image:url("data:image/svg+xml;charset=utf-8,%3Csvg xmlns='http://www.w3.org/2000/svg' fill='none' viewBox='0 0 20 20'%3E%3Cpath stroke='%236b7280' stroke-linecap='round' stroke-linejoin='round' stroke-width='1.5' d='m6 8 4 4 4-4'/%3E%3C/svg%3E");background-position:right .5rem center;background-repeat:no-repeat;background-size:1.5em 1.5em;padding-right:2.5rem;-webkit-print-color-adjust:exact;print-color-adjust:exact}select:where([multiple]),select:where([size]:not([size="1"])){background-image:none;background-position:0 0;background-repeat:unset;background-size:initial;padding-right:.75rem;-webkit-print-color-adjust:unset;print-color-adjust:unset}input:where([type=checkbox]),input:where([type=radio]){-webkit-appearance:none;-moz-appearance:none;appearance:none;padding:0;-webkit-print-color-adjust:exact;print-color-adjust:exact;display:inline-block;vertical-align:middle;background-origin:border-box;-webkit-user-select:none;-moz-user-select:none;user-select:none;flex-shrink:0;height:1rem;width:1rem;color:#2563eb;background-color:#fff;border-color:#6b7280;border-width:1px;--tw-shadow:0 0 #0000}input:where([type=checkbox]){border-radius:0}input:where([type=radio]){border-radius:100%}input:where([type=checkbox]):focus,input:where([type=radio]):focus{outline:2px solid transparent;outline-offset:2px;--tw-ring-inset:var(--tw-empty,/*!*/ /*!*/);--tw-ring-offset-width:2px;--tw-ring-offset-color:#fff;--tw-ring-color:#2563eb;--tw-ring-offset-shadow:var(--tw-ring-inset) 0 0 0 var(--tw-ring-offset-width) var(--tw-ring-offset-color);--tw-ring-shadow:var(--tw-ring-inset) 0 0 0 calc(2px + var(--tw-ring-offset-width)) var(--tw-ring-color);box-shadow:var(--tw-ring-offset-shadow),var(--tw-ring-shadow),var(--tw-shadow)}input:where([type=checkbox]):checked,input:where([type=radio]):checked{border-color:transparent;background-color:currentColor;background-size:100% 100%;background-position:50%;background-repeat:no-repeat}input:where([type=checkbox]):checked{background-image:url("data:image/svg+xml;charset=utf-8,%3Csvg xmlns='http://www.w3.org/2000/svg' fill='%23fff' viewBox='0 0 16 16'%3E%3Cpath d='M12.207 4.793a1 1 0 0 1 0 1.414l-5 5a1 1 0 0 1-1.414 0l-2-2a1 1 0 0 1 1.414-1.414L6.5 9.086l4.293-4.293a1 1 0 0 1 1.414 0'/%3E%3C/svg%3E")}@media (forced-colors:active) {input:where([type=checkbox]):checked{-webkit-appearance:auto;-moz-appearance:auto;appearance:auto}}input:where([type=radio]):checked{background-image:url("data:image/svg+xml;charset=utf-8,%3Csvg xmlns='http://www.w3.org/2000/svg' fill='%23fff' viewBox='0 0 16 16'%3E%3Ccircle cx='8' cy='8' r='3'/%3E%3C/svg%3E")}@media (forced-colors:active) {input:where([type=radio]):checked{-webkit-appearance:auto;-moz-appearance:auto;appearance:auto}}input:where([type=checkbox]):checked:focus,input:where([type=checkbox]):checked:hover,input:where([type=radio]):checked:focus,input:where([type=radio]):checked:hover{border-color:transparent;background-color:currentColor}input:where([type=checkbox]):indeterminate{background-image:url("data:image/svg+xml;charset=utf-8,%3Csvg xmlns='http://www.w3.org/2000/svg' fill='none' viewBox='0 0 16 16'%3E%3Cpath stroke='%23fff' stroke-linecap='round' stroke-linejoin='round' stroke-width='2' d='M4 8h8'/%3E%3C/svg%3E");border-color:transparent;background-color:currentColor;background-size:100% 100%;background-position:50%;background-repeat:no-repeat}@media (forced-colors:active) {input:where([type=checkbox]):indeterminate{-webkit-appearance:auto;-moz-appearance:auto;appearance:auto}}input:where([type=checkbox]):indeterminate:focus,input:where([type=checkbox]):indeterminate:hover{border-color:transparent;background-color:currentColor}input:where([type=file]){background:unset;border-color:inherit;border-width:0;border-radius:0;padding:0;font-size:unset;line-height:inherit}input:where([type=file]):focus{outline:1px solid ButtonText;outline:1px auto -webkit-focus-ring-color}html{scroll-behavior:smooth}body{--tw-bg-opacity:1;background-color:rgb(18 20 26/var(--tw-bg-opacity,1));font-family:Inter,ui-sans-serif,system-ui,sans-serif;--tw-text-opacity:1;color:rgb(237 238 242/var(--tw-text-opacity,1));-webkit-font-smoothing:antialiased;-moz-osx-font-smoothing:grayscale}::-moz-selection{background-color:rgba(232,163,61,.3);--tw-text-opacity:1;color:rgb(237 238 242/var(--tw-text-opacity,1))}::selection{background-color:rgba(232,163,61,.3);--tw-text-opacity:1;color:rgb(237 238 242/var(--tw-text-opacity,1))}:focus-visible{border-radius:.125rem;outline:2px solid transparent;outline-offset:2px;--tw-ring-offset-shadow:var(--tw-ring-inset) 0 0 0 var(--tw-ring-offset-width) var(--tw-ring-offset-color);--tw-ring-shadow:var(--tw-ring-inset) 0 0 0 calc(2px + var(--tw-ring-offset-width)) var(--tw-ring-color);box-shadow:var(--tw-ring-offset-shadow),var(--tw-ring-shadow),var(--tw-shadow,0 0 #0000);--tw-ring-opacity:1;--tw-ring-color:rgb(232 163 61/var(--tw-ring-opacity,1));--tw-ring-offset-width:2px;--tw-ring-offset-color:#12141a}h1,h2,h3,h4{font-family:Space Grotesk,ui-sans-serif,system-ui,sans-serif}.card{border-radius:.875rem;border-width:1px;--tw-border-opacity:1;border-color:rgb(44 49 64/var(--tw-border-opacity,1));--tw-bg-opacity:1;background-color:rgb(27 30 39/var(--tw-bg-opacity,1));--tw-shadow:0 1px 0 0 hsla(0,0%,100%,.02) inset,0 8px 24px -12px rgba(0,0,0,.5);--tw-shadow-colored:inset 0 1px 0 0 var(--tw-shadow-color),0 8px 24px -12px var(--tw-shadow-color);box-shadow:var(--tw-ring-offset-shadow,0 0 #0000),var(--tw-ring-shadow,0 0 #0000),var(--tw-shadow)}.btn{display:inline-flex;align-items:center;justify-content:center;gap:.5rem;border-radius:.5rem;padding:.625rem 1rem;font-size:.875rem;line-height:1.25rem;font-weight:500;transition-property:color,background-color,border-color,text-decoration-color,fill,stroke;transition-timing-function:cubic-bezier(.4,0,.2,1);transition-duration:.15s}.btn:disabled{cursor:not-allowed;opacity:.5}.btn-primary{display:inline-flex;align-items:center;justify-content:center;gap:.5rem;border-radius:.5rem;padding:.625rem 1rem;font-size:.875rem;line-height:1.25rem;font-weight:500;transition-property:color,background-color,border-color,text-decoration-color,fill,stroke;transition-timing-function:cubic-bezier(.4,0,.2,1);transition-duration:.15s}.btn-primary:disabled{cursor:not-allowed;opacity:.5}.btn-primary{--tw-bg-opacity:1;background-color:rgb(232 163 61/var(--tw-bg-opacity,1));font-size:1rem;line-height:1.5rem;--tw-text-opacity:1;color:rgb(18 20 26/var(--tw-text-opacity,1))}.btn-primary:hover{--tw-bg-opacity:1;background-color:rgb(242 182 92/var(--tw-bg-opacity,1))}.btn-secondary{display:inline-flex;align-items:center;justify-content:center;gap:.5rem;border-radius:.5rem;padding:.625rem 1rem;font-size:.875rem;line-height:1.25rem;font-weight:500;transition-property:color,background-color,border-color,text-decoration-color,fill,stroke;transition-timing-function:cubic-bezier(.4,0,.2,1);transition-duration:.15s}.btn-secondary:disabled{cursor:not-allowed;opacity:.5}.btn-secondary{border-width:1px;--tw-border-opacity:1;border-color:rgb(44 49 64/var(--tw-border-opacity,1));--tw-bg-opacity:1;background-color:rgb(35 39 51/var(--tw-bg-opacity,1));--tw-text-opacity:1;color:rgb(237 238 242/var(--tw-text-opacity,1))}.btn-secondary:hover{--tw-border-opacity:1;border-color:rgb(84 91 110/var(--tw-border-opacity,1))}.btn-ghost{display:inline-flex;align-items:center;justify-content:center;gap:.5rem;border-radius:.5rem;padding:.625rem 1rem;font-size:.875rem;line-height:1.25rem;font-weight:500;transition-property:color,background-color,border-color,text-decoration-color,fill,stroke;transition-timing-function:cubic-bezier(.4,0,.2,1);transition-duration:.15s}.btn-ghost:disabled{cursor:not-allowed;opacity:.5}.btn-ghost{--tw-text-opacity:1;color:rgb(139 147 167/var(--tw-text-opacity,1))}.btn-ghost:hover{--tw-bg-opacity:1;background-color:rgb(35 39 51/var(--tw-bg-opacity,1));--tw-text-opacity:1;color:rgb(237 238 242/var(--tw-text-opacity,1))}.btn-danger{display:inline-flex;align-items:center;justify-content:center;gap:.5rem;border-radius:.5rem;padding:.625rem 1rem;font-size:.875rem;line-height:1.25rem;font-weight:500;transition-property:color,background-color,border-color,text-decoration-color,fill,stroke;transition-timing-function:cubic-bezier(.4,0,.2,1);transition-duration:.15s}.btn-danger:disabled{cursor:not-allowed;opacity:.5}.btn-danger{border-width:1px;border-color:rgba(242,99,123,.3);background-color:rgba(242,99,123,.1);--tw-text-opacity:1;color:rgb(242 99 123/var(--tw-text-opacity,1))}.btn-danger:hover{background-color:rgba(242,99,123,.2)}.field-label{margin-bottom:.375rem;display:block;font-size:.75rem;line-height:1rem;font-weight:500;text-transform:uppercase;letter-spacing:.025em;--tw-text-opacity:1;color:rgb(139 147 167/var(--tw-text-opacity,1))}.field-input{width:100%;border-radius:.5rem;border-width:1px;--tw-border-opacity:1;border-color:rgb(44 49 64/var(--tw-border-opacity,1));--tw-bg-opacity:1;background-color:rgb(35 39 51/var(--tw-bg-opacity,1));padding:.625rem .875rem;font-size:.875rem;line-height:1.25rem;--tw-text-opacity:1;color:rgb(237 238 242/var(--tw-text-opacity,1))}.field-input::-moz-placeholder{--tw-placeholder-opacity:1;color:rgb(84 91 110/var(--tw-placeholder-opacity,1))}.field-input::placeholder{--tw-placeholder-opacity:1;color:rgb(84 91 110/var(--tw-placeholder-opacity,1))}.field-input{transition-property:color,background-color,border-color,text-decoration-color,fill,stroke;transition-timing-function:cubic-bezier(.4,0,.2,1);transition-duration:.15s}.field-input:focus{--tw-border-opacity:1;border-color:rgb(232 163 61/var(--tw-border-opacity,1))}.field-error{margin-top:.375rem;font-size:.75rem;line-height:1rem;--tw-text-opacity:1;color:rgb(242 99 123/var(--tw-text-opacity,1))}.nav-link{display:flex;align-items:center;gap:.75rem;border-radius:.5rem;padding:.625rem .75rem;font-size:.875rem;line-height:1.25rem;font-weight:500;--tw-text-opacity:1;color:rgb(139 147 167/var(--tw-text-opacity,1));transition-property:color,background-color,border-color,text-decoration-color,fill,stroke;transition-timing-function:cubic-bezier(.4,0,.2,1);transition-duration:.15s}.nav-link:hover{--tw-bg-opacity:1;background-color:rgb(35 39 51/var(--tw-bg-opacity,1));--tw-text-opacity:1;color:rgb(237 238 242/var(--tw-text-opacity,1))}.nav-link-active{display:flex;align-items:center;gap:.75rem;border-radius:.5rem;padding:.625rem .75rem;font-size:.875rem;line-height:1.25rem;font-weight:500;color:rgb(139 147 167/var(--tw-text-opacity,1));transition-property:color,background-color,border-color,text-decoration-color,fill,stroke;transition-timing-function:cubic-bezier(.4,0,.2,1);transition-duration:.15s}.nav-link-active,.nav-link-active:hover{--tw-bg-opacity:1;background-color:rgb(35 39 51/var(--tw-bg-opacity,1));--tw-text-opacity:1;color:rgb(237 238 242/var(--tw-text-opacity,1))}.status-dot{display:inline-block;height:.625rem;width:.625rem;border-radius:9999px}.status-pill{display:inline-flex;align-items:center;gap:.5rem;border-radius:9999px;border-width:1px;padding:.375rem .75rem;font-size:.875rem;line-height:1.25rem;font-weight:500}.day-badge,.day-badge-on{display:flex;height:2.25rem;width:2.25rem;flex-shrink:0;align-items:center;justify-content:center;border-radius:.5rem;border-width:1px;--tw-border-opacity:1;border-color:rgb(44 49 64/var(--tw-border-opacity,1));--tw-bg-opacity:1;background-color:rgb(35 39 51/var(--tw-bg-opacity,1));font-size:.75rem;line-height:1rem;font-weight:600;text-transform:uppercase;letter-spacing:.025em;--tw-text-opacity:1;color:rgb(139 147 167/var(--tw-text-opacity,1))}.day-badge-on{border-color:rgba(232,163,61,.3);background-color:rgba(232,163,61,.1);color:rgb(232 163 61/var(--tw-text-opacity,1))}.pointer-events-none{pointer-events:none}.visible{visibility:visible}.static{position:static}.fixed{position:fixed}.absolute{position:absolute}.relative{position:relative}.sticky{position:sticky}.inset-0{inset:0}.inset-x-0{left:0;right:0}.inset-y-0{top:0;bottom:0}.bottom-12{bottom:3rem}.left-0{left:0}.top-0{top:0}.top-12{top:3rem}.z-30{z-index:30}.z-40{z-index:40}.z-50{z-index:50}.mx-auto{margin-left:auto;margin-right:auto}.-mt-2{margin-top:-.5rem}.mb-1{margin-bottom:.25rem}.mb-1\.5{margin-bottom:.375rem}.mb-10{margin-bottom:2.5rem}.mb-2{margin-bottom:.5rem}.mb-3{margin-bottom:.75rem}.mb-4{margin-bottom:1rem}.mb-5{margin-bottom:1.25rem}.mb-6{margin-bottom:1.5rem}.mb-8{margin-bottom:2rem}.ml-0{margin-left:0}.ml-2{margin-left:.5rem}.ml-5{margin-left:1.25rem}.ml-7{margin-left:1.75rem}.ml-auto{margin-left:auto}.mt-0\.5{margin-top:.125rem}.mt-1{margin-top:.25rem}.mt-1\.5{margin-top:.375rem}.mt-10{margin-top:2.5rem}.mt-2{margin-top:.5rem}.mt-3{margin-top:.75rem}.mt-4{margin-top:1rem}.mt-5{margin-top:1.25rem}.mt-6{margin-top:1.5rem}.mt-8{margin-top:2rem}.block{display:block}.inline-block{display:inline-block}.inline{display:inline}.flex{display:flex}.inline-flex{display:inline-flex}.table{display:table}.grid{display:grid}.hidden{display:none}.h-1\.5{height:.375rem}.h-10{height:2.5rem}.h-12{height:3rem}.h-16{height:4rem}.h-2{height:.5rem}.h-2\.5{height:.625rem}.h-3{height:.75rem}.h-3\.5{height:.875rem}.h-4{height:1rem}.h-5{height:1.25rem}.h-6{height:1.5rem}.h-72{height:18rem}.h-9{height:2.25rem}.h-\[18px\]{height:18px}.h-full{height:100%}.h-px{height:1px}.min-h-\[120px\]{min-height:120px}.min-h-full{min-height:100%}.min-h-screen{min-height:100vh}.w-1\.5{width:.375rem}.w-10{width:2.5rem}.w-12{width:3rem}.w-16{width:4rem}.w-2{width:.5rem}.w-2\.5{width:.625rem}.w-28{width:7rem}.w-3{width:.75rem}.w-3\.5{width:.875rem}.w-32{width:8rem}.w-4{width:1rem}.w-40{width:10rem}.w-5{width:1.25rem}.w-6{width:1.5rem}.w-72{width:18rem}.w-9{width:2.25rem}.w-\[18px\]{width:18px}.w-fit{width:-moz-fit-content;width:fit-content}.w-full{width:100%}.min-w-0{min-width:0}.max-w-2xl{max-width:42rem}.max-w-6xl{max-width:72rem}.max-w-lg{max-width:32rem}.max-w-md{max-width:28rem}.max-w-sm{max-width:24rem}.max-w-xs{max-width:20rem}.flex-1{flex:1 1 0%}.shrink-0{flex-shrink:0}.-translate-x-full{--tw-translate-x:-100%;transform:translate(var(--tw-translate-x),var(--tw-translate-y)) rotate(var(--tw-rotate)) skewX(var(--tw-skew-x)) skewY(var(--tw-skew-y)) scaleX(var(--tw-scale-x)) scaleY(var(--tw-scale-y))}@keyframes pulseSoft{0%,to{opacity:1}50%{opacity:.45}}.animate-pulse-soft{animation:pulseSoft 2.2s ease-in-out infinite}.cursor-not-allowed{cursor:not-allowed}.cursor-pointer{cursor:pointer}.list-disc{list-style-type:disc}.grid-cols-1{grid-template-columns:repeat(1,minmax(0,1fr))}.grid-cols-2{grid-template-columns:repeat(2,minmax(0,1fr))}.grid-cols-3{grid-template-columns:repeat(3,minmax(0,1fr))}.grid-cols-7{grid-template-columns:repeat(7,minmax(0,1fr))}.flex-col{flex-direction:column}.flex-wrap{flex-wrap:wrap}.items-start{align-items:flex-start}.items-end{align-items:flex-end}.items-center{align-items:center}.justify-center{justify-content:center}.justify-between{justify-content:space-between}.gap-1{gap:.25rem}.gap-1\.5{gap:.375rem}.gap-2{gap:.5rem}.gap-2\.5{gap:.625rem}.gap-3{gap:.75rem}.gap-3\.5{gap:.875rem}.gap-4{gap:1rem}.gap-6{gap:1.5rem}.gap-x-4{-moz-column-gap:1rem;column-gap:1rem}.gap-y-1\.5{row-gap:.375rem}.gap-y-3{row-gap:.75rem}.space-y-1>:not([hidden])~:not([hidden]){--tw-space-y-reverse:0;margin-top:calc(.25rem*(1 - var(--tw-space-y-reverse)));margin-bottom:calc(.25rem*var(--tw-space-y-reverse))}.space-y-1\.5>:not([hidden])~:not([hidden]){--tw-space-y-reverse:0;margin-top:calc(.375rem*(1 - var(--tw-space-y-reverse)));margin-bottom:calc(.375rem*var(--tw-space-y-reverse))}.space-y-2>:not([hidden])~:not([hidden]){--tw-space-y-reverse:0;margin-top:calc(.5rem*(1 - var(--tw-space-y-reverse)));margin-bottom:calc(.5rem*var(--tw-space-y-reverse))}.space-y-2\.5>:not([hidden])~:not([hidden]){--tw-space-y-reverse:0;margin-top:calc(.625rem*(1 - var(--tw-space-y-reverse)));margin-bottom:calc(.625rem*var(--tw-space-y-reverse))}.space-y-3>:not([hidden])~:not([hidden]){--tw-space-y-reverse:0;margin-top:calc(.75rem*(1 - var(--tw-space-y-reverse)));margin-bottom:calc(.75rem*var(--tw-space-y-reverse))}.space-y-4>:not([hidden])~:not([hidden]){--tw-space-y-reverse:0;margin-top:calc(1rem*(1 - var(--tw-space-y-reverse)));margin-bottom:calc(1rem*var(--tw-space-y-reverse))}.space-y-6>:not([hidden])~:not([hidden]){--tw-space-y-reverse:0;margin-top:calc(1.5rem*(1 - var(--tw-space-y-reverse)));margin-bottom:calc(1.5rem*var(--tw-space-y-reverse))}.space-y-8>:not([hidden])~:not([hidden]){--tw-space-y-reverse:0;margin-top:calc(2rem*(1 - var(--tw-space-y-reverse)));margin-bottom:calc(2rem*var(--tw-space-y-reverse))}.divide-y>:not([hidden])~:not([hidden]){--tw-divide-y-reverse:0;border-top-width:calc(1px*(1 - var(--tw-divide-y-reverse)));border-bottom-width:calc(1px*var(--tw-divide-y-reverse))}.divide-border>:not([hidden])~:not([hidden]){--tw-divide-opacity:1;border-color:rgb(44 49 64/var(--tw-divide-opacity,1))}.self-start{align-self:flex-start}.overflow-hidden,.truncate{overflow:hidden}.truncate{text-overflow:ellipsis;white-space:nowrap}.whitespace-pre-line{white-space:pre-line}.rounded{border-radius:.25rem}.rounded-full{border-radius:9999px}.rounded-lg{border-radius:.5rem}.rounded-md{border-radius:.375rem}.border{border-width:1px}.border-b{border-bottom-width:1px}.border-r{border-right-width:1px}.border-t{border-top-width:1px}.border-accent\/30{border-color:rgba(232,163,61,.3)}.border-accent\/40{border-color:rgba(232,163,61,.4)}.border-accent\/50{border-color:rgba(232,163,61,.5)}.border-border{--tw-border-opacity:1;border-color:rgb(44 49 64/var(--tw-border-opacity,1))}.border-status-available{--tw-border-opacity:1;border-color:rgb(61 220 151/var(--tw-border-opacity,1))}.border-status-available\/30{border-color:rgba(61,220,151,.3)}.border-status-away{--tw-border-opacity:1;border-color:rgb(91 141 239/var(--tw-border-opacity,1))}.border-status-away\/30{border-color:rgba(91,141,239,.3)}.border-status-busy{--tw-border-opacity:1;border-color:rgb(242 99 123/var(--tw-border-opacity,1))}.border-status-busy\/30{border-color:rgba(242,99,123,.3)}.border-status-busy\/40{border-color:rgba(242,99,123,.4)}.border-status-offline{--tw-border-opacity:1;border-color:rgb(91 100 120/var(--tw-border-opacity,1))}.border-status-unavailable{--tw-border-opacity:1;border-color:rgb(185 139 242/var(--tw-border-opacity,1))}.bg-accent{--tw-bg-opacity:1;background-color:rgb(232 163 61/var(--tw-bg-opacity,1))}.bg-accent-muted{--tw-bg-opacity:1;background-color:rgb(58 45 24/var(--tw-bg-opacity,1))}.bg-accent-muted\/40{background-color:rgba(58,45,24,.4)}.bg-base{--tw-bg-opacity:1;background-color:rgb(18 20 26/var(--tw-bg-opacity,1))}.bg-base\/95{background-color:rgba(18,20,26,.95)}.bg-black\/50{background-color:rgba(0,0,0,.5)}.bg-black\/60{background-color:rgba(0,0,0,.6)}.bg-border{--tw-bg-opacity:1;background-color:rgb(44 49 64/var(--tw-bg-opacity,1))}.bg-current{background-color:currentColor}.bg-ink-faint{--tw-bg-opacity:1;background-color:rgb(84 91 110/var(--tw-bg-opacity,1))}.bg-status-available{--tw-bg-opacity:1;background-color:rgb(61 220 151/var(--tw-bg-opacity,1))}.bg-status-available\/10{background-color:rgba(61,220,151,.1)}.bg-status-away{--tw-bg-opacity:1;background-color:rgb(91 141 239/var(--tw-bg-opacity,1))}.bg-status-away\/10{background-color:rgba(91,141,239,.1)}.bg-status-busy{--tw-bg-opacity:1;background-color:rgb(242 99 123/var(--tw-bg-opacity,1))}.bg-status-busy\/10{background-color:rgba(242,99,123,.1)}.bg-status-offline{--tw-bg-opacity:1;background-color:rgb(91 100 120/var(--tw-bg-opacity,1))}.bg-status-unavailable{--tw-bg-opacity:1;background-color:rgb(185 139 242/var(--tw-bg-opacity,1))}.bg-surface{--tw-bg-opacity:1;background-color:rgb(27 30 39/var(--tw-bg-opacity,1))}.bg-surface-raised{--tw-bg-opacity:1;background-color:rgb(35 39 51/var(--tw-bg-opacity,1))}.bg-gradient-to-b{background-image:linear-gradient(to bottom,var(--tw-gradient-stops))}.bg-gradient-to-br{background-image:linear-gradient(to bottom right,var(--tw-gradient-stops))}.from-accent-muted\/40{--tw-gradient-from:rgba(58,45,24,.4) var(--tw-gradient-from-position);--tw-gradient-to:rgba(58,45,24,0) var(--tw-gradient-to-position);--tw-gradient-stops:var(--tw-gradient-from),var(--tw-gradient-to)}.from-accent-muted\/50{--tw-gradient-from:rgba(58,45,24,.5) var(--tw-gradient-from-position);--tw-gradient-to:rgba(58,45,24,0) var(--tw-gradient-to-position);--tw-gradient-stops:var(--tw-gradient-from),var(--tw-gradient-to)}.via-transparent{--tw-gradient-to:transparent var(--tw-gradient-to-position);--tw-gradient-stops:var(--tw-gradient-from),transparent var(--tw-gradient-via-position),var(--tw-gradient-to)}.to-transparent{--tw-gradient-to:transparent var(--tw-gradient-to-position)}.p-1{padding:.25rem}.p-2{padding:.5rem}.p-4{padding:1rem}.p-5{padding:1.25rem}.p-6{padding:1.5rem}.p-8{padding:2rem}.\!px-2{padding-left:.5rem!important;padding-right:.5rem!important}.\!px-2\.5{padding-left:.625rem!important;padding-right:.625rem!important}.\!px-3{padding-left:.75rem!important;padding-right:.75rem!important}.\!py-1{padding-top:.25rem!important;padding-bottom:.25rem!important}.\!py-1\.5{padding-top:.375rem!important;padding-bottom:.375rem!important}.px-1{padding-left:.25rem;padding-right:.25rem}.px-1\.5{padding-left:.375rem;padding-right:.375rem}.px-3{padding-left:.75rem;padding-right:.75rem}.px-4{padding-left:1rem;padding-right:1rem}.px-5{padding-left:1.25rem;padding-right:1.25rem}.px-6{padding-left:1.5rem;padding-right:1.5rem}.py-0\.5{padding-top:.125rem;padding-bottom:.125rem}.py-1{padding-top:.25rem;padding-bottom:.25rem}.py-1\.5{padding-top:.375rem;padding-bottom:.375rem}.py-10{padding-top:2.5rem;padding-bottom:2.5rem}.py-12{padding-top:3rem;padding-bottom:3rem}.py-16{padding-top:4rem;padding-bottom:4rem}.py-2{padding-top:.5rem;padding-bottom:.5rem}.py-2\.5{padding-top:.625rem;padding-bottom:.625rem}.py-3{padding-top:.75rem;padding-bottom:.75rem}.py-3\.5{padding-top:.875rem;padding-bottom:.875rem}.py-6{padding-top:1.5rem;padding-bottom:1.5rem}.py-8{padding-top:2rem;padding-bottom:2rem}.pb-1\.5{padding-bottom:.375rem}.pl-3{padding-left:.75rem}.pr-1\.5{padding-right:.375rem}.pt-4{padding-top:1rem}.pt-5{padding-top:1.25rem}.text-left{text-align:left}.text-center{text-align:center}.font-display{font-family:Space Grotesk,ui-sans-serif,system-ui,sans-serif}.font-mono{font-family:ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,Liberation Mono,Courier New,monospace}.text-2xl{font-size:1.5rem;line-height:2rem}.text-3xl{font-size:1.875rem;line-height:2.25rem}.text-6xl{font-size:3.75rem;line-height:1}.text-\[10px\]{font-size:10px}.text-\[11px\]{font-size:11px}.text-base{font-size:1rem;line-height:1.5rem}.text-lg{font-size:1.125rem;line-height:1.75rem}.text-sm{font-size:.875rem;line-height:1.25rem}.text-xl{font-size:1.25rem;line-height:1.75rem}.text-xs{font-size:.75rem;line-height:1rem}.font-medium{font-weight:500}.font-normal{font-weight:400}.font-semibold{font-weight:600}.uppercase{text-transform:uppercase}.capitalize{text-transform:capitalize}.italic{font-style:italic}.leading-relaxed{line-height:1.625}.leading-tight{line-height:1.25}.tracking-\[0\.3em\]{letter-spacing:.3em}.tracking-wide{letter-spacing:.025em}.tracking-wider{letter-spacing:.05em}.text-accent{--tw-text-opacity:1;color:rgb(232 163 61/var(--tw-text-opacity,1))}.text-base{--tw-text-opacity:1;color:rgb(18 20 26/var(--tw-text-opacity,1))}.text-ink{--tw-text-opacity:1;color:rgb(237 238 242/var(--tw-text-opacity,1))}.text-ink-faint{--tw-text-opacity:1;color:rgb(84 91 110/var(--tw-text-opacity,1))}.text-ink-muted{--tw-text-opacity:1;color:rgb(139 147 167/var(--tw-text-opacity,1))}.text-status-available{--tw-text-opacity:1;color:rgb(61 220 151/var(--tw-text-opacity,1))}.text-status-away{--tw-text-opacity:1;color:rgb(91 141 239/var(--tw-text-opacity,1))}.text-status-busy{--tw-text-opacity:1;color:rgb(242 99 123/var(--tw-text-opacity,1))}.text-status-busy\/90{color:rgba(242,99,123,.9)}.text-status-offline{--tw-text-opacity:1;color:rgb(91 100 120/var(--tw-text-opacity,1))}.text-status-unavailable{--tw-text-opacity:1;color:rgb(185 139 242/var(--tw-text-opacity,1))}.underline{text-decoration-line:underline}.opacity-30{opacity:.3}.opacity-50{opacity:.5}.opacity-60{opacity:.6}.shadow-card{--tw-shadow:0 1px 0 0 hsla(0,0%,100%,.02) inset,0 8px 24px -12px rgba(0,0,0,.5);--tw-shadow-colored:inset 0 1px 0 0 var(--tw-shadow-color),0 8px 24px -12px var(--tw-shadow-color);box-shadow:var(--tw-ring-offset-shadow,0 0 #0000),var(--tw-ring-shadow,0 0 #0000),var(--tw-shadow)}.filter{filter:var(--tw-blur) var(--tw-brightness) var(--tw-contrast) var(--tw-grayscale) var(--tw-hue-rotate) var(--tw-invert) var(--tw-saturate) var(--tw-sepia) var(--tw-drop-shadow)}.backdrop-blur{--tw-backdrop-blur:blur(8px)}.backdrop-blur,.backdrop-blur-sm{-webkit-backdrop-filter:var(--tw-backdrop-blur) var(--tw-backdrop-brightness) var(--tw-backdrop-contrast) var(--tw-backdrop-grayscale) var(--tw-backdrop-hue-rotate) var(--tw-backdrop-invert) var(--tw-backdrop-opacity) var(--tw-backdrop-saturate) var(--tw-backdrop-sepia);backdrop-filter:var(--tw-backdrop-blur) var(--tw-backdrop-brightness) var(--tw-backdrop-contrast) var(--tw-backdrop-grayscale) var(--tw-backdrop-hue-rotate) var(--tw-backdrop-invert) var(--tw-backdrop-opacity) var(--tw-backdrop-saturate) var(--tw-backdrop-sepia)}.backdrop-blur-sm{--tw-backdrop-blur:blur(4px)}.transition-colors{transition-property:color,background-color,border-color,text-decoration-color,fill,stroke;transition-timing-function:cubic-bezier(.4,0,.2,1);transition-duration:.15s}.transition-transform{transition-property:transform;transition-timing-function:cubic-bezier(.4,0,.2,1);transition-duration:.15s}.duration-200{transition-duration:.2s}html[data-view=mobile] .vm-topbar,html[data-view=tablet] .vm-topbar{display:flex!important}html[data-view=mobile] .vm-sidebar,html[data-view=tablet] .vm-sidebar{position:fixed!important;display:flex!important;transform:translateX(-100%)!important}html[data-view=mobile] .vm-sidebar.vm-open,html[data-view=tablet] .vm-sidebar.vm-open{transform:translateX(0)!important}html[data-view=mobile] .vm-main{padding:1rem!important}html[data-view=tablet] .vm-main{max-width:42rem!important;margin-inline:auto!important;padding:1.75rem 1.5rem!important}html[data-view=tablet] .vm-main .max-w-6xl{max-width:none!important}html[data-view=desktop] .vm-topbar{display:none!important}html[data-view=desktop] .vm-sidebar{position:static!important;display:flex!important;transform:none!important}html[data-view=desktop] .vm-main{padding:2.5rem!important}.last\:border-r-0:last-child{border-right-width:0}.hover\:border-accent:hover{--tw-border-opacity:1;border-color:rgb(232 163 61/var(--tw-border-opacity,1))}.hover\:border-accent\/50:hover{border-color:rgba(232,163,61,.5)}.hover\:border-ink-faint:hover{--tw-border-opacity:1;border-color:rgb(84 91 110/var(--tw-border-opacity,1))}.hover\:bg-status-busy\/10:hover{background-color:rgba(242,99,123,.1)}.hover\:bg-surface-raised:hover{--tw-bg-opacity:1;background-color:rgb(35 39 51/var(--tw-bg-opacity,1))}.hover\:text-accent:hover{--tw-text-opacity:1;color:rgb(232 163 61/var(--tw-text-opacity,1))}.hover\:text-ink:hover{--tw-text-opacity:1;color:rgb(237 238 242/var(--tw-text-opacity,1))}.hover\:text-ink-muted:hover{--tw-text-opacity:1;color:rgb(139 147 167/var(--tw-text-opacity,1))}.hover\:text-status-busy:hover{--tw-text-opacity:1;color:rgb(242 99 123/var(--tw-text-opacity,1))}.hover\:underline:hover{text-decoration-line:underline}.focus\:ring-accent:focus{--tw-ring-opacity:1;--tw-ring-color:rgb(232 163 61/var(--tw-ring-opacity,1))}.focus\:ring-offset-base:focus{--tw-ring-offset-color:#12141a}.group:hover .group-hover\:text-accent{--tw-text-opacity:1;color:rgb(232 163 61/var(--tw-text-opacity,1))}@media (min-width:640px){.sm\:col-span-2{grid-column:span 2/span 2}.sm\:ml-\[8\.25rem\]{margin-left:8.25rem}.sm\:inline-flex{display:inline-flex}.sm\:hidden{display:none}.sm\:grid-cols-2{grid-template-columns:repeat(2,minmax(0,1fr))}.sm\:grid-cols-3{grid-template-columns:repeat(3,minmax(0,1fr))}.sm\:grid-cols-4{grid-template-columns:repeat(4,minmax(0,1fr))}.sm\:flex-row{flex-direction:row}.sm\:items-end{align-items:flex-end}.sm\:items-center{align-items:center}.sm\:justify-between{justify-content:space-between}.sm\:gap-2{gap:.5rem}.sm\:p-5{padding:1.25rem}.sm\:p-6{padding:1.5rem}.sm\:p-7{padding:1.75rem}.sm\:p-8{padding:2rem}.sm\:px-6{padding-left:1.5rem;padding-right:1.5rem}.sm\:py-14{padding-top:3.5rem;padding-bottom:3.5rem}.sm\:py-16{padding-top:4rem;padding-bottom:4rem}.sm\:text-2xl{font-size:1.5rem;line-height:2rem}}@media (min-width:1024px){.lg\:static{position:static}.lg\:col-span-1{grid-column:span 1/span 1}.lg\:col-span-2{grid-column:span 2/span 2}.lg\:block{display:block}.lg\:flex{display:flex}.lg\:grid{display:grid}.lg\:hidden{display:none}.lg\:min-h-0{min-height:0}.lg\:w-64{width:16rem}.lg\:shrink-0{flex-shrink:0}.lg\:translate-x-0{--tw-translate-x:0px;transform:translate(var(--tw-translate-x),var(--tw-translate-y)) rotate(var(--tw-rotate)) skewX(var(--tw-skew-x)) skewY(var(--tw-skew-y)) scaleX(var(--tw-scale-x)) scaleY(var(--tw-scale-y))}.lg\:grid-cols-2{grid-template-columns:repeat(2,minmax(0,1fr))}.lg\:grid-cols-3{grid-template-columns:repeat(3,minmax(0,1fr))}.lg\:flex-col{flex-direction:column}.lg\:justify-center{justify-content:center}.lg\:p-12{padding:3rem}.lg\:px-10{padding-left:2.5rem;padding-right:2.5rem}.lg\:px-8{padding-left:2rem;padding-right:2rem}.lg\:py-10{padding-top:2.5rem;padding-bottom:2.5rem}.lg\:text-left{text-align:left}}@media (min-width:1280px){.xl\:bottom-16{bottom:4rem}.xl\:top-16{top:4rem}.xl\:p-16{padding:4rem}}
CLAUDE_PATCH_EOF

echo "Files written."

bold() { printf "\033[1m%s\033[0m\n" "$1"; }
cd "$APP_DIR"
bold "== Restarting $SERVICE_NAME =="
sudo systemctl restart "$SERVICE_NAME"

sleep 2
CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PORT}/support/isp" 2>/dev/null || echo 000)
if [ "$CODE" = "200" ]; then bold "Done — ISP support form responding."
else echo "Did not respond as expected (HTTP $CODE) — check: sudo journalctl -u $SERVICE_NAME -n 50"; fi
