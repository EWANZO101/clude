"""Computes "is a scheduled cloud backup due right now" — the same
lazy, purely-server-side philosophy as update_scheduling.py's
next_occurrence_utc/UpdateDeployment.target_time_utc: nothing here runs on
a timer. agent_api.py's get_pending_command calls is_backup_due() on every
single poll and only THEN decides whether to queue a backup_now command,
so there's no separate scheduler process to keep alive or get out of sync.

Unlike update_scheduling.py, the timezone here is per-instance and
arbitrary (whatever IANA zone the company picked for their Backups tab),
not a single hard-coded Europe/London — see Instance.backup_timezone.
"""
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError, available_timezones

UTC = ZoneInfo("UTC")


def available_backup_timezones():
    """IANA zone names for the Backups tab's timezone picker — the
    standard Region/City names plus UTC, excluding the noisy legacy
    aliases (bare names like "Factory"/"WET", and the posix/right
    variants) that available_timezones() also returns but nobody
    actually wants in a dropdown."""
    names = {tz for tz in available_timezones() if "/" in tz and not tz.startswith(("posix/", "right/"))}
    names.add("UTC")
    return sorted(names)


def is_backup_due(instance, now_utc: datetime = None) -> bool:
    """True if `instance` has cloud backups enabled, a schedule configured,
    and today's (in the instance's own timezone) scheduled time has passed
    without a backup having been taken since. Naturally self-healing if a
    poll is missed — it stays true (not just for one instant) until a
    backup actually lands and last_cloud_backup_at advances past today's
    slot, so a kiosk that's offline right at the scheduled moment still
    catches up the next time it's reachable, same as a missed update
    schedule would."""
    if not instance.backup_cloud_enabled:
        return False
    if instance.backup_time is None or not instance.backup_timezone:
        return False

    try:
        tz = ZoneInfo(instance.backup_timezone)
    except (ZoneInfoNotFoundError, ValueError):
        return False  # a bad/removed tz name shouldn't ever fire spuriously

    now_utc = now_utc or datetime.utcnow()
    now_utc_aware = now_utc.replace(tzinfo=UTC)
    now_local = now_utc_aware.astimezone(tz)

    scheduled_today_local = now_local.replace(
        hour=instance.backup_time.hour, minute=instance.backup_time.minute,
        second=0, microsecond=0,
    )
    if now_local < scheduled_today_local:
        return False  # today's slot hasn't arrived yet

    scheduled_today_utc = scheduled_today_local.astimezone(UTC).replace(tzinfo=None)
    if instance.last_cloud_backup_at is not None and instance.last_cloud_backup_at >= scheduled_today_utc:
        return False  # already covered today's slot

    return True


def next_occurrence_utc(instance, now_utc: datetime = None):
    """For display only ("Next backup: ...") — the actual trigger is
    is_backup_due() above, this never gates anything."""
    if instance.backup_time is None or not instance.backup_timezone:
        return None
    try:
        tz = ZoneInfo(instance.backup_timezone)
    except (ZoneInfoNotFoundError, ValueError):
        return None

    now_utc = now_utc or datetime.utcnow()
    now_local = now_utc.replace(tzinfo=UTC).astimezone(tz)
    candidate_local = now_local.replace(
        hour=instance.backup_time.hour, minute=instance.backup_time.minute,
        second=0, microsecond=0,
    )
    if candidate_local <= now_local:
        candidate_local += timedelta(days=1)
    return candidate_local.astimezone(UTC).replace(tzinfo=None)
