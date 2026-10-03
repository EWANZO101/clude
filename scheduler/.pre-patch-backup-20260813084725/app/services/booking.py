"""Turns free intervals into concrete bookable slots, and creates bookings.

Slot generation plugs straight into the Phase 2 availability engine via its
`busy_periods` argument — existing bookings (expanded by their own type's
buffers) are just another kind of blocked time, same as breaks or time off.
"""

from datetime import datetime, time as dt_time, timedelta

from app import db
from app.models.booking import ACTIVE_BOOKING_STATUSES, Booking
from app.services.availability import compute_available_intervals
from app.services.status import local_now


def get_busy_periods(user, range_start, range_end, exclude_booking_id=None):
    """Active bookings overlapping [range_start, range_end), each expanded by its own buffers."""
    query = Booking.query.filter(
        Booking.user_id == user.id,
        Booking.status.in_(ACTIVE_BOOKING_STATUSES),
        Booking.start_datetime < range_end,
        Booking.end_datetime > range_start,
    )
    if exclude_booking_id:
        query = query.filter(Booking.id != exclude_booking_id)

    busy = []
    for booking in query.all():
        bt = booking.booking_type
        before = timedelta(minutes=bt.buffer_before) if bt else timedelta()
        after = timedelta(minutes=bt.buffer_after) if bt else timedelta()
        busy.append((booking.start_datetime - before, booking.end_datetime + after))
    return busy


def get_available_slots(user, booking_type, target_date):
    """Bookable start times for `booking_type` on `target_date`, in the user's local time."""
    if not booking_type.enabled:
        return []

    day_start = datetime.combine(target_date, dt_time.min)
    day_end = datetime.combine(target_date, dt_time.max)
    busy = get_busy_periods(user, day_start, day_end)

    free_intervals = compute_available_intervals(user, target_date, busy_periods=busy)

    duration = timedelta(minutes=booking_type.duration)
    buffer_before = timedelta(minutes=booking_type.buffer_before)
    buffer_after = timedelta(minutes=booking_type.buffer_after)

    slots = []
    for interval_start, interval_end in free_intervals:
        cursor = interval_start
        while cursor + duration <= interval_end:
            slot_start, slot_end = cursor, cursor + duration
            # The slot's own buffer must also fit inside this free interval —
            # buffers are protected spacing, not just a display concern.
            if slot_start - buffer_before >= interval_start and slot_end + buffer_after <= interval_end:
                slots.append(slot_start)
            cursor += duration

    now = local_now(user)
    return [s for s in slots if s > now]


class SlotUnavailableError(Exception):
    pass


def create_booking(user, booking_type, start_dt, name, email, phone, notes):
    """Creates a booking after re-confirming the slot is still free.

    Re-checking here (rather than trusting the slot the person clicked a
    minute ago) closes the obvious race: two people booking the same slot
    at nearly the same time.
    """
    end_dt = start_dt + timedelta(minutes=booking_type.duration)

    buffer_before = timedelta(minutes=booking_type.buffer_before)
    buffer_after = timedelta(minutes=booking_type.buffer_after)
    check_start = start_dt - buffer_before
    check_end = end_dt + buffer_after

    still_free = compute_available_intervals(
        user,
        start_dt.date(),
        busy_periods=get_busy_periods(user, check_start, check_end),
    )
    if not any(iv_start <= check_start and check_end <= iv_end for iv_start, iv_end in still_free):
        raise SlotUnavailableError("That time is no longer available.")

    booking = Booking(
        user_id=user.id,
        booking_type_id=booking_type.id,
        name=name.strip(),
        email=email.strip().lower(),
        phone=(phone or "").strip() or None,
        notes=(notes or "").strip() or None,
        start_datetime=start_dt,
        end_datetime=end_dt,
        status="confirmed",
    )
    db.session.add(booking)
    db.session.commit()
    return booking
