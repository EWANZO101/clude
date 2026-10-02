from datetime import datetime, time as dt_time, timezone as dt_timezone

from flask import Blueprint, make_response, redirect, render_template, request, url_for

from app import db
from app.forms import CSRFOnlyForm, ShareLinkPinForm, TimeOffForm
from app.models.time_off import TimeOff, TimeOffShareLink
from app.services.calendar import build_time_off_grid
from app.services.pin_access import (
    clear_attempts,
    clear_unlocked,
    is_locked_out,
    is_unlocked,
    record_failed_attempt,
    set_unlocked,
)

timeoff_share_bp = Blueprint("timeoff_share", __name__, url_prefix="/time-off")

NAMESPACE = "timeoff"


def _get_link_or_404(token):
    return TimeOffShareLink.query.filter_by(token=token).first_or_404()


def _unlocked(link):
    return is_unlocked(request, NAMESPACE, link.token) if link.pin_protected else True


@timeoff_share_bp.route("/<token>", methods=["GET", "POST"])
def gate(token):
    link = _get_link_or_404(token)

    if not link.pin_protected or _unlocked(link):
        return redirect(url_for("timeoff_share.calendar_view", token=token))

    form = ShareLinkPinForm()
    if form.validate_on_submit():
        if is_locked_out(NAMESPACE, token):
            form.pin.errors.append("Too many incorrect attempts. Please wait a few minutes and try again.")
        elif link.check_pin(form.pin.data):
            clear_attempts(NAMESPACE, token)
            resp = make_response(redirect(url_for("timeoff_share.calendar_view", token=token)))
            set_unlocked(resp, NAMESPACE, token)
            return resp
        else:
            record_failed_attempt(NAMESPACE, token)
            form.pin.errors.append("Incorrect PIN.")

    return render_template("timeoff_share/gate.html", link=link, form=form)


@timeoff_share_bp.route("/<token>/calendar", methods=["GET", "POST"])
def calendar_view(token):
    link = _get_link_or_404(token)
    if not _unlocked(link):
        return redirect(url_for("timeoff_share.gate", token=token))

    owner = link.user
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
                user_id=owner.id,
                start_datetime=start_dt,
                end_datetime=end_dt,
                all_day=form.all_day.data,
                reason=form.reason.data.strip() if form.reason.data else None,
            )
        )
        link.last_used_at = datetime.now(dt_timezone.utc)
        db.session.commit()
        return redirect(url_for("timeoff_share.calendar_view", token=token))

    today = datetime.utcnow().date()
    year = request.args.get("year", type=int) or today.year
    month = request.args.get("month", type=int) or today.month
    if not (1 <= month <= 12):
        month = today.month

    days, meta = build_time_off_grid(owner, year, month)

    entries = (
        TimeOff.query.filter_by(user_id=owner.id)
        .order_by(TimeOff.start_datetime.desc())
        .limit(30)
        .all()
    )

    return render_template(
        "timeoff_share/calendar.html",
        link=link,
        owner=owner,
        form=form,
        days=days,
        today=today,
        entries=entries,
        delete_form=CSRFOnlyForm(),
        **meta,
    )


@timeoff_share_bp.route("/<token>/entries/<int:time_off_id>/delete", methods=["POST"])
def delete_entry(token, time_off_id):
    link = _get_link_or_404(token)
    if not _unlocked(link):
        return redirect(url_for("timeoff_share.gate", token=token))

    form = CSRFOnlyForm()
    if form.validate_on_submit():
        entry = TimeOff.query.filter_by(id=time_off_id, user_id=link.user_id).first_or_404()
        db.session.delete(entry)
        db.session.commit()

    return redirect(url_for("timeoff_share.calendar_view", token=token))


@timeoff_share_bp.route("/<token>/lock", methods=["POST"])
def lock(token):
    link = _get_link_or_404(token)
    resp = make_response(redirect(url_for("timeoff_share.gate", token=token)))
    clear_unlocked(resp, NAMESPACE, token)
    return resp
