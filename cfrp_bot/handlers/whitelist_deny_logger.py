"""
WhitelistDenyLoggerCog — CFRP
=====================================================================
Watches for whitelist application status changes (via webhook from the
web app OR by polling the website API) and, when a user is DENIED,
posts a rich log embed to the configured log channel with:

  • The user's TRUE Discord username pulled from discord.id
  • Their website username and application details
  • A Select-Menu (dropdown) with two options:
      1. "Send Whitelist Message" — DMs the user a standard CFRP
         "how to get whitelisted" guide via the AI bot.
      2. "Send Custom Message" — prompts the staff member for a
         custom message, then DMs it to the user.

Configuration (add to your .env / environment):
  WHITELIST_DENY_LOG_CHANNEL   Name of the text channel to post in.
                               Default: "whitelist-logs"
  WHITELIST_API_URL            Already set — base URL of the web app.
  WHITELIST_API_KEY            Already set — API key.
  DISCORD_GUILD_ID             Already set — your guild snowflake.
  DISCORD_BOT_TOKEN            Already set — bot token.
"""

import asyncio
import logging
import os
import aiohttp

import discord
from discord.ext import commands, tasks
from discord import app_commands

from config import Config
from database.app_db import _get as api_get, _headers

log = logging.getLogger("cfrp_bot.wl_deny_logger")

# ── Config ────────────────────────────────────────────────────────────────────

LOG_CHANNEL_NAME: str = os.getenv("WHITELIST_DENY_LOG_CHANNEL", "whitelist-logs")
API_BASE: str = os.getenv("WHITELIST_API_URL", "https://web.cfrp.co.za").rstrip("/")
POLL_INTERVAL: int = 30          # seconds between application polls
DISCORD_ID_API: str = "https://discord.id/api/fetch-info"   # ?user_id=<snowflake>

# Standard whitelist guide DM message — edit as needed
WHITELIST_GUIDE = (
    "👋 **Hey! Here's how to get whitelisted on CFRP:**\n\n"
    "**Step 1 — Link your Discord**\n"
    "Visit <https://web.cfrp.co.za> and log in with Discord OAuth so "
    "your account is linked.\n\n"
    "**Step 2 — Apply**\n"
    "Head to <https://web.cfrp.co.za/applications/apply/whitelist> and "
    "fill in the application form honestly and in detail. Reviewers want "
    "to see that you understand RP concepts like RDM, VDM, Metagaming, "
    "Powergaming and Fail RP.\n\n"
    "**Step 3 — Wait for review**\n"
    "Applications are reviewed by staff within 24–48 hours. You'll receive "
    "a notification on the website and here on Discord.\n\n"
    "**Tips to improve your application:**\n"
    "• Write full sentences — avoid one-word answers.\n"
    "• Show enthusiasm for serious RP.\n"
    "• Be honest about your experience level.\n\n"
    "If you have questions, open a ticket in our Discord server and a "
    "staff member will help you out. Good luck! 🎮"
)

# ── discord.id helper ─────────────────────────────────────────────────────────

async def fetch_discord_username(discord_id: str) -> str | None:
    """
    Query discord.id to get the true global username for a Discord snowflake.
    Returns the username string (e.g. "coolguy" or "OldUser#1234") or None
    if the lookup fails.
    """
    try:
        async with aiohttp.ClientSession() as session:
            async with session.get(
                DISCORD_ID_API,
                params={"user_id": discord_id},
                timeout=aiohttp.ClientTimeout(total=8),
            ) as resp:
                if resp.status == 200:
                    data = await resp.json()
                    # discord.id returns {"id": ..., "username": ..., "global_name": ...}
                    username = (
                        data.get("global_name")
                        or data.get("username")
                        or data.get("tag")
                    )
                    if username:
                        log.debug("discord.id resolved %s → %s", discord_id, username)
                        return str(username)
                log.warning("discord.id returned %s for %s", resp.status, discord_id)
    except Exception as exc:
        log.warning("discord.id lookup failed for %s: %s", discord_id, exc)
    return None


# ── Website API helpers ───────────────────────────────────────────────────────

