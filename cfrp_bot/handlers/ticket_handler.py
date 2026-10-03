"""
TicketHandler — CFRP full ticket system.
!setup-tickets deletes ALL categories (except exempt) then rebuilds from scratch.

Changes vs original:
- Live application polling every 5s inside whitelist tickets
- Deduplication: never posts the same application embed twice
- Discord ID fix: strips 'discord:' prefix before comparing
- Checks if user is linked on the website before searching applications
- Shows "not linked" message with signup URL if user hasn't connected Discord
- Fix: interview booking link now reliably appears in whitelist tickets
  by passing app_key directly into _build_app_embed() instead of reading
  it back from the returned app dict (which may not contain that field).
"""

import discord
import logging
import io
import re
import os
import json
import asyncio
from datetime import datetime, timezone
from discord.ext import commands, tasks
from config import Config
from database.db_manager import db
from database.app_db import (
    get_application, format_application_embed,
    is_application_type, get_user_limits,
)

log = logging.getLogger("cfrp_bot.ticket_handler")

INFRA_CATEGORY_ID = 1501617058679357440

_extra_exempt = [
    int(x.strip())
    for x in os.environ.get("EXEMPT_CATEGORY_IDS", "").split(",")
    if x.strip().isdigit()
]
EXEMPT_CATEGORY_IDS: set = {1489197426765070356, 1489200037991944242} | set(_extra_exempt)
EXEMPT_CATEGORY_ID = 1501617058679357440
TICKET_LOG_NAME        = "ticket-logs"
TICKET_TRANSCRIPT_NAME = "ticket-transcripts"
TRANSCRIPT_DIR         = os.path.join(os.path.dirname(__file__), "..", "transcripts")
TRANSCRIPT_BASE_URL    = os.environ.get("TRANSCRIPT_BASE_URL", "http://localhost:5000")
WEBSITE_URL            = os.environ.get("WHITELIST_API_URL", "https://web.goldenshoresrp.com")

APP_SLUG_MAP = {
    "whitelist":    "whitelist",
    "dispatch":     "dispatch",
    "east-customs": "east-customs",
    "ems":          "ems",
    "fire":         "fire",
    "ls-customs":   "ls-customs",
    "police":       "police",
    "tuner-shop":   "tuner-shop",
}

# Keys that should show the interview booking prompt when status is pending.
# Must match the app_key values used in APP_SLUG_MAP (left-hand side).
INTERVIEW_APP_KEYS: set = {"whitelist", "whitelist-tickets"}

# ── Live poll state ───────────────────────────────────────────────────────────
# Maps channel_id -> { "member": Member, "app_key": str, "last_app_id": int|None, "msg_id": int|None }
_live_polls: dict = {}


def _slug(text):
    return re.sub(r"[^a-z0-9\-]", "-", text.lower().strip()).strip("-")

def _get_ch(guild, name):
    return discord.utils.get(guild.text_channels, name=name.lower())

def _infra_cat(guild):
    return discord.utils.get(guild.categories, id=INFRA_CATEGORY_ID)

def _transcript_url(ticket_id):
    return TRANSCRIPT_BASE_URL.rstrip("/") + "/t/" + ticket_id

def _json_default(obj):
    if hasattr(obj, "isoformat"):
        return obj.isoformat()
    return str(obj)

def _save_transcript(data):
    os.makedirs(TRANSCRIPT_DIR, exist_ok=True)
    path = os.path.join(TRANSCRIPT_DIR, data["ticket_id"] + ".json")
    with open(path, "w") as f:
        json.dump(data, f, indent=2, default=_json_default)


async def _get_or_make_type_cat(guild, tt):
    if tt.get("category_id"):
        cat = guild.get_channel(int(tt["category_id"]))
        if cat and isinstance(cat, discord.CategoryChannel):
            return cat
    cat_name   = tt["emoji"] + " " + tt["name"] + " Tickets"
    cat        = discord.utils.get(guild.categories, name=cat_name)
    staff_role = guild.get_role(Config.STAFF_ROLE_ID)
    if not cat:
        ow = {
            guild.default_role: discord.PermissionOverwrite(read_messages=False),
            guild.me:           discord.PermissionOverwrite(read_messages=True, send_messages=True,
                                                            manage_channels=True),
        }
        if staff_role:
            ow[staff_role] = discord.PermissionOverwrite(read_messages=True, send_messages=True)
        cat = await guild.create_category(cat_name, overwrites=ow)
    db.set_type_category(tt["app_key"], cat.id)
    return cat


async def _build_transcript(channel, rec, closed_by):
    messages = []
    async for msg in channel.history(limit=500, oldest_first=True):
        is_bot   = msg.author.bot
        is_staff = (isinstance(msg.author, discord.Member) and
                    any(r.id == Config.STAFF_ROLE_ID for r in msg.author.roles))
        messages.append({
            "ts":          msg.created_at.isoformat(),
            "author":      msg.author.display_name,
            "author_id":   str(msg.author.id),
            "role":        "bot" if is_bot else ("staff" if is_staff else ""),
            "content":     msg.content,
            "attachments": [a.url for a in msg.attachments],
            "system":      False,
        })
    now = datetime.now(timezone.utc)
    return {
        "ticket_id":   rec.get("ticket_number", "TICK-????") if rec else "TICK-????",
        "ticket_type": rec.get("app_key", "unknown") if rec else "unknown",
        "opened_by":   rec.get("opened_by_name", "?") if rec else "?",
        "opened_at":   str(rec.get("opened_at", "")) if rec else "",
        "closed_by":   closed_by.display_name,
        "closed_at":   now.strftime("%Y-%m-%d %H:%M UTC"),
        "messages":    messages,
    }


