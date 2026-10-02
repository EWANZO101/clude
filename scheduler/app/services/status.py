"""Computes the user's current status.

Priority, matching the plan:
    1. An active manual override
    2. Time off covering right now             -> away
    3. Inside working hours, inside a break     -> busy
    4. Inside working hours, otherwise          -> available
    5. Outside working hours entirely           -> offline
"""

from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

from app.models.settings import Settings
from app.models.time_off import TimeOff
from app.services.availability import get_next_available, get_working_hours_for_day


def local_now(user):
    """The current time in the user's configured timezone, as a naive datetime.

    Naive because every stored time (working hours, breaks, time off) is
    naive-in-local-time too — see the TimeOff model docstring.
    """
    tz = ZoneInfo(user.timezone or "UTC")
    return datetime.now(tz).replace(tzinfo=None)


def _format_when(dt, now):
    if dt is None:
        return None
    if dt.date() == now.date():
        return f"Today at {dt.strftime('%H:%M')}"
    if dt.date() == (now + timedelta(days=1)).date():
        return f"Tomorrow at {dt.strftime('%H:%M')}"
    return dt.strftime("%a %d %b at %H:%M")


def get_current_status(user):
    """Returns a dict: status, message, is_manual, next_available (formatted string or None)."""
    now = local_now(user)
    settings = Settings.for_user(user)

    if settings.manual_status and (
        settings.manual_status_expires_at is None or settings.manual_status_expires_at > now
    ):
        next_available = None
        if settings.manual_status != "available":
            next_available = _format_when(get_next_available(user, now), now)
        return {
            "status": settings.manual_status,
            "message": settings.manual_status_message,
            "is_manual": True,
            "next_available": next_available,
        }

    active_time_off = TimeOff.query.filter(
        TimeOff.user_id == user.id,
        TimeOff.start_datetime <= now,
        TimeOff.end_datetime > now,
    ).first()
    if active_time_off:
        return {
            "status": "away",
            "message": active_time_off.reason,
            "is_manual": False,
            "next_available": _format_when(get_next_available(user, now), now),
        }

    working_hours = get_working_hours_for_day(user, now.date())
    if working_hours and working_hours.enabled and working_hours.start_time and working_hours.end_time:
        day_start = datetime.combine(now.date(), working_hours.start_time)
        day_end = datetime.combine(now.date(), working_hours.end_time)

        if day_start <= now < day_end:
            for b in working_hours.breaks:
                b_start = datetime.combine(now.date(), b.start_time)
                b_end = datetime.combine(now.date(), b.end_time)
                if b_start <= now < b_end:
                    return {
                        "status": "busy",
                        "message": b.label,
                        "is_manual": False,
                        "next_available": _format_when(b_end, now),
                    }
            return {"status": "available", "message": None, "is_manual": False, "next_available": None}

    return {
        "status": "offline",
        "message": None,
        "is_manual": False,
        "next_available": _format_when(get_next_available(user, now), now),
    }
