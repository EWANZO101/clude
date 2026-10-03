"""Polls the Scheduler database and sends Discord DMs.

Runs inside the bot's own asyncio loop as a periodic task (see bot.py).
Polling — rather than the Flask app pushing events to the bot directly —
keeps the two processes fully decoupled: gunicorn workers never need to
know the bot exists, and the bot can be restarted, redeployed, or down
for a while without losing anything. Every DM type has a boolean
sent-flag on the row it's about, so a restart or a slow poll cycle never
produces a duplicate.

Every notification fans out to every ID in
Settings.all_discord_recipient_ids() — the primary discord_user_id plus
any DiscordRecipient rows — so a second person can be added to get the
same alerts and pings.

Every send is wrapped in try/except, same rule as app/services/email.py —
a Discord hiccup (rate limit, a recipient left the shared server,
whatever) must never crash the poll loop or block the next booking's
reminder.
"""

import logging
import os
from datetime import datetime, timedelta, timezone as dt_timezone

import discord

from app import db
from app.models.booking import ACTIVE_BOOKING_STATUSES, Booking, BookingPingState
from app.models.settings import Settings
from app.services.status import local_now

from discord_bot.embeds import (
    build_15min_reminder_embed,
    build_cancelled_embed,
    build_day_start_embed,
    build_hour_reminder_embed,
    build_new_booking_embed,
    build_ping_embed,
    build_test_embed,
)
from discord_bot.views import StopPingView

logger = logging.getLogger("discord_bot.notifier")

HOUR_WINDOW = timedelta(hours=1)
FIFTEEN_MIN_WINDOW = timedelta(minutes=15)
PING_INTERVAL = timedelta(seconds=int(os.environ.get("DISCORD_PING_INTERVAL_SECONDS", "30")))


async def _dm(client, discord_user_id, embed, what, view=None):
    """Fetch the user and send them the embed. Logs and swallows failures —
    a bad ID, a revoked share-a-server, or a Discord outage should never
    take down the poll loop. Returns the sent Message, or None on failure."""
    try:
        user_id = int(discord_user_id)
    except (TypeError, ValueError):
        logger.warning("Skipping %s: discord_user_id %r isn't a valid ID", what, discord_user_id)
        return None
    try:
        discord_user = client.get_user(user_id) or await client.fetch_user(user_id)
        kwargs = {"embed": embed}
        if view is not None:
            kwargs["view"] = view
        message = await discord_user.send(**kwargs)
        logger.info("Sent %s to Discord user %s", what, user_id)
        return message
    except discord.Forbidden:
        logger.warning(
            "Couldn't DM %s for %s — they must share a server with the bot, or have DM'd it before.",
            user_id, what,
        )
    except discord.NotFound:
        logger.warning("Discord user ID %s not found (for %s) — check it's correct.", user_id, what)
    except Exception:  # noqa: BLE001 - a Discord failure must never break the poll loop
        logger.exception("Failed to send %s to Discord user %s", what, user_id)
    return None


async def _dm_all(client, settings_row, embed, what):
    """Send the same embed to every recipient (primary + DiscordRecipient
    rows). Fire-and-forget — used for notifications nothing needs to track
    or delete later (new booking, cancellation, reminders, test)."""
    for recipient_id in settings_row.all_discord_recipient_ids():
        await _dm(client, recipient_id, embed, what)


async def _delete_dm_message(client, discord_user_id, message_id):
    if not message_id:
        return
    try:
        user_id = int(discord_user_id)
        discord_user = client.get_user(user_id) or await client.fetch_user(user_id)
        channel = discord_user.dm_channel or await discord_user.create_dm()
        message = await channel.fetch_message(int(message_id))
        await message.delete()
    except discord.NotFound:
        pass  # already gone — fine
    except Exception:  # noqa: BLE001 - cleanup failures shouldn't break anything else
        logger.exception("Failed to delete old ping message %s", message_id)


async def _handle_test_requests(client):
    for settings_row in Settings.query.filter(Settings.discord_test_requested_at.isnot(None)).all():
        await _dm_all(client, settings_row, build_test_embed(), "test DM")
        settings_row.discord_test_requested_at = None
    db.session.commit()


async def _handle_new_bookings(client):
    bookings = Booking.query.filter(
        Booking.discord_new_notified.is_(False),
        Booking.status.in_(ACTIVE_BOOKING_STATUSES),
    ).all()
    for booking in bookings:
        settings_row = Settings.for_user(booking.user)
        recipients = settings_row.all_discord_recipient_ids()
        if recipients and settings_row.notify_discord_new_booking:
            await _dm_all(client, settings_row, build_new_booking_embed(booking), f"new-booking DM (#{booking.id})")
            if settings_row.discord_spam_ping_enabled:
                for recipient_id in recipients:
                    db.session.add(BookingPingState(booking_id=booking.id, discord_user_id=recipient_id, active=True))
        booking.discord_new_notified = True
    if bookings:
        db.session.commit()


async def _handle_cancellations(client):
    bookings = Booking.query.filter(
        Booking.discord_cancel_notified.is_(False),
        Booking.status == "cancelled",
        Booking.cancelled_at.isnot(None),
    ).all()
    for booking in bookings:
        settings_row = Settings.for_user(booking.user)
        if settings_row.all_discord_recipient_ids() and settings_row.notify_discord_cancellation:
            await _dm_all(client, settings_row, build_cancelled_embed(booking), f"cancellation DM (#{booking.id})")
        booking.discord_cancel_notified = True
        for ping_state in booking.ping_states:
            if ping_state.active:
                await _delete_dm_message(client, ping_state.discord_user_id, ping_state.last_message_id)
                ping_state.active = False
                ping_state.last_message_id = None
    if bookings:
        db.session.commit()


