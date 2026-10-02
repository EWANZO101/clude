from datetime import datetime, time, timedelta
from zoneinfo import ZoneInfo


def _load_uk_tz() -> ZoneInfo:
    """Loads the Europe/London tz. Windows ships no IANA tz database of its
    own (unlike Linux/macOS), so zoneinfo depends on the 'tzdata' PyPI
    package being installed in *this* process's environment — easy to miss
    on a machine with multiple Python installs even though it's listed in
    requirements.txt. Rather than crash the whole app on import over a
    missing dependency, try to install it automatically once and retry
    before giving up."""
    try:
        return ZoneInfo("Europe/London")
    except Exception:
        import logging
        import subprocess
        import sys

        log = logging.getLogger("app.update_scheduling")
        log.warning("tzdata not available for ZoneInfo('Europe/London') — "
                    "attempting to install it into %s ...", sys.executable)
        try:
            subprocess.check_call([sys.executable, "-m", "pip", "install", "-q", "tzdata"])
            return ZoneInfo("Europe/London")
        except Exception:
            log.error(
                "Could not load 'Europe/London' tzdata even after attempting "
                "to auto-install the tzdata package. Falling back to a fixed "
                "UTC offset with NO daylight-saving adjustment — 9pm-UK "
                "scheduling will be off by an hour during BST (late March to "
                "late October). Fix properly by running: "
                "%s -m pip install tzdata", sys.executable,
            )
            from datetime import timezone
            return timezone.utc


UK_TZ = _load_uk_tz()
SYSTEM_DEFAULT_UPDATE_TIME = time(21, 0)  # 9:00 PM UK, spec Sections 20-22


def resolve_update_time_of_day(instance):
    """Priority hierarchy from spec Section 24 (most specific wins), for the
    *recurring* schedule only — an explicit one-time custom pick is handled
    separately in schedule_deployment() below, since it isn't a time-of-day
    at all but a specific date+time.

    Returns (time_obj, source) where source is one of
    'kiosk' | 'company' | 'system_default'.
    """
    if instance.scheduled_update_time is not None:
        return instance.scheduled_update_time, "kiosk"
    if instance.company.default_update_time is not None:
        return instance.company.default_update_time, "company"
    return SYSTEM_DEFAULT_UPDATE_TIME, "system_default"


def next_occurrence_utc(time_of_day: time, now_utc: datetime = None) -> datetime:
    """Next future moment (in UTC) that 'time_of_day' occurs in the
    Europe/London timezone. Deliberately timezone-aware rather than a fixed
    UTC offset (spec Section 21: 'must use the actual UK local timezone and
    automatically handle British Summer Time and GMT... not simply
    hard-code a UTC offset') — zoneinfo's Europe/London handles the BST/GMT
    transition automatically.
    """
    now_utc = now_utc or datetime.utcnow().replace(tzinfo=ZoneInfo("UTC"))
    if now_utc.tzinfo is None:
        now_utc = now_utc.replace(tzinfo=ZoneInfo("UTC"))
    now_uk = now_utc.astimezone(UK_TZ)

    candidate_uk = now_uk.replace(
        hour=time_of_day.hour, minute=time_of_day.minute, second=0, microsecond=0
    )
    if candidate_uk <= now_uk:
        candidate_uk += timedelta(days=1)

    return candidate_uk.astimezone(ZoneInfo("UTC")).replace(tzinfo=None)


def resolve_deployment_target(instance, mode: str, custom_datetime_utc: datetime = None):
    """Computes (target_time_utc, schedule_source) for a push based on the
    chosen mode:
      - 'now'      -> immediate, source 'now'
      - 'custom'   -> an explicit one-time pick (highest priority — spec
                      Section 24's "Individual Scheduled Update"), source
                      'individual'
      - 'schedule' -> apply the recurring priority hierarchy (kiosk ->
                      company -> system default) and compute its next
                      occurrence in UK local time
    """
    if mode == "now":
        return datetime.utcnow(), "now"
    if mode == "custom":
        if custom_datetime_utc is None:
            raise ValueError("custom_datetime_utc is required when mode='custom'")
        return custom_datetime_utc, "individual"
    if mode == "schedule":
        time_of_day, source = resolve_update_time_of_day(instance)
        return next_occurrence_utc(time_of_day), source
    raise ValueError(f"unknown schedule mode: {mode!r}")
