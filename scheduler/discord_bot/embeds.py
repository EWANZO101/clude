"""Builds the discord.Embed objects sent by the notifier.

Kept separate from notifier.py so the "what it looks like" and "when it
gets sent" concerns don't tangle. Every embed follows the same shape —
title, a coloured left bar, a handful of inline fields, an optional notes
block, and a footer — so DMs read as one consistent, professional-looking
notification stream rather than a grab-bag of formats.
"""

import os
from datetime import datetime, timezone as dt_timezone

import discord

APP_NAME = "Scheduler"
BASE_URL = os.environ.get("DISCORD_APP_BASE_URL", "").rstrip("/")

COLOR_NEW = 0x22C55E       # green — something landed
COLOR_CANCELLED = 0xEF4444  # red — something was removed
COLOR_DAY = 0x3B82F6        # blue — informational, plenty of notice
COLOR_HOUR = 0xF59E0B       # amber — getting closer
COLOR_15MIN = 0xF97316       # orange — act now
COLOR_TEST = 0x8B5CF6        # purple — distinct from every real alert
COLOR_PING_NEW = 0xDC2626      # red — the repeated nag for a new booking
COLOR_PING_OOH = 0xB91C1C      # deeper red — out-of-hours nag, needs a decision


def _service_name(booking):
    return booking.booking_type.name if booking.booking_type else "Meeting"


def _duration_minutes(booking):
    delta = booking.end_datetime - booking.start_datetime
    return int(delta.total_seconds() // 60)


def _date_field(booking):
    return booking.start_datetime.strftime("%A %d %B %Y")


def _time_field(booking):
    return f"{booking.start_datetime.strftime('%H:%M')} \u2013 {booking.end_datetime.strftime('%H:%M')}"


def _manage_url(booking):
    if not BASE_URL:
        return None
    return f"{BASE_URL}/admin/bookings/{booking.id}"


def _base_embed(title, color, description=None):
    embed = discord.Embed(title=title, color=color, description=description, timestamp=datetime.now(dt_timezone.utc))
    embed.set_footer(text=APP_NAME)
    return embed


def _add_booking_fields(embed, booking, include_contact=True):
    embed.add_field(name="Service", value=f"{_service_name(booking)} ({_duration_minutes(booking)} min)", inline=True)
    embed.add_field(name="Date", value=_date_field(booking), inline=True)
    embed.add_field(name="Time", value=_time_field(booking), inline=True)
    if include_contact:
        contact = booking.email if not booking.phone else f"{booking.email}\n{booking.phone}"
        embed.add_field(name="Booked by", value=f"{booking.name}\n{contact}", inline=False)
    if booking.notes:
        note = booking.notes if len(booking.notes) <= 500 else booking.notes[:497] + "..."
        embed.add_field(name="Notes", value=note, inline=False)
    url = _manage_url(booking)
    if url:
        embed.add_field(name="\u200b", value=f"[View in dashboard]({url})", inline=False)
    return embed


def build_new_booking_embed(booking):
    embed = _base_embed("\U0001F4C5 New booking", COLOR_NEW, f"**{booking.name}** just booked time with you.")
    return _add_booking_fields(embed, booking)


def build_cancelled_embed(booking):
    embed = _base_embed("\u274C Booking cancelled", COLOR_CANCELLED, f"**{booking.name}** cancelled their booking.")
    return _add_booking_fields(embed, booking)


def build_day_start_embed(bookings):
    """One embed listing every booking for today, sent once when the day starts."""
    embed = _base_embed(
        f"\u2600\uFE0F Today's schedule \u2014 {len(bookings)} booking{'s' if len(bookings) != 1 else ''}",
        COLOR_DAY,
    )
    for booking in bookings:
        contact = booking.email if not booking.phone else f"{booking.email} \u00b7 {booking.phone}"
        embed.add_field(
            name=f"{booking.start_datetime.strftime('%H:%M')} \u2013 {_service_name(booking)}",
            value=f"{booking.name} ({contact})",
            inline=False,
        )
    return embed


def build_hour_reminder_embed(booking):
    embed = _base_embed("\u23F0 Starting in 1 hour", COLOR_HOUR, f"Your booking with **{booking.name}** starts in an hour.")
    return _add_booking_fields(embed, booking)


def build_15min_reminder_embed(booking):
    embed = _base_embed("\U0001F6A8 Starting in 15 minutes", COLOR_15MIN, f"Your booking with **{booking.name}** starts in 15 minutes.")
    return _add_booking_fields(embed, booking)


def build_ping_embed(booking, ping_number):
    """The repeated nag DM. Distinct red styling + a growing ping count so
    it's obviously different from the one-off new-booking embed, and the
    admin can see at a glance how long it's been going unacknowledged."""
    if booking.is_out_of_hours:
        title = "\u26A0\uFE0F OUT-OF-HOURS BOOKING \u2014 needs a look"
        color = COLOR_PING_OOH
        description = f"**{booking.name}** booked outside your working hours. Still unacknowledged."
    else:
        title = "\U0001F514 NEW BOOKING \u2014 needs a look"
        color = COLOR_PING_NEW
        description = f"**{booking.name}** booked with you. Still unacknowledged."

    embed = _base_embed(title, color, description)
    embed = _add_booking_fields(embed, booking)
    embed.add_field(name="\u200b", value=f"Ping #{ping_number} \u2014 press Stop below to silence this.", inline=False)
    return embed


def build_test_embed():
    embed = _base_embed(
        "\u2705 Test notification",
        COLOR_TEST,
        "If you can see this, your Discord ID is set up correctly and the bot can reach you.",
    )
    embed.add_field(
        name="What you'll get",
        value=(
            "\u2022 New booking alerts\n"
            "\u2022 Cancellation alerts\n"
            "\u2022 A daily schedule at the start of the day\n"
            "\u2022 A reminder 1 hour before each booking\n"
            "\u2022 A reminder 15 minutes before each booking\n"
            "\u2022 Repeated pings for new/out-of-hours bookings until you hit Stop"
        ),
        inline=False,
    )
    return embed
