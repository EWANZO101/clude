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

calendarmaker_bp = Blueprint("calendarmaker", __name__, url_prefix="/clandermaker")


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