def _build_app_embed(app: dict, app_key: str = "") -> discord.Embed:
    """
    Build the application embed from a normalised app dict.

    app_key should always be passed — it is the ticket's app_key (the reliable
    source of truth) rather than whatever field the app dict may or may not
    contain.  The fallback to app dict fields is kept as a safety net only.
    """
    header, fields = format_application_embed(app)
    status_colour = {
        "pending":  discord.Colour.yellow(),
        "approved": discord.Colour.green(),
        "denied":   discord.Colour.red(),
    }
    status_icon = {"pending": "🟡", "approved": "🟢", "denied": "🔴"}
    colour = status_colour.get(str(app["status"]), discord.Colour.blurple())
    icon   = status_icon.get(str(app["status"]), "⚪")

    embed = discord.Embed(
        title=f"{icon} {app['type_name']} Application #{app['id']}",
        description=header,
        colour=colour,
    )
    embed.set_footer(text="Status: " + str(app["status"]).upper() + " — updates every 5s")
    for label, value in fields:
        inline = len(value) < 100
        embed.add_field(name=label, value=value, inline=inline)
        if len(embed.fields) >= 24:
            embed.add_field(name="Note", value="Additional fields truncated.", inline=False)
            break

    # Determine whether this is a whitelist-type ticket.
    # Priority: use the app_key argument (passed from the ticket context — always
    # correct).  Fall back to the app dict fields in case this helper is ever
    # called without an explicit app_key.
    resolved_key = app_key.lower() if app_key else ""
    if not resolved_key:
        resolved_key = str(
            app.get("app_key", app.get("type_name", ""))
        ).lower()

    is_whitelist = resolved_key in INTERVIEW_APP_KEYS

    log.debug(
        "_build_app_embed: resolved_key=%r, status=%r, is_whitelist=%r",
        resolved_key, app["status"], is_whitelist,
    )

    if is_whitelist and str(app["status"]) == "pending":
        embed.add_field(
            name="📅  Book Your Interview",
            value=(
                "Please book an interview with our team to complete your whitelist application.\n"
                "[**Click here to schedule your interview →**](https://web.goldenshoresrp.com/interviews/book)"
            ),
            inline=False,
        )

    return embed


async def _post_application(channel, member, app_key):
    """
    Post the application embed when a ticket is first opened.
    Also registers the channel for live polling if it's an application type.
    Skips the linked check entirely — goes straight to get_application.
    """
    if not is_application_type(app_key):
        return

    discord_id = str(member.id)
    slug = APP_SLUG_MAP.get(app_key)

    # ── Look up application directly ──────────────────────────────────────────
    app = await asyncio.get_event_loop().run_in_executor(
        None, get_application, discord_id, slug
    ) if slug else None

    if app:
        embed = _build_app_embed(app, app_key=app_key)
        msg = await channel.send(embed=embed)
        _live_polls[channel.id] = {
            "member":      member,
            "app_key":     app_key,
            "last_app_id": app["id"],
            "last_status": str(app["status"]),
            "msg_id":      msg.id,
        }
        return

    # ── No application found yet ──────────────────────────────────────────────
    type_label = app_key.replace("-", " ").title()
    embed = discord.Embed(
        title=f"No {type_label} Application Found",
        description=(
            f"{member.mention} hasn't submitted a **{type_label}** application yet.\n\n"
            f"👉 [Click here to apply]({WEBSITE_URL}/applications)"
        ),
        colour=discord.Colour.orange(),
    )
    embed.set_footer(text="Checking for new application every 5 seconds...")
    msg = await channel.send(embed=embed)
    _live_polls[channel.id] = {
        "member":      member,
        "app_key":     app_key,
        "last_app_id": None,
        "last_status": None,
        "msg_id":      msg.id,
    }


async def _poll_tick(bot):
    """
    Called every 5 seconds. For each tracked ticket channel, checks if
    the application has appeared or changed and updates the embed in-place.
    Never posts a duplicate — always edits the existing message.
    """
    if not _live_polls:
        return

    dead = []
    for channel_id, state in list(_live_polls.items()):
        try:
            guild   = None
            channel = None
            for g in bot.guilds:
                ch = g.get_channel(channel_id)
                if ch:
                    guild   = g
                    channel = ch
                    break

            if channel is None:
                dead.append(channel_id)
                continue

            member  = state["member"]
            app_key = state["app_key"]
            slug    = APP_SLUG_MAP.get(app_key)
            discord_id = str(member.id)

            # Fetch the message we previously posted
            try:
                msg = await channel.fetch_message(state["msg_id"])
            except (discord.NotFound, discord.HTTPException):
                dead.append(channel_id)
                continue

            # ── Look up application ───────────────────────────────────────────
            app = await asyncio.get_event_loop().run_in_executor(
                None, get_application, discord_id, slug
            ) if slug else None

            if app:
                app_id      = app["id"]
                last_id     = state.get("last_app_id")
                last_status = state.get("last_status")
                cur_status  = str(app["status"])

                # Force refresh when: ID changed, status changed, OR last_app_id
                # is None (bot just restarted — guarantees new labels are applied immediately)
                if app_id != last_id or cur_status != last_status or last_id is None:
                    embed = _build_app_embed(app, app_key=app_key)
                    await msg.edit(embed=embed)

                    # ── Auto-assign role on approval ──────────────────────────
                    # Only trigger when we see a *transition* into approved
                    # (last_status != "approved") so we don't spam add_roles
                    # on every poll tick after the fact.
                    if cur_status == "approved" and last_status != "approved":
                        await _assign_auto_role(guild, member, app_key, channel=channel)

                    state["last_app_id"] = app_id
                    state["last_status"] = cur_status
                    log.debug("Refreshed embed for channel %s (app %s, status %s)", channel_id, app_id, cur_status)
            else:
                # No app found — show not-found embed once (or after a restart)
                if state.get("last_app_id") is not None or state.get("last_status") is None:
                    type_label = app_key.replace("-", " ").title()
                    embed = discord.Embed(
                        title=f"No {type_label} Application Found",
                        description=(
                            f"{member.mention} hasn't submitted a **{type_label}** application yet.\n\n"
                            f"👉 [Click here to apply]({WEBSITE_URL}/applications)"
                        ),
                        colour=discord.Colour.orange(),
                    )
                    embed.set_footer(text="Checking for new application every 5 seconds...")
                    await msg.edit(embed=embed)
                    state["last_app_id"] = None
                    state["last_status"] = "none"

        except Exception as e:
            log.warning("Poll tick error for channel %s: %s", channel_id, e)

    for cid in dead:
        _live_polls.pop(cid, None)


