#!/usr/bin/env bash
# Scheduler patch — root domain now lands on the booking page instead of a
# 404, and the sign-in page has a clear "book an appointment" link so
# customers who land there aren't stuck. Paste this whole block into a
# terminal on the server.
set -euo pipefail

APP_DIR="${APP_DIR:-/root/scheduler}"
SERVICE_NAME="${SERVICE_NAME:-scheduler}"
PORT="${PORT:-5076}"

[ -f "$APP_DIR/run.py" ] || { echo "APP_DIR ($APP_DIR) doesn't look like the scheduler app — set APP_DIR=/path first."; exit 1; }

ts=$(date +%Y%m%d%H%M%S)
mkdir -p "$APP_DIR/.pre-patch-backup-$ts"
[ -f "$APP_DIR/app/routes/public.py" ] && { mkdir -p "$APP_DIR/.pre-patch-backup-$ts/$(dirname app/routes/public.py)"; cp "$APP_DIR/app/routes/public.py" "$APP_DIR/.pre-patch-backup-$ts/app/routes/public.py"; } || true
[ -f "$APP_DIR/app/templates/auth/login.html" ] && { mkdir -p "$APP_DIR/.pre-patch-backup-$ts/$(dirname app/templates/auth/login.html)"; cp "$APP_DIR/app/templates/auth/login.html" "$APP_DIR/.pre-patch-backup-$ts/app/templates/auth/login.html"; } || true

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
from app.services.booking import SlotUnavailableError, create_booking, get_available_slots
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

    # Bounce back to slot picking if this exact time isn't offered anymore
    # (e.g. someone else just booked it, or it's now in the past).
    if start_dt not in get_available_slots(owner, booking_type, start_dt.date()):
        flash("That time isn't available anymore — please pick another.", "error")
        return redirect(url_for("public.pick_slot", type_id=type_id, date=start_dt.date().isoformat()))

    form = PublicBookingDetailsForm()

    if form.validate_on_submit():
        try:
            booking = create_booking(
                owner,
                booking_type,
                start_dt,
                form.name.data,
                form.email.data,
                form.phone.data,
                form.notes.data,
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

mkdir -p "$APP_DIR/app/templates/auth"
cat > "$APP_DIR/app/templates/auth/login.html" << 'CLAUDE_PATCH_EOF'
{% extends "base.html" %}
{% block title %}Sign in · {{ app_name }}{% endblock %}
{% block body %}
<div class="min-h-screen lg:grid lg:grid-cols-2">

  <!-- Desktop/tablet-landscape only: branding panel -->
  <div class="relative hidden overflow-hidden bg-surface lg:flex lg:flex-col lg:justify-between lg:p-12 xl:p-16">
    <div class="pointer-events-none absolute inset-0 bg-gradient-to-br from-accent-muted/40 via-transparent to-transparent"></div>

    <div class="relative flex items-center gap-2 font-display text-lg font-semibold text-ink">
      <span class="status-dot bg-accent"></span>
      {{ app_name }}
    </div>

    <div class="relative max-w-md">
      <h1 class="font-display text-3xl font-semibold leading-tight text-ink xl:text-4xl">
        Your schedule, on your own server.
      </h1>
      <p class="mt-4 text-sm leading-relaxed text-ink-muted">
        Set your hours, share one link, and let people book time that actually
        works for you — no third party holding your calendar data.
      </p>

      <a href="{{ url_for('public.booking_types') }}" class="card mt-8 block max-w-xs p-5 hover:border-accent/50 transition-colors group">
        <div class="flex items-center justify-between">
          <span class="text-sm font-medium text-ink">Looking to book time?</span>
          <span class="status-pill border-status-available/30 bg-status-available/10 text-status-available !py-1 !px-2.5 text-xs">
            <span class="status-dot h-2 w-2 bg-status-available animate-pulse-soft"></span>
            Available
          </span>
        </div>
        <p class="mt-2 text-xs text-ink-muted">This sign-in page is for the owner. Customers book here &rarr;</p>
      </a>
    </div>

    <p class="relative text-xs text-ink-faint">Self-hosted · Open source · Your data stays with you</p>
  </div>

  <!-- Form: centered on every size, the only thing shown on mobile/tablet-portrait -->
  <div class="flex min-h-screen flex-col items-center justify-center px-4 py-12 lg:min-h-0 lg:px-8">
    <div class="w-full max-w-sm">

      <div class="mb-8 flex flex-col items-center text-center lg:hidden">
        <span class="status-pill border-accent/30 bg-accent-muted text-accent mb-4">
          <span class="status-dot bg-accent animate-pulse-soft"></span>
          {{ app_name }}
        </span>
      </div>

      <div class="mb-6 text-center lg:text-left">
        <h1 class="font-display text-2xl font-semibold text-ink">Sign in</h1>
        <p class="mt-1.5 text-sm text-ink-muted">Owner sign-in — manage your schedule and bookings.</p>
      </div>

      <a href="{{ url_for('public.booking_types') }}" class="mb-6 flex items-center justify-between gap-3 rounded-lg border border-accent/30 bg-accent-muted/60 px-4 py-3 text-sm hover:border-accent/50 transition-colors lg:hidden">
        <span class="text-ink">Just want to book an appointment?</span>
        <span class="shrink-0 font-medium text-accent">Book now &rarr;</span>
      </a>

      {% include "partials/flash.html" %}

      <div class="card p-6 sm:p-7">
        <form method="POST" action="{{ url_for('auth.login') }}" novalidate>
          {{ form.hidden_tag() }}

          <div class="mb-4">
            <label class="field-label" for="{{ form.email.id }}">Email</label>
            {{ form.email(class_="field-input", placeholder="you@example.com", autocomplete="email", autofocus=true) }}
            {% for error in form.email.errors %}
              <p class="field-error">{{ error }}</p>
            {% endfor %}
          </div>

          <div class="mb-4">
            <label class="field-label" for="{{ form.password.id }}">Password</label>
            {{ form.password(class_="field-input", placeholder="••••••••", autocomplete="current-password") }}
            {% for error in form.password.errors %}
              <p class="field-error">{{ error }}</p>
            {% endfor %}
          </div>

          <label class="mb-6 flex items-center gap-2 text-sm text-ink-muted">
            {{ form.remember_me(class_="rounded border-border bg-surface-raised text-accent focus:ring-accent focus:ring-offset-base") }}
            Keep me signed in
          </label>

          <button type="submit" class="btn-primary w-full">Sign in</button>
        </form>
      </div>

      <p class="mt-6 text-center text-xs text-ink-faint lg:text-left">
        Not the owner?
        <a href="{{ url_for('public.booking_types') }}" class="text-accent hover:underline">Book an appointment</a>
        instead.
      </p>
    </div>
  </div>

</div>
{% endblock %}
CLAUDE_PATCH_EOF

echo "Files written."

bold() { printf "\033[1m%s\033[0m\n" "$1"; }
cd "$APP_DIR"

bold "== Restarting $SERVICE_NAME =="
sudo systemctl restart "$SERVICE_NAME"

sleep 2
CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PORT}/" 2>/dev/null || echo 000)
if [ "$CODE" = "200" ] || [ "$CODE" = "302" ]; then bold "Done — root path responding (HTTP $CODE)."
else echo "Root path did not respond as expected (HTTP $CODE) — check: sudo journalctl -u $SERVICE_NAME -n 50"; fi
