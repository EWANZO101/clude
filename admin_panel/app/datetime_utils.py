"""Friendlier datetime rendering for templates. All stored timestamps are
naive UTC (see models.py), so formatting and the "time ago" comparison
both work directly against datetime.utcnow() with no timezone conversion
needed.

Three filters, for three different spots:
- friendly_dt    -> full stamp + a muted relative line underneath (HTML).
                    For a table cell / kv-table row that IS the timestamp,
                    with nothing else sharing the cell.
- friendly_dtstr  -> full stamp as plain text, no relative line, no HTML.
                    For a timestamp sitting inside a sentence (e.g.
                    "target: ...", "Last request: ... by ...") where the
                    two-line markup would break the surrounding text.
- friendly_date   -> date only ("09 Sep 2026"), plain text. For compact
                    date-only columns (invited/signed-up date, "since ...").
"""
from datetime import datetime, timedelta

from markupsafe import Markup, escape

_STAMP_FORMAT = "%d %b %Y, %H:%M UTC"
_DATE_FORMAT = "%d %b %Y"


def _relative(dt: datetime) -> str:
    delta = (datetime.utcnow() - dt).total_seconds()
    future = delta < 0
    seconds = abs(delta)

    if seconds < 60:
        value, unit = int(seconds), "second"
    elif seconds < 3600:
        value, unit = int(seconds // 60), "minute"
    elif seconds < 86400:
        value, unit = int(seconds // 3600), "hour"
    elif seconds < 86400 * 30:
        value, unit = int(seconds // 86400), "day"
    elif seconds < 86400 * 365:
        value, unit = int(seconds // (86400 * 30)), "month"
    else:
        value, unit = int(seconds // (86400 * 365)), "year"

    plural = "" if value == 1 else "s"
    return f"in {value} {unit}{plural}" if future else f"{value} {unit}{plural} ago"


def friendly_dt(dt: datetime) -> Markup:
    """'09 Sep 2026, 13:47 UTC' with a muted relative '2 hours ago' line
    underneath — replaces a bare '%Y-%m-%d %H:%M UTC' stamp sitting alone
    in a cell."""
    if dt is None:
        return Markup("—")
    primary = dt.strftime(_STAMP_FORMAT)
    return Markup(
        f"{escape(primary)}"
        f'<span class="muted" style="font-size:11.5px; display:block; margin-top:2px;">{escape(_relative(dt))}</span>'
    )


def friendly_dtstr(dt: datetime) -> str:
    """Plain '09 Sep 2026, 13:47 UTC', no relative line — for a timestamp
    embedded inside a sentence rather than alone in a cell."""
    if dt is None:
        return "—"
    return dt.strftime(_STAMP_FORMAT)


def friendly_date(dt: datetime) -> str:
    """Plain '09 Sep 2026', no time — for compact date-only columns."""
    if dt is None:
        return "—"
    return dt.strftime(_DATE_FORMAT)


def friendly_local_dt(dt: datetime) -> str:
    """Plain '09 Sep 2026, 13:47', no UTC suffix and no relative line — for
    a timestamp that is NOT UTC (e.g. dev_files.py's file mtimes, which are
    datetime.fromtimestamp() in the server's local time). Labeling one of
    those "UTC" via friendly_dt would just be wrong, and computing a
    relative offset against datetime.utcnow() would be off by the server's
    local/UTC skew, so this deliberately omits both."""
    if dt is None:
        return "—"
    return dt.strftime("%d %b %Y, %H:%M")


def group_by_month_week(items, dt_getter):
    """Buckets `items` (expected already ordered most-recent-first by the
    datetime dt_getter returns for each) into month groups, each holding
    week sub-groups, each holding the items for that week — the shape the
    releases and platform-dashboard pages render as collapsible accordions
    instead of one long flat table. Only the single most-recent week (the
    first one seen) is marked open=True; everything else defaults collapsed.
    Items with no date from dt_getter are dropped — there's no week to file
    them under. Each week group's items live under the key "rows" rather
    than "items" — Jinja resolves `week.items` to dict.items() (a bound
    method, not the list) before ever trying `week["items"]`, so "items"
    would silently break in templates."""
    months = []
    current_month = None
    current_week = None
    first_week = True

    for item in items:
        dt = dt_getter(item)
        if dt is None:
            continue

        month_key = (dt.year, dt.month)
        if current_month is None or current_month["key"] != month_key:
            current_month = {"key": month_key, "label": dt.strftime("%B %Y"), "weeks": [], "count": 0}
            months.append(current_month)
            current_week = None

        week_start = dt.date() - timedelta(days=dt.weekday())
        if current_week is None or current_week["key"] != week_start:
            week_end = week_start + timedelta(days=6)
            if week_start.month == week_end.month:
                label = f"Week of {week_start.strftime('%d')}–{week_end.strftime('%d %b %Y')}"
            else:
                label = f"Week of {week_start.strftime('%d %b')}–{week_end.strftime('%d %b %Y')}"
            current_week = {"key": week_start, "label": label, "rows": [], "open": first_week}
            current_month["weeks"].append(current_week)
            first_week = False

        current_week["rows"].append(item)
        current_month["count"] += 1

    return months