def stop_poll(channel_id: int):
    """Call this when a ticket is closed to stop polling it."""
    _live_polls.pop(channel_id, None)


# ── UI Views ──────────────────────────────────────────────────────────────────

class OpenTicketView(discord.ui.View):
    def __init__(self, key, label, emoji):
        super().__init__(timeout=None)
        self.add_item(OpenTicketButton(key, label, emoji))


class OpenTicketButton(discord.ui.Button):
    def __init__(self, key, label, emoji):
        super().__init__(label=label, emoji=emoji,
                         style=discord.ButtonStyle.primary,
                         custom_id="ticket_open_" + key)
        self.key = key

    async def callback(self, interaction):
        db.ensure_tables()
        tt = db.get_type(self.key)
        if not tt:
            await interaction.response.send_message("This ticket type no longer exists.", ephemeral=True)
            return
        existing = db.get_open_ticket(interaction.user.id, self.key)
        if existing:
            ch = interaction.guild.get_channel(int(existing["channel_id"]))
            if ch:
                await interaction.response.send_message(
                    "You already have an open ticket: " + ch.mention, ephemeral=True)
                return
            db.close_ticket(int(existing["channel_id"]), interaction.user.id)
        await interaction.response.send_message(
            embed=discord.Embed(description="Opening your ticket...",
                                colour=discord.Colour.blurple()), ephemeral=True)
        try:
            await _open_ticket(interaction, tt)
        except Exception as e:
            log.exception("Error opening ticket: " + str(e))
            await interaction.edit_original_response(
                embed=discord.Embed(description="Failed to open ticket: " + str(e),
                                    colour=discord.Colour.red()))


class AddUserView(discord.ui.View):
    """Ephemeral view with a MemberSelect to add someone to a ticket channel."""
    def __init__(self, channel):
        super().__init__(timeout=60)
        self.channel = channel

    @discord.ui.select(
        cls=discord.ui.UserSelect,
        placeholder="Select a member to add…",
        min_values=1, max_values=1,
    )
    async def user_select(self, interaction, select: discord.ui.UserSelect):
        user = select.values[0]
        member = interaction.guild.get_member(user.id)
        if member is None:
            try:
                member = await interaction.guild.fetch_member(user.id)
            except Exception:
                member = None
        if member is None:
            await interaction.response.edit_message(
                embed=discord.Embed(
                    description="⚠️ Could not find that member in this server.",
                    colour=discord.Colour.red(),
                ),
                view=None,
            )
            return
        channel = self.channel

        overwrite = channel.overwrites_for(member)
        if overwrite.read_messages is True:
            await interaction.response.edit_message(
                embed=discord.Embed(
                    description=f"⚠️ {member.mention} already has access to this ticket.",
                    colour=discord.Colour.orange(),
                ),
                view=None,
            )
            return

        await channel.set_permissions(
            member,
            read_messages=True,
            send_messages=True,
            attach_files=True,
            reason=f"Added to ticket by {interaction.user}",
        )
        await interaction.response.edit_message(
            embed=discord.Embed(
                description=f"✅ {member.mention} has been added to this ticket.",
                colour=discord.Colour.green(),
            ),
            view=None,
        )
        await channel.send(
            embed=discord.Embed(
                description=f"➕ {member.mention} was added to this ticket by {interaction.user.mention}.",
                colour=discord.Colour.blurple(),
            )
        )


class AssignTicketView(discord.ui.View):
    """Ephemeral view with a MemberSelect to assign a ticket to a staff member."""
    def __init__(self, channel):
        super().__init__(timeout=60)
        self.channel = channel

    @discord.ui.select(
        cls=discord.ui.UserSelect,
        placeholder="Select a staff member to assign…",
        min_values=1, max_values=1,
    )
    async def staff_select(self, interaction, select: discord.ui.UserSelect):
        user = select.values[0]
        assignee = interaction.guild.get_member(user.id)
        if assignee is None:
            try:
                assignee = await interaction.guild.fetch_member(user.id)
            except Exception:
                assignee = None
        if assignee is None:
            await interaction.response.edit_message(
                embed=discord.Embed(
                    description="⚠️ Could not find that member in this server.",
                    colour=discord.Colour.red(),
                ),
                view=None,
            )
            return

        if not any(r.id == Config.STAFF_ROLE_ID for r in assignee.roles):
            await interaction.response.edit_message(
                embed=discord.Embed(
                    description=f"⚠️ {assignee.mention} is not a staff member.",
                    colour=discord.Colour.red(),
                ),
                view=None,
            )
            return

        db.claim_ticket(self.channel.id, assignee.id)

        overwrite = self.channel.overwrites_for(assignee)
        if overwrite.read_messages is not True:
            await self.channel.set_permissions(
                assignee,
                read_messages=True,
                send_messages=True,
                attach_files=True,
                reason=f"Assigned ticket by {interaction.user}",
            )

        await interaction.response.edit_message(
            embed=discord.Embed(
                description=f"✅ Ticket assigned to {assignee.mention}.",
                colour=discord.Colour.green(),
            ),
            view=None,
        )
        await self.channel.send(
            content=assignee.mention,
            embed=discord.Embed(
                title="📋 Ticket Assigned",
                description=(
                    f"This ticket has been assigned to {assignee.mention} "
                    f"by {interaction.user.mention}."
                ),
                colour=discord.Colour.blurple(),
            ),
        )


