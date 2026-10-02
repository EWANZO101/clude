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
