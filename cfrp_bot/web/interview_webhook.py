"""
web/interview_webhook.py
────────────────────────
Flask Blueprint: POST /webhook/interview-booked

The Flask website calls this endpoint whenever a user books an interview.
This module posts a rich embed to the staff interview channel and pings
the staff role via the Discord bot.

Registered in main.py exactly like report_webhook:
    from web.interview_webhook import interview_webhook, set_bot as _set_interview_bot
    app.register_blueprint(interview_webhook)
    _set_interview_bot(bot)
"""

import asyncio
import logging
import os
from datetime import datetime, timezone

import discord
from flask import Blueprint, request, jsonify

log = logging.getLogger("cfrp_bot.interview_webhook")

# ── Config (read from environment / .env) ────────────────────────────────────
INTERVIEW_CHANNEL_ID = int(os.environ.get("INTERVIEW_CHANNEL_ID", "1497865058372423834"))
STAFF_ROLE_ID        = int(os.environ.get("STAFF_ROLE_ID",        "1451691985730539592"))
WEBHOOK_SECRET       = os.environ.get("WEBHOOK_SECRET", "")

# Injected by main.py after bot is ready (same pattern as report_webhook)
_bot: discord.ext.commands.Bot | None = None

interview_webhook = Blueprint("interview_webhook", __name__)


def set_bot(bot_instance):
    """Call this from on_ready() after the bot is logged in."""
    global _bot
    _bot = bot_instance
    log.info("Interview webhook: bot reference set.")


# ── Route ─────────────────────────────────────────────────────────────────────

@interview_webhook.route("/webhook/interview-booked", methods=["POST"])
def interview_booked():
    """
    Receives a booking notification from the Flask website and posts
    a staff ping + embed to the interview channel.
    """
    # ── Secret check ──────────────────────────────────────────────────────────
    if WEBHOOK_SECRET:
        incoming = request.headers.get("X-Webhook-Secret", "")
        if incoming != WEBHOOK_SECRET:
            log.warning("Interview webhook: rejected request — bad secret")
            return jsonify({"ok": False, "error": "Forbidden"}), 403

    data = request.get_json(silent=True)
    if not data:
        return jsonify({"ok": False, "error": "Invalid JSON"}), 400

    discord_id   = str(data.get("discord_id", "")).strip()
    username     = data.get("username", "Unknown")
    interview_id = data.get("interview_id", "?")
    date_str     = data.get("date", "?")
    time_str     = data.get("time", "?")
    notes        = data.get("notes", "")
    avatar_url   = data.get("avatar_url", "")

    log.info(
        "Interview booked — #%s by %s (%s) on %s at %s",
        interview_id, username, discord_id or "no discord", date_str, time_str,
    )

    if _bot is None:
        log.error("Interview webhook: bot not ready yet")
        return jsonify({"ok": False, "error": "Bot not ready"}), 503

    # ── Schedule the Discord send on the bot's event loop ─────────────────────
    # The Flask server runs in a daemon thread; the bot runs in the main thread's
    # event loop.  We use run_coroutine_threadsafe so we don't block the HTTP
    # handler and don't need to create a new event loop.
    future = asyncio.run_coroutine_threadsafe(
        _post_to_discord(
            discord_id=discord_id,
            username=username,
            interview_id=interview_id,
            date_str=date_str,
            time_str=time_str,
            notes=notes,
            avatar_url=avatar_url,
        ),
        _bot.loop,
    )

    try:
        # Wait up to 8 seconds for Discord to accept the message
        future.result(timeout=8)
        return jsonify({"ok": True})
    except TimeoutError:
        log.error("Interview webhook: Discord send timed out")
        return jsonify({"ok": False, "error": "Discord timeout"}), 504
    except Exception as e:
        log.error("Interview webhook: Discord send failed: %s", e)
        return jsonify({"ok": False, "error": str(e)}), 500


# ── Discord coroutine ─────────────────────────────────────────────────────────

async def _post_to_discord(
    *,
    discord_id: str,
    username: str,
    interview_id,
    date_str: str,
    time_str: str,
    notes: str,
    avatar_url: str,
):
    """
    Posts the booking embed + staff ping to the interview channel.
    Runs on the bot's event loop.
    """
    channel = _bot.get_channel(INTERVIEW_CHANNEL_ID)
    if channel is None:
        # Try fetching in case the channel isn't cached yet
        try:
            channel = await _bot.fetch_channel(INTERVIEW_CHANNEL_ID)
        except Exception as e:
            log.error("Interview webhook: cannot find channel %s — %s", INTERVIEW_CHANNEL_ID, e)
            raise

    # ── Embed ─────────────────────────────────────────────────────────────────
    embed = discord.Embed(
        title="📅  New Interview Booked",
        color=0x6366F1,
        timestamp=datetime.now(timezone.utc),
    )

    if avatar_url:
        embed.set_thumbnail(url=avatar_url)

    embed.add_field(name="📋  Booking ID",  value=f"```#{interview_id}```", inline=True)
    embed.add_field(name="👤  Applicant",   value=f"```{username}```",      inline=True)

    if discord_id:
        embed.add_field(name="🔗  Discord", value=f"<@{discord_id}>",      inline=True)
    else:
        embed.add_field(name="🔗  Discord", value="*Not linked*",           inline=True)

    embed.add_field(name="📅  Date",        value=f"```{date_str}```",      inline=True)
    embed.add_field(name="⏰  Time (SAST)", value=f"```{time_str} SAST```", inline=True)
    embed.add_field(name="\u200b",          value="\u200b",                 inline=True)

    if notes:
        embed.add_field(
            name="📝  Applicant Notes",
            value=f"> {notes[:500]}",
            inline=False,
        )

    embed.add_field(
        name="🔧  Actions",
        value=(
            "[**View in Admin Panel →**](https://web.goldenshoresrp.com/interviews/admin)\n"
            "-# Confirm, reassign, or cancel from the admin panel."
        ),
        inline=False,
    )
    embed.set_footer(text=f"Cape Flats Roleplay  •  Interview #{interview_id}")

    # ── Staff ping ────────────────────────────────────────────────────────────
    staff_mention = f"<@&{STAFF_ROLE_ID}>"
    try:
        staff_role = channel.guild.get_role(STAFF_ROLE_ID)
        if staff_role:
            staff_mention = staff_role.mention
    except Exception:
        pass

    await channel.send(
        content=f"{staff_mention} — A new interview has been booked!",
        embed=embed,
    )
    log.info("Interview webhook: posted booking #%s to channel %s", interview_id, INTERVIEW_CHANNEL_ID)