class TicketControlView(discord.ui.View):
    def __init__(self):
        super().__init__(timeout=None)

    @discord.ui.button(label="Close Ticket", emoji="🔒",
                       style=discord.ButtonStyle.danger, custom_id="ticket_close")
    async def close_ticket(self, interaction, _btn):
        rec      = db.get_ticket_by_channel(interaction.channel_id)
        is_staff = any(r.id == Config.STAFF_ROLE_ID for r in interaction.user.roles)
        is_owner = rec and str(rec["user_id"]) == str(interaction.user.id)
        if not is_staff and not is_owner:
            await interaction.response.send_message(
                embed=discord.Embed(description="Only staff or the ticket owner can close this.",
                                    colour=discord.Colour.red()), ephemeral=True)
            return
        await interaction.response.send_message(
            embed=discord.Embed(description="Closing ticket...",
                                colour=discord.Colour.orange()), ephemeral=True)
        try:
            await _close_ticket(interaction.guild, interaction.channel, interaction.user)
        except Exception as e:
            log.exception("Error closing ticket: " + str(e))

    @discord.ui.button(label="Claim Ticket", emoji="🙋",
                       style=discord.ButtonStyle.success, custom_id="ticket_claim")
    async def claim_ticket(self, interaction, _btn):
        if not any(r.id == Config.STAFF_ROLE_ID for r in interaction.user.roles):
            await interaction.response.send_message(
                embed=discord.Embed(description="Only staff can claim tickets.",
                                    colour=discord.Colour.red()), ephemeral=True)
            return
        db.claim_ticket(interaction.channel_id, interaction.user.id)
        await interaction.response.send_message(
            embed=discord.Embed(
                description="🙋 **" + interaction.user.display_name + "** has claimed this ticket.",
                colour=discord.Colour.green()))

    @discord.ui.button(label="Add User", emoji="➕",
                       style=discord.ButtonStyle.secondary, custom_id="ticket_add_user")
    async def add_user(self, interaction, _btn):
        is_staff = any(r.id == Config.STAFF_ROLE_ID for r in interaction.user.roles)
        rec      = db.get_ticket_by_channel(interaction.channel_id)
        is_owner = rec and str(rec["user_id"]) == str(interaction.user.id)
        if not is_staff and not is_owner:
            await interaction.response.send_message(
                embed=discord.Embed(description="Only staff or the ticket owner can add users.",
                                    colour=discord.Colour.red()), ephemeral=True)
            return
        await interaction.response.send_message(
            embed=discord.Embed(
                title="➕ Add User to Ticket",
                description="Select a member to give access to this ticket.",
                colour=discord.Colour.blurple(),
            ),
            view=AddUserView(interaction.channel),
            ephemeral=True,
        )

    @discord.ui.button(label="Assign Ticket", emoji="📋",
                       style=discord.ButtonStyle.primary, custom_id="ticket_assign")
    async def assign_ticket(self, interaction, _btn):
        if not any(r.id == Config.STAFF_ROLE_ID for r in interaction.user.roles):
            await interaction.response.send_message(
                embed=discord.Embed(description="Only staff can assign tickets.",
                                    colour=discord.Colour.red()), ephemeral=True)
            return
        await interaction.response.send_message(
            embed=discord.Embed(
                title="📋 Assign Ticket",
                description="Select a staff member to assign this ticket to.",
                colour=discord.Colour.blurple(),
            ),
            view=AssignTicketView(interaction.channel),
            ephemeral=True,
        )



async def _post_user_limits(channel, member):
    """
    Fetch active UserLimit records for this Discord user from the web app API.
    If any active limits exist, post a prominent red warning embed into the ticket
    so both the user and staff are immediately aware.
    Returns True if limits were found and posted, False otherwise.
    """
    limits = await asyncio.get_event_loop().run_in_executor(
        None, get_user_limits, str(member.id)
    )
    if not limits:
        return False

    embed = discord.Embed(
        title="🚨  ACTIVE RESTRICTIONS ON THIS USER",
        description=(
            f"{member.mention} has **{len(limits)} active restriction(s)** on their account.\n"
            f"Staff — please review before proceeding.\n\n"
            f"[📋 View full restriction details on the admin panel]"
            f"({WEBSITE_URL}/admin/limits?q={member.name}&active=1)"
        ),
        colour=discord.Colour.red(),
    )
    embed.set_author(
        name=member.display_name,
        icon_url=member.display_avatar.url,
    )

    for lim in limits:
        flags = []
        if lim.get("no_firearm"):
            flags.append("🔫 Cannot own a firearm (legal or illegal)")
        if lim.get("no_create_priority"):
            flags.append("🚫 Cannot create priority situations")
        if lim.get("no_join_priority"):
            flags.append("🚫 Cannot participate in priority situations")

        expires = lim.get("expires_at")
        if expires:
            try:
                exp_dt   = datetime.fromisoformat(expires.replace("Z", "+00:00"))
                now_utc  = datetime.now(timezone.utc)
                days_rem = max((exp_dt.date() - now_utc.date()).days, 0)
                exp_str  = f"Expires **{exp_dt.strftime('%d %b %Y')}** ({days_rem} days left)"
            except Exception:
                exp_str = f"Expires {expires[:10]}"
        else:
            exp_str = "**Permanent**"

        source_label = {
            "under_18": "🔞 Under 18 (auto-applied)",
            "admin":    "⚙️ Admin restriction",
        }.get(lim.get("source", ""), lim.get("source", "unknown"))

        field_value = (
            f"**Source:** {source_label}\n"
            + ("**Restrictions:**\n" + "\n".join(f"  • {f}" for f in flags) + "\n" if flags else "")
            + f"**Duration:** {exp_str}"
            + (f"\n**Note:** {lim['notes']}" if lim.get("notes") else "")
        )
        embed.add_field(
            name=f"🔴 {lim.get('label', 'Restriction')}",
            value=field_value[:1020],
            inline=False,
        )

    embed.set_footer(text="⚠️  These restrictions are enforced server-wide. Do NOT approve conflicting requests.")
    await channel.send(embed=embed)

    # Plain-language notice to the user so they know their limits
    user_embed = discord.Embed(
        title="📋  Your Account Has Active Restrictions",
        description=(
            "Your account has restrictions applied that affect what you can do on the server.\n"
            "These were applied automatically or by an admin, and are listed below.\n\n"
            "If you believe this is an error, please let staff know in this ticket."
        ),
        colour=discord.Colour.orange(),
    )
    for lim in limits:
        flags = []
        if lim.get("no_firearm"):
            flags.append("• Cannot own a firearm (legal or illegal)")
        if lim.get("no_create_priority"):
            flags.append("• Cannot create priority situations")
        if lim.get("no_join_priority"):
            flags.append("• Cannot participate in priority situations")

        expires = lim.get("expires_at")
        if expires:
            try:
                exp_dt   = datetime.fromisoformat(expires.replace("Z", "+00:00"))
                now_utc  = datetime.now(timezone.utc)
                days_rem = max((exp_dt.date() - now_utc.date()).days, 0)
                exp_str  = f"Until {exp_dt.strftime('%d %b %Y')} ({days_rem} days remaining)"
            except Exception:
                exp_str = expires[:10]
        else:
            exp_str = "Permanent (no expiry set)"

        field_value = (
            ("\n".join(flags) + "\n" if flags else "No specific flag restrictions.\n")
            + f"**Expires:** {exp_str}"
        )
        user_embed.add_field(
            name=lim.get("label", "Restriction"),
            value=field_value[:1020],
            inline=False,
        )

    user_embed.set_footer(text="Questions? Ask the staff in this ticket.")
    await channel.send(content=member.mention, embed=user_embed)
    return True

