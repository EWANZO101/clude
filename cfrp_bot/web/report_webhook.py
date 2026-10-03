"""
Report Webhook — receives POST events from the CFRP website and DMs users via the bot.

Two endpoints:
  POST /webhook/report-submitted   — fires when a user submits a report
  POST /webhook/private-comm       — fires when an admin sends a Private Communication reply

Expected JSON payloads:

  report-submitted:
    {
      "discord_id": "123456789012345678",
      "report_id":  42,
      "report_type": "player" | "bug",
      "summary":    "Short one-line description"          (optional)
    }

  private-comm:
    {
      "discord_id":  "123456789012345678",
      "report_id":   42,
      "admin_name":  "StaffMember",
      "message":     "The reply text from the admin"
    }

Authentication: every request must include the header
  X-Webhook-Secret: <WEBHOOK_SECRET from .env>
"""

import logging
import os
from flask import Blueprint, request, jsonify
import asyncio

log = logging.getLogger("cfrp_bot.report_webhook")

# Will be set by bot.py after the bot is ready
_bot = None

WEBHOOK_SECRET: str = os.getenv("WEBHOOK_SECRET", "")

report_webhook = Blueprint("report_webhook", __name__)


def set_bot(bot):
    """Called from bot.py once the Discord client is ready."""
    global _bot
    _bot = bot


def _check_secret() -> bool:
    """Return True if the request carries a valid webhook secret (or secret is unset)."""
    if not WEBHOOK_SECRET:
        return True  # secret not configured → allow (warn in logs)
    return request.headers.get("X-Webhook-Secret", "") == WEBHOOK_SECRET


def _schedule_dm(coro):
    """Push a coroutine onto the bot's running event loop from Flask's sync thread."""
    if _bot is None:
        log.error("Bot not initialised yet — cannot send DM.")
        return
    loop = _bot.loop
    asyncio.run_coroutine_threadsafe(coro, loop)


async def _dm_user(discord_id: str, embed: "discord.Embed"):
    """Fetch the Discord user and send them a DM embed."""
    import discord as _discord
    try:
        user = await _bot.fetch_user(int(discord_id))
        await user.send(embed=embed)
        log.info("DM sent to Discord user %s", discord_id)
    except _discord.NotFound:
        log.warning("Discord user %s not found — DM not sent.", discord_id)
    except _discord.Forbidden:
        log.warning("Cannot DM Discord user %s (DMs disabled).", discord_id)
    except Exception as exc:
        log.error("Unexpected error DMing user %s: %s", discord_id, exc)


# ── Endpoint 1: Report submitted ──────────────────────────────────────────────

@report_webhook.route("/webhook/report-submitted", methods=["POST"])
def report_submitted():
    if not _check_secret():
        return jsonify({"error": "Unauthorized"}), 401

    data = request.get_json(silent=True) or {}
    discord_id  = str(data.get("discord_id", "")).strip()
    report_id   = data.get("report_id", "N/A")
    report_type = str(data.get("report_type", "report")).strip()
    summary     = str(data.get("summary", "")).strip()

    if not discord_id:
        return jsonify({"error": "discord_id is required"}), 400

    type_label = "Bug Report" if report_type == "bug" else "Player Report"
    admin_url  = "https://web.goldenshoresrp.com/reports/admin"

    async def _send():
        import discord as _discord
        embed = _discord.Embed(
            title="✅ Report Received",
            description=(
                f"Thanks for submitting your **{type_label}**!\n\n"
                "Our staff team has been notified and will review it shortly. "
                "You may receive a **Private Communication** from an admin if they need more information "
                "or to let you know the outcome."
            ),
            colour=0x2ecc71,
        )
        embed.add_field(name="Report ID", value=f"#{report_id}", inline=True)
        embed.add_field(name="Type",      value=type_label,       inline=True)
        if summary:
            embed.add_field(name="Summary", value=summary, inline=False)
        embed.set_footer(text="Cape Flats Roleplay • Reports Portal")
        await _dm_user(discord_id, embed)

    _schedule_dm(_send())
    return jsonify({"status": "queued"}), 200


# ── Endpoint 2: Admin private communication ───────────────────────────────────

@report_webhook.route("/webhook/private-comm", methods=["POST"])
def private_comm():
    if not _check_secret():
        return jsonify({"error": "Unauthorized"}), 401

    data = request.get_json(silent=True) or {}
    discord_id = str(data.get("discord_id", "")).strip()
    report_id  = data.get("report_id", "N/A")
    admin_name = str(data.get("admin_name", "Staff")).strip()
    message    = str(data.get("message", "")).strip()

    if not discord_id:
        return jsonify({"error": "discord_id is required"}), 400
    if not message:
        return jsonify({"error": "message is required"}), 400

    report_url = f"https://web.goldenshoresrp.com/reports/{report_id}" if report_id != "N/A" else "https://web.goldenshoresrp.com/reports"

    async def _send():
        import discord as _discord
        embed = _discord.Embed(
            title="📨 Private Communication from Staff",
            description=message,
            colour=0x5865f2,
        )
        embed.add_field(name="Report ID",   value=f"#{report_id}", inline=True)
        embed.add_field(name="Sent by",     value=admin_name,       inline=True)
        embed.add_field(
            name="View Report",
            value=f"[Click here to view your report]({report_url})",
            inline=False,
        )
        embed.set_footer(text="Cape Flats Roleplay • Staff Communication")
        await _dm_user(discord_id, embed)

    _schedule_dm(_send())
    return jsonify({"status": "queued"}), 200
