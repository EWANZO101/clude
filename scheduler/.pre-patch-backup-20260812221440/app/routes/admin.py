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

            if end_time <= start_time:
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