async def _open_ticket(interaction, tt):
    guild      = interaction.guild
    member     = interaction.user
    staff_role = guild.get_role(Config.STAFF_ROLE_ID)
    db.ensure_tables()
    category   = await _get_or_make_type_cat(guild, tt)
    ticket_num = db.next_ticket_number()
    ch_name    = "[" + ticket_num + "-" + tt["app_key"] + "]"
    ow = {
        guild.default_role: discord.PermissionOverwrite(read_messages=False),
        member:             discord.PermissionOverwrite(read_messages=True, send_messages=True,
                                                        attach_files=True),
        guild.me:           discord.PermissionOverwrite(read_messages=True, send_messages=True,
                                                        manage_channels=True, manage_messages=True,
                                                        manage_webhooks=True),
    }
    if staff_role:
        ow[staff_role] = discord.PermissionOverwrite(read_messages=True, send_messages=True,
                                                     manage_messages=True)
    try:
        ticket_ch = await guild.create_text_channel(
            ch_name, category=category, overwrites=ow,
            topic=ticket_num + " - " + tt["name"] + " - " + str(member.id),
        )
    except discord.Forbidden:
        await interaction.edit_original_response(embed=discord.Embed(
            description="Bot missing permission to create channels.",
            colour=discord.Colour.red()))
        return

    opened_at = datetime.now(timezone.utc).replace(tzinfo=None)
    db.create_ticket(ticket_ch.id, member.id, tt["app_key"],
                     ticket_num, member.display_name, opened_at)

    embed = discord.Embed(colour=discord.Colour.blurple(),
                          timestamp=datetime.now(timezone.utc))
    embed.set_author(name=tt["emoji"] + " " + tt["name"] + " Ticket",
                     icon_url=member.display_avatar.url)
    embed.description = "Welcome " + member.mention + "! Staff will be with you shortly."
    embed.add_field(name="Ticket ID", value="`" + ticket_num + "`", inline=True)
    embed.add_field(name="Type",      value=tt["name"],              inline=True)
    embed.add_field(name="Opened By", value=member.mention,          inline=True)
    if tt.get("apply_url"):
        embed.add_field(name="Application",
                        value="[Click here](" + tt["apply_url"] + ")", inline=False)
    embed.set_footer(text=ticket_num + " - " + opened_at.strftime("%Y-%m-%d %H:%M") + " UTC")

    await ticket_ch.send(
        content=(staff_role.mention if staff_role else "") + " " + member.mention,
        embed=embed,
        view=TicketControlView(),
    )
    await _post_application(ticket_ch, member, tt["app_key"])
    await _post_user_limits(ticket_ch, member)
    await _log_event(guild, "Ticket Opened", discord.Colour.green(), [
        ("Ticket ID", "`" + ticket_num + "`", True),
        ("Type",      tt["name"],             True),
        ("User",      member.mention,         True),
        ("Channel",   ticket_ch.mention,      False),
        ("Category",  category.name,          False),
    ], member)
    await interaction.edit_original_response(embed=discord.Embed(
        description="Ticket opened: " + ticket_ch.mention + " ID: `" + ticket_num + "`",
        colour=discord.Colour.green()))


async def _assign_auto_role(guild, member, app_key, channel=None):
    """
    If the ticket type has an auto_role_id configured, grant that role to member.
    Sends a confirmation message into channel if provided.
    Safe to call for every ticket type — silently does nothing if no role is set.

    The staff role (Config.STAFF_ROLE_ID) is explicitly blocked — it must never
    be auto-assigned to a regular user through the ticket system.
    """
    tt = db.get_type(app_key)
    if not tt:
        return
    role_id_raw = tt.get("auto_role_id")
    if not role_id_raw or str(role_id_raw).lower() in ("none", ""):
        return
    try:
        role_id = int(role_id_raw)
    except (ValueError, TypeError):
        log.warning("Invalid auto_role_id %r for app_key %s — skipping", role_id_raw, app_key)
        return

    # ── Safety guard: never grant the staff role via the ticket system ────────
    if role_id == Config.STAFF_ROLE_ID:
        log.error(
            "auto_role_id for app_key %s is set to STAFF_ROLE_ID (%s) — "
            "refusing to assign staff role to user. "
            "Use !manage-roles to correct this.",
            app_key, Config.STAFF_ROLE_ID,
        )
        return

    try:
        role = guild.get_role(role_id)
        if role is None:
            log.warning("auto_role_id %s not found in guild for app_key %s", role_id, app_key)
            return
        if not isinstance(member, discord.Member):
            member = guild.get_member(int(member)) if member else None
        if member is None:
            return
        if role in member.roles:
            log.debug("Member %s already has role %s — skipping", member, role.name)
            return
        await member.add_roles(role, reason=f"Auto-assigned: {app_key} approved/closed")
        log.info("Auto-assigned role %s to %s (app_key=%s)", role.name, member, app_key)
        if channel:
            await channel.send(embed=discord.Embed(
                description=f"✅ {member.mention} has been given the {role.mention} role.",
                colour=discord.Colour.green(),
            ))
    except Exception as e:
        log.warning("Failed to auto-assign role for %s (app_key=%s): %s", member, app_key, e)


