"""Builds the data behind the admin calendar view.

Per the plan: "The calendar should NOT be the source of truth for
availability." This module only reads and summarizes what the availability
engine, time off, and bookings already say — it doesn't compute anything
that would need to agree with `app/services/availability.py` separately.
"""

import calendar as calendar_module
from datetime import datetime, time as dt_time, timedelta

from app.models.booking import ACTIVE_BOOKING_STATUSES, Booking
from app.models.time_off import TimeOff
from app.services.availability import get_working_hours_for_day


def _day_entry(user, target_date, in_month):
    day_start = datetime.combine(target_date, dt_time.min)
    day_end = datetime.combine(target_date, dt_time.max)

    working_hours = get_working_hours_for_day(user, target_date)
    is_working_day = bool(working_hours and working_hours.enabled)

    time_offs = TimeOff.query.filter(
        TimeOff.user_id == user.id,
        TimeOff.start_datetime < day_end,
        TimeOff.end_datetime > day_start,
    ).all()

    bookings = (
        Booking.query.filter(
            Booking.user_id == user.id,
            Booking.status.in_(ACTIVE_BOOKING_STATUSES),
            Booking.start_datetime >= day_start,
            Booking.start_datetime <= day_end,
        )
        .order_by(Booking.start_datetime)
        .all()
    )

    return {
        "date": target_date,
        "in_month": in_month,
        "is_working_day": is_working_day,
        "working_hours": working_hours if is_working_day else None,
        "breaks": working_hours.breaks if is_working_day else [],
        "time_offs": time_offs,
        "bookings": bookings,
    }


def _grid_dates(year, month):
    first_of_month = datetime(year, month, 1).date()
    days_in_month = calendar_module.monthrange(year, month)[1]
    last_of_month = first_of_month.replace(day=days_in_month)

    grid_start = first_of_month - timedelta(days=first_of_month.weekday())
    total_days_needed = (last_of_month - grid_start).days + 1
    weeks_needed = -(-total_days_needed // 7)  # ceil division

    dates = [grid_start + timedelta(days=i) for i in range(weeks_needed * 7)]

    prev_month_date = first_of_month - timedelta(days=1)
    next_month_date = last_of_month + timedelta(days=1)

    meta = {
        "month_label": first_of_month.strftime("%B %Y"),
        "prev_year": prev_month_date.year,
        "prev_month": prev_month_date.month,
        "next_year": next_month_date.year,
        "next_month": next_month_date.month,
    }
    return dates, meta


def build_month_grid(user, year, month):
    """Returns (days, meta) — `days` is a flat list of day entries covering
    full weeks (Monday-start) for the given month, `meta` has navigation info."""
    dates, meta = _grid_dates(year, month)
    days = [_day_entry(user, d, in_month=(d.month == month and d.year == year)) for d in dates]
    return days, meta


def build_time_off_grid(user, year, month):
    """Same shape as build_month_grid, but deliberately leaves out bookings
    and working-hours detail — for surfaces (like a time-off share link)
    that should only ever see/manage time off, never booking/client info."""
    dates, meta = _grid_dates(year, month)
    days = []
    for d in dates:
        day_start = datetime.combine(d, dt_time.min)
        day_end = datetime.combine(d, dt_time.max)
        time_offs = TimeOff.query.filter(
            TimeOff.user_id == user.id,
            TimeOff.start_datetime < day_end,
            TimeOff.end_datetime > day_start,
        ).all()
        days.append(
            {
                "date": d,
                "in_month": (d.month == month and d.year == year),
                "time_offs": time_offs,
            }
        )
    return days, meta