async def _handle_day_start(client, users):
    for user in users:
        settings_row = Settings.for_user(user)
        if not (settings_row.all_discord_recipient_ids() and settings_row.notify_discord_reminders):
            continue
        now = local_now(user)
        todays = Booking.query.filter(
            Booking.user_id == user.id,
            Booking.status.in_(ACTIVE_BOOKING_STATUSES),
            Booking.discord_day_reminder_sent.is_(False),
            Booking.start_datetime >= datetime.combine(now.date(), datetime.min.time()),
            Booking.start_datetime < datetime.combine(now.date(), datetime.max.time()),
            Booking.start_datetime > now,
        ).order_by(Booking.start_datetime.asc()).all()
        if todays:
            await _dm_all(client, settings_row, build_day_start_embed(todays), "day-start digest")
            for booking in todays:
                booking.discord_day_reminder_sent = True
            db.session.commit()


async def _handle_timed_reminders(client, users):
    for user in users:
        settings_row = Settings.for_user(user)
        if not (settings_row.all_discord_recipient_ids() and settings_row.notify_discord_reminders):
            continue
        now = local_now(user)

        hour_due = Booking.query.filter(
            Booking.user_id == user.id,
            Booking.status.in_(ACTIVE_BOOKING_STATUSES),
            Booking.discord_hour_reminder_sent.is_(False),
            Booking.start_datetime > now,
            Booking.start_datetime <= now + HOUR_WINDOW,
        ).all()
        for booking in hour_due:
            await _dm_all(client, settings_row, build_hour_reminder_embed(booking), f"1-hour reminder (#{booking.id})")
            booking.discord_hour_reminder_sent = True

        fifteen_due = Booking.query.filter(
            Booking.user_id == user.id,
            Booking.status.in_(ACTIVE_BOOKING_STATUSES),
            Booking.discord_15min_reminder_sent.is_(False),
            Booking.start_datetime > now,
            Booking.start_datetime <= now + FIFTEEN_MIN_WINDOW,
        ).all()
        for booking in fifteen_due:
            await _dm_all(client, settings_row, build_15min_reminder_embed(booking), f"15-minute reminder (#{booking.id})")
            booking.discord_15min_reminder_sent = True

        if hour_due or fifteen_due:
            db.session.commit()


async def run_ping_tick(app, client):
    """Fires the repeated 'spam ping' DMs — one independent session per
    recipient per booking (BookingPingState). Called on its own fast
    timer (bot.py), separate from the main poll() loop, since pings need
    a much shorter cadence than everything else.

    Ping 1 is sent immediately (from _handle_new_bookings, one
    BookingPingState row created per recipient). From ping 2 onward, each
    recipient's previous ping message is deleted right before their next
    one goes out, so only ever one ping is visible per person at a time —
    right up until that person presses Stop, which only affects their own
    session, not anyone else's.
    """
    with app.app_context():
        try:
            now_utc = datetime.now(dt_timezone.utc).replace(tzinfo=None)
            active_states = BookingPingState.query.filter(BookingPingState.active.is_(True)).all()
            for state in active_states:
                booking = state.booking
                settings_row = Settings.for_user(booking.user)
                if not settings_row.discord_spam_ping_enabled:
                    state.active = False
                    continue

                # Nothing left to nag about once it's started/cancelled/etc.
                if booking.status not in ACTIVE_BOOKING_STATUSES or booking.start_datetime <= local_now(booking.user):
                    state.active = False
                    if state.last_message_id:
                        await _delete_dm_message(client, state.discord_user_id, state.last_message_id)
                        state.last_message_id = None
                    continue

                due_at = (state.last_sent_at or datetime.min) + PING_INTERVAL
                if now_utc < due_at:
                    continue

                next_ping_number = state.count + 1
                view = StopPingView(booking.id, state.discord_user_id)
                message = await _dm(
                    client, state.discord_user_id, build_ping_embed(booking, next_ping_number),
                    f"ping #{next_ping_number} (#{booking.id} -> {state.discord_user_id})", view=view,
                )
                if message is None:
                    # Couldn't send (Forbidden/etc) — stop trying rather than loop forever.
                    state.active = False
                    continue

                client.add_view(view, message_id=message.id)

                # From ping 2 onward, delete the one before it.
                if next_ping_number >= 2 and state.last_message_id:
                    await _delete_dm_message(client, state.discord_user_id, state.last_message_id)

                state.count = next_ping_number
                state.last_sent_at = now_utc
                state.last_message_id = str(message.id)

            db.session.commit()
        except Exception:  # noqa: BLE001 - one bad tick must not kill the loop
            db.session.rollback()
            logger.exception("Discord bot ping tick failed")


async def resume_active_ping_views(app, client):
    """Called once from on_ready — re-registers a StopPingView for every
    session still marked active, so Stop keeps working after a restart
    even though the in-memory view objects from before are gone."""
    with app.app_context():
        active_states = BookingPingState.query.filter(BookingPingState.active.is_(True)).all()
        for state in active_states:
            client.add_view(StopPingView(state.booking_id, state.discord_user_id))
        if active_states:
            logger.info("Re-registered %d active ping session(s) after restart.", len(active_states))


async def poll(app, client):
    """One full poll cycle. Called on a timer from bot.py."""
    from app.models.user import User

    with app.app_context():
        try:
            users = User.query.all()
            await _handle_test_requests(client)
            await _handle_new_bookings(client)
            await _handle_cancellations(client)
            await _handle_day_start(client, users)
            await _handle_timed_reminders(client, users)
        except Exception:  # noqa: BLE001 - one bad poll must not kill the loop
            db.session.rollback()
            logger.exception("Discord bot poll cycle failed")