async def _close_ticket(guild, channel, closed_by):
    # Stop live polling for this channel
    stop_poll(channel.id)

    db.ensure_tables()
    rec     = db.get_ticket_by_channel(channel.id)
    tr_data = await _build_transcript(channel, rec, closed_by)
    tid     = tr_data["ticket_id"]
    _save_transcript(tr_data)
    tr_url  = _transcript_url(tid)

    # ── Auto-assign role on close (for all non-application ticket types) ───────
    # Application types (whitelist, police, etc.) get their role assigned via
    # _poll_tick when the website application status changes to "approved".
    # All other ticket types (support, gang, business, etc.) assign on close.
    from database.app_db import is_application_type
    if rec and not is_application_type(rec.get("app_key", "")):
        try:
            member = guild.get_member(int(rec["user_id"]))
            if member is None:
                member = await guild.fetch_member(int(rec["user_id"]))
        except Exception:
            member = None
        if member:
            await _assign_auto_role(guild, member, rec["app_key"], channel=None)

    tr_ch = _get_ch(guild, TICKET_TRANSCRIPT_NAME)
    if tr_ch:
        embed = discord.Embed(colour=discord.Colour.greyple(),
                              timestamp=datetime.now(timezone.utc))
        embed.set_author(name="Transcript - " + tid)
        if rec:
            embed.add_field(name="Ticket ID",  value="`" + str(rec.get("ticket_number", "?")) + "`", inline=True)
            embed.add_field(name="Type",       value=str(rec.get("app_key", "?")),                    inline=True)
            embed.add_field(name="Owner",      value="<@" + str(rec["user_id"]) + ">",               inline=True)
        embed.add_field(name="Closed By",    value=closed_by.mention,                               inline=True)
        embed.add_field(name="View Online",  value="[" + tid + "](" + tr_url + ")",                 inline=False)
        lines     = ["[" + m["ts"][:16] + "] " + m["author"] + ": " + m["content"]
                     for m in tr_data["messages"] if not m.get("system")]
        txt_bytes = "\n".join(lines).encode("utf-8")
        await tr_ch.send(embed=embed,
                         file=discord.File(io.BytesIO(txt_bytes), filename=tid + ".txt"))

    await _log_event(guild, "Ticket Closed", discord.Colour.red(), [
        ("Ticket ID",  "`" + tid + "`",                                True),
        ("Closed By",  closed_by.mention,                              True),
        ("Owner",      "<@" + str(rec["user_id"]) + ">" if rec else "?", True),
        ("Transcript", "[View online](" + tr_url + ")",                False),
    ], closed_by)

    if rec:
        db.close_ticket(channel.id, closed_by.id)

    await channel.send(embed=discord.Embed(
        description="Ticket `" + tid + "` closed. [View transcript](" + tr_url + ")",
        colour=discord.Colour.red()))
    await asyncio.sleep(5)
    try:
        await channel.delete(reason="Closed by " + str(closed_by))
    except discord.Forbidden:
        pass


async def _log_event(guild, title, colour, fields, member):
    ch = _get_ch(guild, TICKET_LOG_NAME)
    if not ch:
        return
    embed = discord.Embed(title=title, colour=colour, timestamp=datetime.now(timezone.utc))
    embed.set_thumbnail(url=member.display_avatar.url)
    for name, value, inline in fields:
        embed.add_field(name=name, value=value, inline=inline)
    await ch.send(embed=embed)


async def _post_panel(channel, tt):
    async for msg in channel.history(limit=20):
        if msg.author == channel.guild.me:
            try:
                await msg.delete()
            except Exception:
                pass
    embed = discord.Embed(
        title=tt["emoji"] + " " + tt["name"] + " Tickets",
        description="Press the button below to open a ticket."
            + ("\n\n[Application Form](" + tt["apply_url"] + ")" if tt.get("apply_url") else ""),
        colour=discord.Colour.blurple(),
    )
    embed.set_footer(text="Cape Flats Roleplay - Ticket System")
    await channel.send(embed=embed,
                       view=OpenTicketView(tt["app_key"],
                                          "Open " + tt["name"] + " Ticket",
                                          tt["emoji"]))


# ── Cog ───────────────────────────────────────────────────────────────────────