async def fetch_denied_applications_since(last_seen_id: int) -> list[dict]:
    """
    Poll the website API for recently denied whitelist applications.
    Returns normalised dicts sorted oldest-first with id > last_seen_id.
    """
    found = []
    try:
        import requests
        for page in range(1, 6):
            url = f"{API_BASE}/api/applications"
            r = requests.get(
                url,
                headers=_headers(),
                params={"type": "whitelist", "status": "denied", "page": page},
                timeout=10,
            )
            if r.status_code != 200:
                break
            data = r.json()
            apps = data.get("applications", [])
            if not apps:
                break
            for app in apps:
                if app.get("id", 0) > last_seen_id:
                    user = app.get("user") or {}
                    raw_discord = str(user.get("discord_id", "") or "")
                    discord_id = (
                        raw_discord[len("discord:"):]
                        if raw_discord.startswith("discord:")
                        else raw_discord
                    )
                    found.append({
                        "app_id":        app.get("id"),
                        "username":      user.get("username") or user.get("discord_username") or "Unknown",
                        "email":         user.get("email", ""),
                        "discord_id":    discord_id,
                        "denial_reason": app.get("review_note") or "No reason provided.",
                        "submitted_at":  str(app.get("submitted_at", ""))[:10],
                        "reviewed_at":   str(app.get("reviewed_at", ""))[:10],
                        "app_url":       f"{API_BASE}/admin/reviews/{app.get('id')}",
                    })
            if page >= data.get("pages", 1):
                break
    except Exception as exc:
        log.error("Error polling denied applications: %s", exc)
    found.sort(key=lambda a: a["app_id"])
    return found


# ── Views ─────────────────────────────────────────────────────────────────────

class CustomMessageModal(discord.ui.Modal, title="Send Custom DM"):
    message_text = discord.ui.TextInput(
        label="Message to send",
        style=discord.TextStyle.paragraph,
        placeholder="Type your custom message here...",
        required=True,
        max_length=1800,
    )

    def __init__(self, target_member: discord.Member | None, target_discord_id: str, username: str):
        super().__init__()
        self.target_member = target_member
        self.target_discord_id = target_discord_id
        self.username = username

    async def on_submit(self, interaction: discord.Interaction):
        msg = str(self.message_text.value).strip()
        if not msg:
            await interaction.response.send_message("❌ Message cannot be empty.", ephemeral=True)
            return

        sent = await _dm_user(self.target_member, self.target_discord_id, interaction.guild, msg)
        if sent:
            await interaction.response.send_message(
                f"✅ Custom message sent to **{self.username}**.", ephemeral=True
            )
            # Update the log embed to show action taken
            await _annotate_original(interaction, f"📨 Custom DM sent by {interaction.user.mention}")
        else:
            await interaction.response.send_message(
                f"❌ Could not DM **{self.username}** — they may have DMs disabled or aren't in the server.",
                ephemeral=True,
            )


class DenyActionSelect(discord.ui.Select):
    def __init__(self, target_discord_id: str, username: str):
        self.target_discord_id = target_discord_id
        self.username = username
        options = [
            discord.SelectOption(
                label="Send Whitelist Guide",
                value="guide",
                description="DM the user our standard how-to-get-whitelisted guide",
                emoji="📋",
            ),
            discord.SelectOption(
                label="Send Custom Message",
                value="custom",
                description="Type a custom message to DM the denied user",
                emoji="✏️",
            ),
        ]
        super().__init__(
            placeholder="📬 Staff action — DM this user...",
            min_values=1,
            max_values=1,
            options=options,
            custom_id=f"deny_action:{target_discord_id}",
        )

    async def callback(self, interaction: discord.Interaction):
        # Verify staff role
        staff_role = interaction.guild.get_role(Config.STAFF_ROLE_ID)
        if staff_role and staff_role not in interaction.user.roles:
            await interaction.response.send_message(
                "❌ You need the Staff role to use this.", ephemeral=True
            )
            return

        # Resolve member from guild if possible
        target_member = interaction.guild.get_member(int(self.target_discord_id)) if self.target_discord_id.isdigit() else None

        choice = self.values[0]

        if choice == "guide":
            sent = await _dm_user(target_member, self.target_discord_id, interaction.guild, WHITELIST_GUIDE)
            if sent:
                await interaction.response.send_message(
                    f"✅ Whitelist guide sent to **{self.username}**.", ephemeral=True
                )
                await _annotate_original(interaction, f"📋 Whitelist guide sent by {interaction.user.mention}")
            else:
                await interaction.response.send_message(
                    f"❌ Could not DM **{self.username}** — DMs may be closed or user not in server.",
                    ephemeral=True,
                )

        elif choice == "custom":
            modal = CustomMessageModal(target_member, self.target_discord_id, self.username)
            await interaction.response.send_modal(modal)


