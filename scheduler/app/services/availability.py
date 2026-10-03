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


def compute_out_of_hours_intervals(user, target_date, busy_periods=None):
    """Free (start, end) datetime intervals OUTSIDE `user`'s normal working
    hours on `target_date` — the complement of compute_available_intervals.

    Still honors breaks, time off, and busy_periods (bookings) the same
    way the normal-hours computation does; only the working-hours gate
    itself is lifted. On a day marked off entirely (enabled=False), the
    whole day counts as "outside working hours".
    """
    working_hours = get_working_hours_for_day(user, target_date)
    day_full_start = datetime.combine(target_date, dt_time.min)
    day_full_end = datetime.combine(target_date + timedelta(days=1), dt_time.min)

    if working_hours and working_hours.enabled and working_hours.start_time and working_hours.end_time:
        in_hours_start = datetime.combine(target_date, working_hours.start_time)
        in_hours_end = _day_end_datetime(target_date, working_hours.end_time)
        intervals = subtract_intervals([(day_full_start, day_full_end)], [(in_hours_start, in_hours_end)])
    else:
        intervals = [(day_full_start, day_full_end)]

    if working_hours:
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