class TicketCog(commands.Cog):
    def __init__(self, bot):
        self.bot = bot
        # Re-register persistent views so old buttons still work after restart
        self.bot.add_view(TicketControlView())
        for tt in db.get_all_types():
            self.bot.add_view(OpenTicketView(tt["app_key"],
                                             "Open " + tt["name"] + " Ticket",
                                             tt["emoji"]))
        self.poll_loop.start()

    def cog_unload(self):
        self.poll_loop.cancel()

    @tasks.loop(seconds=5)
    async def poll_loop(self):
        """Live-refresh application embeds in open ticket channels."""
        await _poll_tick(self.bot)

    @poll_loop.before_loop
    async def before_poll(self):
        """Wait for Discord to be ready, then restore poll state for all open tickets."""
        await self.bot.wait_until_ready()
        await self._restore_polls()

    async def _restore_polls(self):
        """
        On startup:
        1. For ALL open tickets — find the welcome/control embed and re-post it
           with the current TicketControlView (adds any new buttons like Add User).
        2. For application-type tickets — re-register into _live_polls so the
           5s embed update loop resumes and immediately re-renders with new labels.
        """
        open_tickets = db.get_all_open_tickets()
        polls_restored    = 0
        buttons_refreshed = 0

        for rec in open_tickets:
            app_key    = rec.get("app_key", "")
            channel_id = int(rec["channel_id"])
            user_id    = int(rec["user_id"])

            # ── Find channel + member ─────────────────────────────────────────
            channel = None
            member  = None
            for guild in self.bot.guilds:
                ch = guild.get_channel(channel_id)
                if ch:
                    channel = ch
                    member  = guild.get_member(user_id)
                    if member is None:
                        try:
                            member = await guild.fetch_member(user_id)
                        except Exception:
                            pass
                    break

            if channel is None or member is None:
                log.warning("Restore: could not find channel %s or member %s — skipping", channel_id, user_id)
                continue

            # ── Step 1: Re-post the control embed with updated buttons ─────────
            try:
                control_msg = None
                async for msg in channel.history(limit=100, oldest_first=True):
                    if (msg.author == self.bot.user
                            and msg.embeds
                            and msg.components):  # has buttons = control embed
                        control_msg = msg
                        break

                if control_msg:
                    old_embed = control_msg.embeds[0]
                    await control_msg.delete()
                    await channel.send(
                        content=member.mention,
                        embed=old_embed,
                        view=TicketControlView(),
                    )
                    buttons_refreshed += 1
                    log.info("Restore: refreshed control buttons in channel %s", channel_id)
            except Exception as e:
                log.warning("Restore: error refreshing buttons in channel %s: %s", channel_id, e)

            # ── Step 2: Re-register application tickets into _live_polls ──────
            if not is_application_type(app_key):
                continue

            if channel_id in _live_polls:
                continue

            # Find the application embed (has "checking" or "updates every" in footer)
            bot_embed_msg = None
            try:
                async for msg in channel.history(limit=50, oldest_first=False):
                    if msg.author == self.bot.user and msg.embeds:
                        footer = (msg.embeds[0].footer.text or "").lower()
                        if "update" in footer or "checking" in footer:
                            bot_embed_msg = msg
                            break
            except Exception as e:
                log.warning("Restore: error scanning app embed in channel %s: %s", channel_id, e)
                continue

            if bot_embed_msg is None:
                await _post_application(channel, member, app_key)
            else:
                _live_polls[channel_id] = {
                    "member":      member,
                    "app_key":     app_key,
                    "last_app_id": None,
                    "last_status": None,
                    "msg_id":      bot_embed_msg.id,
                }
            polls_restored += 1

        log.info("Restore complete: %d control views refreshed, %d poll channels re-registered",
                 buttons_refreshed, polls_restored)

    # ── Commands ──────────────────────────────────────────────────────────────

    @commands.command(name="setup-tickets")
    @commands.has_role(Config.STAFF_ROLE_ID)
    async def setup_tickets(self, ctx):
        guild      = ctx.guild
        staff_role = guild.get_role(Config.STAFF_ROLE_ID)
        TICKET_CATEGORY_ID = 1501617058679357440

        progress = await ctx.send(embed=discord.Embed(
            title="Resetting Ticket System...",
            colour=discord.Colour.blurple(),
        ).add_field(name="Status", value="Starting...", inline=False))

        async def upd(title, fields, done=False, error=False):
            colour = (discord.Colour.red()   if error else
                      discord.Colour.green() if done  else
                      discord.Colour.blurple())
            e = discord.Embed(title=title, colour=colour, timestamp=datetime.now(timezone.utc))
            e.set_footer(text="Cape Flats Roleplay - Ticket System")
            for n, v, i in fields:
                e.add_field(name=n, value=str(v)[:1024], inline=i)
            try:
                await progress.edit(embed=e)
            except Exception:
                pass

        try:
            infra = guild.get_channel(TICKET_CATEGORY_ID)
            if infra is None or not isinstance(infra, discord.CategoryChannel):
                await upd("Setup Failed", [
                    ("Error", f"Category `{TICKET_CATEGORY_ID}` not found.", False),
                ], error=True)
                return

            await upd("Resetting...", [("Status", f"Clearing #{infra.name}...", False)])
            removed_channels = 0
            for ch in list(infra.channels):
                try:
                    await ch.delete(reason="Ticket system reset")
                    removed_channels += 1
                except Exception as e:
                    log.warning("Could not delete channel %s: %s", ch.name, e)

            await upd("Resetting...", [
                ("Status",  "Resetting database...", False),
                ("Cleared", f"{removed_channels} channels", True),
            ])
            try:
                db.reset()
            except Exception as e:
                log.exception("db.reset() failed")
                await upd("Setup Failed — DB Reset Error", [
                    ("Error", str(e), False),
                ], error=True)
                return

            types = db.get_all_types()
            if not types:
                await upd("Setup Failed — No Ticket Types", [
                    ("Error", "db.reset() ran but get_all_types() returned nothing.", False),
                ], error=True)
                return

            await upd("Rebuilding...", [
                ("Status", f"Building channels (0/{len(types)})...", False),
                ("Types",  str(len(types)) + " found", True),
            ])

            def _ow_staff():
                o = {
                    guild.default_role: discord.PermissionOverwrite(read_messages=False),
                    guild.me:           discord.PermissionOverwrite(read_messages=True, send_messages=True,
                                                                    manage_messages=True, manage_webhooks=True),
                }
                if staff_role:
                    o[staff_role] = discord.PermissionOverwrite(read_messages=True, send_messages=True)
                return o

            def _ow_panel():
                o = {
                    guild.default_role: discord.PermissionOverwrite(read_messages=True, send_messages=False),
                    guild.me:           discord.PermissionOverwrite(read_messages=True, send_messages=True,
                                                                    manage_messages=True, manage_webhooks=True),
                }
                if staff_role:
                    o[staff_role] = discord.PermissionOverwrite(read_messages=True, send_messages=True)
                return o

            log_ch = await guild.create_text_channel(TICKET_LOG_NAME,        category=infra, overwrites=_ow_staff())
            tr_ch  = await guild.create_text_channel(TICKET_TRANSCRIPT_NAME, category=infra, overwrites=_ow_staff())

            results = []
            for i, tt in enumerate(types):
                await upd("Rebuilding...", [
                    ("Status",      f"Type {i+1}/{len(types)}: {tt['name']}", False),
                    ("Logs",        log_ch.mention, True),
                    ("Transcripts", tr_ch.mention,  True),
                ])
                try:
                    ch_name  = tt["channel_name"] or _slug(tt["name"]) + "-tickets"
                    panel_ch = await guild.create_text_channel(ch_name, category=infra, overwrites=_ow_panel())
                    await _post_panel(panel_ch, tt)
                    self.bot.add_view(OpenTicketView(tt["app_key"], "Open " + tt["name"] + " Ticket", tt["emoji"]))
                    results.append(tt["emoji"] + " **" + tt["name"] + "** — " + panel_ch.mention)
                except Exception as e:
                    log.exception("Failed to create channels for type %s", tt["name"])
                    results.append("⚠️ **" + tt["name"] + "** — FAILED: " + str(e)[:80])

            await upd("Ticket System Ready", [
                ("Category",     infra.mention,                False),
                ("Logs",         log_ch.mention,               True),
                ("Transcripts",  tr_ch.mention,                True),
                ("Cleared",      f"{removed_channels} old channels", True),
                ("Database",     "Reset and reseeded",         True),
                ("Ticket Types", "\n".join(results),           False),
            ], done=True)

        except Exception as e:
            log.exception("setup_tickets crashed")
            await upd("Setup Failed — Unexpected Error", [
                ("Error", str(e)[:1000], False),
            ], error=True)

    @commands.command(name="new-ticket-type")
    @commands.has_role(Config.STAFF_ROLE_ID)
    async def new_ticket_type(self, ctx, *, args):
        db.ensure_tables()
        parts = args.split()
        url   = parts.pop() if parts and parts[-1].startswith("http") else ""
        name  = " ".join(parts).strip()
        if not name:
            await ctx.send(embed=discord.Embed(description="Usage: `!new-ticket-type <name> [url]`",
                                               colour=discord.Colour.red()))
            return
        key     = _slug(name)
        ch_name = key + "-tickets"
        if db.get_type(key):
            await ctx.send(embed=discord.Embed(description="Type `" + key + "` already exists.",
                                               colour=discord.Colour.red()))
            return
        db.add_type(name, key, url, "🎫", ch_name)
        tt         = db.get_type(key)
        infra      = _infra_cat(ctx.guild)
        staff_role = ctx.guild.get_role(Config.STAFF_ROLE_ID)
        ow = {
            ctx.guild.default_role: discord.PermissionOverwrite(read_messages=True, send_messages=False),
            ctx.guild.me:           discord.PermissionOverwrite(read_messages=True, send_messages=True,
                                                                manage_messages=True),
        }
        if staff_role:
            ow[staff_role] = discord.PermissionOverwrite(read_messages=True, send_messages=True)
        panel_ch = await ctx.guild.create_text_channel(ch_name, category=infra, overwrites=ow)
        await _post_panel(panel_ch, tt)
        cat = await _get_or_make_type_cat(ctx.guild, tt)
        self.bot.add_view(OpenTicketView(key, "Open " + name + " Ticket", "🎫"))
        embed = discord.Embed(title="Ticket Type Created", colour=discord.Colour.green())
        embed.add_field(name="Name",     value=name,             inline=True)
        embed.add_field(name="Panel",    value=panel_ch.mention, inline=True)
        embed.add_field(name="Category", value=cat.name,         inline=True)
        if url:
            embed.add_field(name="URL", value=url, inline=False)
        await ctx.send(embed=embed)

    @commands.command(name="del-ticket-type")
    @commands.has_role(Config.STAFF_ROLE_ID)
    async def del_ticket_type(self, ctx, *, name):
        db.ensure_tables()
        tt = db.get_type(_slug(name)) or next(
            (t for t in db.get_all_types() if t["name"].lower() == name.lower()), None)
        if not tt:
            await ctx.send(embed=discord.Embed(description="No type `" + name + "` found.",
                                               colour=discord.Colour.red()))
            return
        db.delete_type(tt["app_key"])
        deleted = []
        ch = discord.utils.get(ctx.guild.text_channels, name=(tt.get("channel_name") or "").lower())
        if ch:
            await ch.delete()
            deleted.append("#" + str(tt["channel_name"]))
        if tt.get("category_id"):
            cat = ctx.guild.get_channel(int(tt["category_id"]))
            if cat and isinstance(cat, discord.CategoryChannel) and not cat.channels:
                await cat.delete()
                deleted.append(cat.name)
        await ctx.send(embed=discord.Embed(
            title="Removed " + tt["name"],
            description="Deleted: " + ", ".join(deleted) if deleted else "Done.",
            colour=discord.Colour.orange()))

    @commands.command(name="list-ticket-types")
    @commands.has_role(Config.STAFF_ROLE_ID)
    async def list_ticket_types(self, ctx):
        db.ensure_tables()
        types = db.get_all_types()
        if not types:
            await ctx.send(embed=discord.Embed(description="No types. Run `!setup-tickets`.",
                                               colour=discord.Colour.orange()))
            return
        embed = discord.Embed(title="Ticket Types", colour=discord.Colour.blurple(),
                              timestamp=datetime.now(timezone.utc))
        for tt in types:
            val = "Channel: `" + str(tt["channel_name"]) + "`"
            if tt.get("apply_url"):
                val += "\nURL: " + tt["apply_url"]
            if tt.get("category_id"):
                cat = ctx.guild.get_channel(int(tt["category_id"]))
                if cat:
                    val += "\nCategory: " + cat.name
            embed.add_field(name=tt["emoji"] + " " + tt["name"], value=val, inline=True)
        embed.set_footer(text=str(len(types)) + " types")
        await ctx.send(embed=embed)

    async def cog_command_error(self, ctx, error):
        if isinstance(error, commands.MissingRole):
            await ctx.send(embed=discord.Embed(description="You need the Staff role.",
                                               colour=discord.Colour.red()))
        else:
            raise error