class DenyActionView(discord.ui.View):
    def __init__(self, target_discord_id: str, username: str):
        super().__init__(timeout=None)   # Persist across restarts
        self.add_item(DenyActionSelect(target_discord_id, username))


# ── DM helper ─────────────────────────────────────────────────────────────────

async def _dm_user(
    member: discord.Member | None,
    discord_id: str,
    guild: discord.Guild,
    message: str,
) -> bool:
    """
    Try to DM the user.  If we don't have a Member object yet we attempt
    to fetch them from the guild first.
    """
    if member is None and discord_id.isdigit():
        try:
            member = await guild.fetch_member(int(discord_id))
        except Exception:
            pass

    if member is None:
        return False

    try:
        await member.send(message)
        return True
    except (discord.Forbidden, discord.HTTPException):
        return False


async def _annotate_original(interaction: discord.Interaction, note: str):
    """Append an action note to the original log embed footer."""
    try:
        msg = interaction.message
        if msg and msg.embeds:
            emb = msg.embeds[0].copy()
            existing = emb.footer.text or ""
            emb.set_footer(text=(existing + "  •  " + note).lstrip("  •  "))
            await msg.edit(embed=emb)
    except Exception:
        pass


# ── The Cog ───────────────────────────────────────────────────────────────────

class WhitelistDenyLoggerCog(commands.Cog):
    """
    Polls the CFRP website for newly denied whitelist applications,
    enriches the data via discord.id, then posts a log with a staff DM dropdown.
    """

    def __init__(self, bot: commands.Bot):
        self.bot = bot
        self._last_seen_id: int = 0   # Track highest app ID we've already logged
        self._poll_task.start()

    def cog_unload(self):
        self._poll_task.cancel()

    # ── Bootstrap: seed last_seen_id so we don't spam on first start ──────────

    async def _seed_last_seen(self):
        """On first run, find the highest existing denied app ID so we only log NEW denials."""
        try:
            import requests
            r = requests.get(
                f"{API_BASE}/api/applications",
                headers=_headers(),
                params={"type": "whitelist", "status": "denied", "page": 1},
                timeout=10,
            )
            if r.status_code == 200:
                apps = r.json().get("applications", [])
                if apps:
                    self._last_seen_id = max(a.get("id", 0) for a in apps)
                    log.info("WhitelistDenyLogger seeded last_seen_id=%d", self._last_seen_id)
        except Exception as exc:
            log.warning("Could not seed last_seen_id: %s", exc)

    # ── Polling loop ──────────────────────────────────────────────────────────

    @tasks.loop(seconds=POLL_INTERVAL)
    async def _poll_task(self):
        await self.bot.wait_until_ready()
        guild_id = int(os.getenv("DISCORD_GUILD_ID", "0"))
        if not guild_id:
            return
        guild = self.bot.get_guild(guild_id)
        if not guild:
            return

        denied = await fetch_denied_applications_since(self._last_seen_id)
        for app in denied:
            await self._post_deny_log(guild, app)
            if app["app_id"] > self._last_seen_id:
                self._last_seen_id = app["app_id"]

    @_poll_task.before_loop
    async def _before_poll(self):
        await self.bot.wait_until_ready()
        await self._seed_last_seen()

    # ── Post log embed ────────────────────────────────────────────────────────

    async def _post_deny_log(self, guild: discord.Guild, app: dict):
        log_ch = discord.utils.get(guild.text_channels, name=LOG_CHANNEL_NAME)
        if not log_ch:
            log.warning("Deny log channel '%s' not found.", LOG_CHANNEL_NAME)
            return

        discord_id = app.get("discord_id", "")
        site_username = app.get("username", "Unknown")

        # ── Resolve true Discord username via discord.id ──────────────────
        true_username = None
        if discord_id:
            true_username = await fetch_discord_username(discord_id)

        display_name = true_username or site_username

        # ── Also try to get member object for avatar ──────────────────────
        member = guild.get_member(int(discord_id)) if discord_id.isdigit() else None

        # ── Build embed ───────────────────────────────────────────────────
        embed = discord.Embed(
            title="❌  Whitelist Application Denied",
            colour=discord.Colour.red(),
        )

        if member:
            embed.set_thumbnail(url=member.display_avatar.url)

        embed.add_field(
            name="👤  Discord Username",
            value=f"**{display_name}**"
            + (f"\n*(site: {site_username})*" if true_username and true_username != site_username else ""),
            inline=True,
        )
        embed.add_field(
            name="🆔  Discord ID",
            value=f"`{discord_id}`" if discord_id else "Not linked",
            inline=True,
        )
        embed.add_field(
            name="🔗  Mention",
            value=f"<@{discord_id}>" if discord_id else "—",
            inline=True,
        )
        embed.add_field(
            name="📋  Application",
            value=f"[App #{app['app_id']}]({app['app_url']})",
            inline=True,
        )
        embed.add_field(
            name="📅  Submitted",
            value=app.get("submitted_at", "—"),
            inline=True,
        )
        embed.add_field(
            name="📅  Reviewed",
            value=app.get("reviewed_at", "—"),
            inline=True,
        )
        embed.add_field(
            name="❌  Denial Reason",
            value=app.get("denial_reason", "No reason provided."),
            inline=False,
        )
        embed.set_footer(text="Use the dropdown below to contact this user")

        view = DenyActionView(discord_id, display_name)

        await log_ch.send(embed=embed, view=view)
        log.info(
            "Posted deny log for app #%d — user %s (%s)",
            app["app_id"],
            display_name,
            discord_id,
        )

    # ── Slash command: manually re-trigger a log for any app ID ──────────────

    @app_commands.command(
        name="wl-deny-log",
        description="[Staff] Manually post a whitelist deny log for a given application ID.",
    )
    @app_commands.describe(app_id="The whitelist application ID to log")
    async def wl_deny_log(self, interaction: discord.Interaction, app_id: int):
        staff_role = interaction.guild.get_role(Config.STAFF_ROLE_ID)
        if staff_role and staff_role not in interaction.user.roles:
            await interaction.response.send_message("❌ Staff only.", ephemeral=True)
            return

        await interaction.response.defer(ephemeral=True)

        try:
            import requests
            r = requests.get(
                f"{API_BASE}/api/applications/{app_id}",
                headers=_headers(),
                timeout=10,
            )
            if r.status_code != 200:
                await interaction.followup.send(f"❌ App #{app_id} not found (HTTP {r.status_code}).", ephemeral=True)
                return
            raw = r.json()
            app_data = raw.get("application") or raw
            user = app_data.get("user") or {}
            raw_discord = str(user.get("discord_id", "") or "")
            discord_id = raw_discord[len("discord:"):] if raw_discord.startswith("discord:") else raw_discord

            app = {
                "app_id":        app_data.get("id", app_id),
                "username":      user.get("username") or user.get("discord_username") or "Unknown",
                "email":         user.get("email", ""),
                "discord_id":    discord_id,
                "denial_reason": app_data.get("review_note") or "No reason provided.",
                "submitted_at":  str(app_data.get("submitted_at", ""))[:10],
                "reviewed_at":   str(app_data.get("reviewed_at", ""))[:10],
                "app_url":       f"{API_BASE}/admin/reviews/{app_id}",
            }
            await self._post_deny_log(interaction.guild, app)
            await interaction.followup.send(f"✅ Deny log posted for app #{app_id}.", ephemeral=True)
        except Exception as exc:
            await interaction.followup.send(f"❌ Error: {exc}", ephemeral=True)


async def setup(bot: commands.Bot):
    cog = WhitelistDenyLoggerCog(bot)
    await bot.add_cog(cog)
    # Register persistent views so dropdowns survive bot restarts
    # (discord.py re-attaches them on reconnect via on_ready)
    log.info("WhitelistDenyLoggerCog loaded.")
