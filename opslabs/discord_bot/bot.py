"""
╔══════════════════════════════════════════════════════════════════════════╗
║  OpsLab Systems — Discord Bot                                            ║
║  ─────────────────────────────                                           ║
║  Bidirectional sync with the Flask site over HTTP.                       ║
║                                                                          ║
║  Status flow (kept in sync with app/models.py STATUS_META):              ║
║      Seen  →  Pending  →  In Progress  →  Resolved  /  Denied            ║
║                                                                          ║
║  Slash commands:                                                         ║
║      /setup-server, /post-ticket-panel, /post-services                   ║
║      /link-account, /my-tickets, /ping                                   ║
║      /status (in a ticket channel — change status quickly)               ║
║      /close, /reopen — legacy aliases                                    ║
╚══════════════════════════════════════════════════════════════════════════╝
"""
from __future__ import annotations

import asyncio
import logging
import os
import re
from datetime import datetime, timezone
from typing import Optional

import discord
from discord import app_commands
from discord.ext import commands
from aiohttp import web, ClientSession, ClientTimeout
from dotenv import load_dotenv

load_dotenv()


# ═══════════════════════════════════════════════════════════════════════════
#  Config
# ═══════════════════════════════════════════════════════════════════════════
def _i(name: str, default: int = 0) -> int:
    raw = os.environ.get(name, str(default)).strip()
    if raw.startswith(("0x", "0X")):
        return int(raw, 16)
    return int(raw or default)


TOKEN              = os.environ.get("DISCORD_TOKEN", "")
GUILD_ID           = _i("DISCORD_GUILD_ID")
TICKET_CATEGORY_ID = _i("DISCORD_TICKET_CATEGORY_ID")
STAFF_ROLE_ID      = _i("DISCORD_STAFF_ROLE_ID")

BRIDGE_KEY         = os.environ.get("BRIDGE_KEY", "shared-secret-change-me")
WEB_URL            = os.environ.get("WEB_URL", "https://web.opslabsystems.cloud").rstrip("/")
WEB_INTERNAL_URL   = os.environ.get("WEB_INTERNAL_URL", WEB_URL).rstrip("/")
LISTEN_PORT        = _i("BOT_LISTEN_PORT", 5090)

API_KEY            = os.environ.get("OPSLAB_API_KEY", "")

BRAND_NAME         = os.environ.get("BRAND_NAME", "OpsLab Systems")
BRAND_TAGLINE      = os.environ.get("BRAND_TAGLINE", "Build. Support. Scale. Together.")
BRAND_LOGO_URL     = os.environ.get("BRAND_LOGO_URL", "").strip()

# Grace period before deleting a closed Discord ticket channel (seconds)
CLOSE_DELETE_DELAY = _i("CLOSE_DELETE_DELAY", 30)

BRAND_BLUE         = _i("BRAND_BLUE",     0x2196F3)
COLOR_SEEN         = _i("COLOR_SEEN",     0x71B7FF)
COLOR_PENDING      = _i("COLOR_PENDING",  0xF59E0B)
COLOR_IN_PROGRESS  = _i("COLOR_IN_PROGRESS", 0x2196F3)
COLOR_RESOLVED     = _i("COLOR_RESOLVED", 0x22C55E)
COLOR_DENIED       = _i("COLOR_DENIED",   0xEF4444)
COLOR_DANGER       = _i("COLOR_DANGER",   0xEF4444)

PRIORITY_STYLES = {
    "low":    ("⚪", 0x94A3B8, "Low"),
    "normal": ("🔵", 0x2196F3, "Normal"),
    "high":   ("🟠", 0xF59E0B, "High"),
    "urgent": ("🔴", 0xEF4444, "Urgent"),
}

# ─── Status metadata — MUST mirror app/models.py STATUS_META ──────────────
STATUS_META = {
    "seen":        {"label": "Seen",        "emoji": "👀", "color": COLOR_SEEN,        "step": 1, "terminal": False},
    "pending":     {"label": "Pending",     "emoji": "⏳", "color": COLOR_PENDING,     "step": 2, "terminal": False},
    "in_progress": {"label": "In Progress", "emoji": "🛠️", "color": COLOR_IN_PROGRESS, "step": 3, "terminal": False},
    "resolved":    {"label": "Resolved",    "emoji": "✅", "color": COLOR_RESOLVED,    "step": 4, "terminal": True},
    "denied":      {"label": "Denied",      "emoji": "🚫", "color": COLOR_DENIED,      "step": 4, "terminal": True},
    # Legacy
    "open":        {"label": "Open",        "emoji": "🔓", "color": COLOR_SEEN,        "step": 1, "terminal": False},
    "closed":      {"label": "Closed",      "emoji": "🔒", "color": 0x94A3B8,          "step": 4, "terminal": True},
}
STATUS_FLOW = ["seen", "pending", "in_progress", "resolved", "denied"]

ROLE_BADGES = {
    "founder": "👑 Founder", "admin": "🛡️ Admin", "staff": "🎫 Staff",
    "user":  "👤 Client", "api":   "🤖 API",
}

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
log = logging.getLogger("opslab-bot")


# ═══════════════════════════════════════════════════════════════════════════
#  Discord client
# ═══════════════════════════════════════════════════════════════════════════
intents = discord.Intents.default()
intents.message_content = True
intents.members = True

bot = commands.Bot(command_prefix="!opslab ", intents=intents, help_command=None)


# ═══════════════════════════════════════════════════════════════════════════
#  Server blueprint (used by /setup-server)
# ═══════════════════════════════════════════════════════════════════════════
ROLES = [
    {"name": "👑 Founder",             "colour": 0xE91E63, "hoist": True,  "mentionable": False},
    {"name": "🎯 Operations Director", "colour": 0xE67E22, "hoist": True,  "mentionable": True},
    {"name": "⚙️ Administrator",       "colour": 0xD35400, "hoist": True,  "mentionable": True},
    {"name": "🧠 Lead Engineer",       "colour": 0x8E44AD, "hoist": True,  "mentionable": True},
    {"name": "💻 Senior Developer",    "colour": 0x3498DB, "hoist": True,  "mentionable": True},
    {"name": "🛠️ Developer",           "colour": 0x2980B9, "hoist": True,  "mentionable": True},
    {"name": "🎧 Support Lead",        "colour": 0x16A085, "hoist": True,  "mentionable": True},
    {"name": "🛎️ Support Specialist",  "colour": 0x1ABC9C, "hoist": True,  "mentionable": True},
    {"name": "🌐 Web Engineering",     "colour": 0x2ECC71, "hoist": False, "mentionable": True},
    {"name": "🎮 FiveM Engineering",   "colour": 0xF1C40F, "hoist": False, "mentionable": True},
    {"name": "☁️ Infrastructure",      "colour": 0x3498DB, "hoist": False, "mentionable": True},
    {"name": "🖥️ Systems Engineering", "colour": 0x34495E, "hoist": False, "mentionable": True},
    {"name": "💎 Enterprise Client",   "colour": 0x9B59B6, "hoist": True,  "mentionable": False},
    {"name": "⭐ Priority Client",     "colour": 0x00BFFF, "hoist": True,  "mentionable": False},
    {"name": "🧾 Client",              "colour": 0x95A5A6, "hoist": True,  "mentionable": False},
    {"name": "🤝 Partner",             "colour": 0xFF69B4, "hoist": True,  "mentionable": False},
    {"name": "👥 Member",              "colour": 0xBDC3C7, "hoist": False, "mentionable": False},
    {"name": "📢 Announcements Ping",  "colour": 0xE74C3C, "hoist": False, "mentionable": False},
    {"name": "🚀 Releases Ping",       "colour": 0xFF9F43, "hoist": False, "mentionable": False},
    {"name": "🤖 Bot",                 "colour": 0x607D8B, "hoist": False, "mentionable": False},
]

SERVER_STRUCTURE = [
    {"category": "📌 ─ INFORMATION ─", "private": False, "channels": [
        {"name": "👋・welcome",          "type": "text",         "topic": f"Welcome to {BRAND_NAME}. Start here."},
        {"name": "📜・rules",            "type": "text",         "topic": "Server rules and code of conduct."},
        {"name": "🗺️・getting-started",  "type": "text",         "topic": "How the platform works."},
        {"name": "📣・announcements",    "type": "announcement", "topic": "Official announcements."},
        {"name": "🚀・releases",         "type": "announcement", "topic": "New services & features."},
        {"name": "📡・site-updates",     "type": "text",         "topic": f"Updates from {WEB_URL}"},
    ]},
    {"category": "🎫 ─ CLIENT PORTAL ─", "private": False, "channels": [
        {"name": "🎟️・open-a-ticket",    "type": "text", "topic": "Open a ticket here."},
        {"name": "💡・our-services",     "type": "text", "topic": "All services overview."},
        {"name": "💰・pricing-info",     "type": "text", "topic": "Pricing & quote process."},
        {"name": "📚・knowledge-base",   "type": "text", "topic": "FAQs and guides."},
        {"name": "⭐・testimonials",      "type": "text", "topic": "Reviews and success stories."},
    ]},
    {"category": "🎫 ─ ACTIVE TICKETS ─", "private": True, "channels": []},
    {"category": "🌐 ─ WEB DEVELOPMENT ─", "private": False, "channels": [
        {"name": "🌐・web-lounge", "type": "text"}, {"name": "🎨・design-showcase", "type": "text"},
        {"name": "🧠・web-resources", "type": "text"}, {"name": "🔬・web-lab", "type": "text"},
    ]},
    {"category": "🎮 ─ FIVEM DEVELOPMENT ─", "private": False, "channels": [
        {"name": "🎮・fivem-lounge", "type": "text"}, {"name": "🗺️・maps-and-mlos", "type": "text"},
        {"name": "📜・scripts-resources", "type": "text"}, {"name": "🧪・fivem-showcase", "type": "text"},
    ]},
    {"category": "☁️ ─ HOSTING & INFRASTRUCTURE ─", "private": False, "channels": [
        {"name": "☁️・hosting-lounge", "type": "text"}, {"name": "🖥️・system-setup", "type": "text"},
        {"name": "🛡️・security-corner", "type": "text"}, {"name": "📈・performance", "type": "text"},
    ]},
    {"category": "💬 ─ COMMUNITY ─", "private": False, "channels": [
        {"name": "💬・general-chat", "type": "text"}, {"name": "🤝・introductions", "type": "text"},
        {"name": "💡・tech-news", "type": "text"}, {"name": "📸・media-share", "type": "text"},
        {"name": "🤖・bot-commands", "type": "text"},
    ]},
    {"category": "🔊 ─ VOICE CHANNELS ─", "private": False, "channels": [
        {"name": "🔊 Public Lounge", "type": "voice"},
        {"name": "💼 Client Meeting Room", "type": "voice"},
        {"name": "🧠 Dev Standup", "type": "voice"},
        {"name": "🎧 Music & Chill", "type": "voice"},
        {"name": "💤 AFK", "type": "voice"},
    ]},
    {"category": "🔒 ─ STAFF OPERATIONS ─", "private": True, "channels": [
        {"name": "📋・staff-lounge", "type": "text"}, {"name": "📊・staff-briefings", "type": "text"},
        {"name": "🗂️・ticket-archive", "type": "text"}, {"name": "📝・audit-log", "type": "text"},
        {"name": "🧾・internal-notes", "type": "text"},
        {"name": "🔊 Staff Voice", "type": "voice"}, {"name": "🎯 Leadership Voice", "type": "voice"},
    ]},
]


SERVICES = {
    "web": {
        "label": "Website Development", "tagline": "Custom websites and updates",
        "blurb": "Bespoke sites, dashboards, e-commerce, and ongoing maintenance.",
        "emoji": "🌐", "style": discord.ButtonStyle.primary,
        "specialist_role": "🌐 Web Engineering", "category": "Website Development",
        "questions": [
            ("Project type", "Landing page, dashboard, e-commerce, app…"),
            ("Tech preference", "React, Next.js, Wordpress, no preference…"),
            ("Timeline", "When do you need this?"),
            ("Budget range", "Rough budget."),
        ],
    },
    "fivem": {
        "label": "FiveM Development", "tagline": "Scripts, maps, resources",
        "blurb": "QBCore / ESX / standalone scripts, MLOs, custom maps.",
        "emoji": "🎮", "style": discord.ButtonStyle.success,
        "specialist_role": "🎮 FiveM Engineering", "category": "FiveM Development",
        "questions": [
            ("Framework", "QBCore, ESX, standalone, or other?"),
            ("What do you need?", "Script, MLO, map, full server build."),
            ("Existing setup", "Current resources we should integrate with?"),
            ("Deadline", "When do you need this live?"),
        ],
    },
    "tech": {
        "label": "Tech Support", "tagline": "Fix issues and get help",
        "blurb": "Debugging, troubleshooting, and rapid fixes.",
        "emoji": "🛠️", "style": discord.ButtonStyle.secondary,
        "specialist_role": "🛎️ Support Specialist", "category": "Tech Support",
        "questions": [
            ("The problem", "Describe in detail."),
            ("What you've tried", "Steps already attempted."),
            ("Error messages", "Paste any errors, logs, screenshots."),
            ("Urgency", "Low / Normal / High / Urgent"),
        ],
    },
    "hosting": {
        "label": "Hosting Support", "tagline": "Reliable hosting solutions",
        "blurb": "VPS, dedicated, game-server hosting — provisioning + management.",
        "emoji": "☁️", "style": discord.ButtonStyle.primary,
        "specialist_role": "☁️ Infrastructure", "category": "Hosting Support",
        "questions": [
            ("Hosting type", "VPS, dedicated, shared, game server, cloud?"),
            ("Current provider", "Where are you hosted now?"),
            ("Specs required", "RAM / CPU / storage / location."),
            ("Monthly budget", "Rough monthly budget."),
        ],
    },
    "setup": {
        "label": "System Setup", "tagline": "Setup and optimize systems",
        "blurb": "OS install, hardening, monitoring, performance tuning.",
        "emoji": "⚙️", "style": discord.ButtonStyle.success,
        "specialist_role": "🖥️ Systems Engineering", "category": "System Setup",
        "questions": [
            ("System / OS", "Linux distro, Windows Server, or other?"),
            ("Use case", "Game server, web server, dev env?"),
            ("Access available", "SSH / RDP credentials ready?"),
            ("Deadline", "When does it need to be ready?"),
        ],
    },
    "other": {
        "label": "General Enquiry", "tagline": "Anything tech related",
        "blurb": "Doesn't fit a category? Open a general ticket.",
        "emoji": "✨", "style": discord.ButtonStyle.secondary,
        "specialist_role": "🛎️ Support Specialist", "category": "Other",
        "questions": [
            ("What do you need?", "Describe in as much detail as you can."),
            ("Urgency", "Low / Normal / High / Urgent"),
        ],
    },
}


# ═══════════════════════════════════════════════════════════════════════════
#  Helpers
# ═══════════════════════════════════════════════════════════════════════════
def brand_footer(embed: discord.Embed, extra: str = "") -> discord.Embed:
    txt = f"{BRAND_NAME} • {BRAND_TAGLINE}" + (f" · {extra}" if extra else "")
    if BRAND_LOGO_URL:
        embed.set_footer(text=txt, icon_url=BRAND_LOGO_URL)
    else:
        embed.set_footer(text=txt)
    return embed


def brand_embed(title="", description="", colour=BRAND_BLUE, url=None) -> discord.Embed:
    e = discord.Embed(title=title or None, description=description or None,
                      colour=colour, timestamp=datetime.now(timezone.utc), url=url)
    brand_footer(e)
    if BRAND_LOGO_URL:
        e.set_thumbnail(url=BRAND_LOGO_URL)
    return e


def find_role(guild, name):     return discord.utils.get(guild.roles, name=name)
def find_channel(guild, name):  return discord.utils.get(guild.text_channels, name=name)
def find_category(guild, name): return discord.utils.get(guild.categories, name=name)


def staff_roles(guild):
    names = [
        "👑 Founder", "🎯 Operations Director", "⚙️ Administrator",
        "🧠 Lead Engineer", "💻 Senior Developer", "🛠️ Developer",
        "🎧 Support Lead", "🛎️ Support Specialist",
    ]
    return [r for r in (find_role(guild, n) for n in names) if r is not None]


def is_staff(member: discord.Member) -> bool:
    if member.guild_permissions.administrator:
        return True
    return any(r in staff_roles(member.guild) for r in member.roles)


async def post_web(path, payload, *, headers_extra=None):
    url = WEB_INTERNAL_URL + path
    headers = {"X-Bridge-Key": BRIDGE_KEY}
    if headers_extra: headers.update(headers_extra)
    try:
        async with ClientSession(timeout=ClientTimeout(total=8)) as s:
            async with s.post(url, json=payload, headers=headers) as r:
                try: body = await r.json()
                except Exception: body = None
                if r.status >= 300:
                    log.warning("POST %s -> %s: %s", path, r.status, body or await r.text())
                return r.status, body
    except Exception as e:
        log.warning("POST %s failed: %s", path, e)
        return 0, None


async def api_post(path, payload):
    if not API_KEY:
        log.error("OPSLAB_API_KEY is not set — ticket panel cannot create tickets.")
        return 0, None
    return await post_web(path, payload, headers_extra={"Authorization": f"Bearer {API_KEY}"})


# ═══════════════════════════════════════════════════════════════════════════
#  Status / progress bar rendering
# ═══════════════════════════════════════════════════════════════════════════
def render_progress_bar(status: str, width: int = 20) -> str:
    """Render a Unicode progress bar for the ticket status."""
    meta = STATUS_META.get(status, STATUS_META["seen"])
    step = meta.get("step", 1)
    pct = 100 if status == "denied" else min(100, step * 25)
    filled = round(width * pct / 100)
    if status == "denied":
        bar = "▰" * width      # full but in red colour via embed
    else:
        bar = "▰" * filled + "▱" * (width - filled)
    return f"`{bar}` **{pct}%**"


def render_status_track(status: str) -> str:
    """Render a horizontal track showing all 4 stages."""
    meta = STATUS_META.get(status, STATUS_META["seen"])
    current_step = meta.get("step", 1)

    # 4 stages: Seen → Pending → In Progress → Resolved/Denied
    stages = [
        ("Seen",        1),
        ("Pending",     2),
        ("In Progress", 3),
        ("Done",        4),
    ]
    out_lines = []
    icons = []
    for name, step in stages:
        if status == "denied" and step == 4:
            icons.append("🚫")
        elif step < current_step:
            icons.append("●")
        elif step == current_step:
            icons.append("🔵" if status != "denied" else "🚫")
        else:
            icons.append("○")
    out_lines.append("  ".join(icons))
    out_lines.append("  ".join(f"`{name:<11}`" for name, _ in stages))
    return "\n".join(out_lines)


def build_ticket_embed(*, ticket_id, subject, status, priority, owner,
                       owner_member, company_name, category_name,
                       initial_msg="", resolution_note=None) -> discord.Embed:
    s_meta = STATUS_META.get(status, STATUS_META["seen"])
    p_emoji, _, p_label = PRIORITY_STYLES.get(priority, PRIORITY_STYLES["normal"])
    ticket_url = f"{WEB_URL}/tickets/{ticket_id}"

    embed = discord.Embed(
        title=f"🎫 Ticket #{ticket_id}",
        description=f"### {subject}",
        color=s_meta["color"],
        timestamp=datetime.now(timezone.utc),
        url=ticket_url,
    )

    # Live status block — progress bar + track
    progress = render_progress_bar(status)
    track = render_status_track(status)
    embed.add_field(
        name=f"{s_meta['emoji']} Status — {s_meta['label']}",
        value=f"{progress}\n\n{track}",
        inline=False,
    )

    embed.add_field(name="🏢 Company",  value=f"`{company_name}`",  inline=True)
    embed.add_field(name="📂 Category", value=f"`{category_name}`", inline=True)
    embed.add_field(name="Priority",   value=f"{p_emoji} **{p_label}**", inline=True)

    embed.add_field(name="Owner",
                    value=f"<@{owner_member.id}>" if owner_member else f"`{owner}`",
                    inline=True)

    if initial_msg:
        b = initial_msg if len(initial_msg) <= 1000 else initial_msg[:1000] + "…"
        embed.add_field(name="📝 Initial Message", value=f">>> {b}", inline=False)

    if resolution_note and s_meta.get("terminal"):
        embed.add_field(name="📋 Resolution",
                        value=f">>> {resolution_note[:1000]}",
                        inline=False)

    embed.add_field(
        name="\u200b",
        value=(f"🔗 [Open on the dashboard]({ticket_url})\n"
               f"💬 Reply here or on the web — both stay in sync\n"
               f"🎛️ Use the buttons below to update status"),
        inline=False,
    )
    brand_footer(embed, f"Ticket #{ticket_id}")
    if BRAND_LOGO_URL:
        embed.set_thumbnail(url=BRAND_LOGO_URL)
    return embed


# ═══════════════════════════════════════════════════════════════════════════
#  Ticket control View (status buttons under the embed)
# ═══════════════════════════════════════════════════════════════════════════
class ResolutionNoteModal(discord.ui.Modal):
    """Asks for a short note when marking as Resolved or Denied."""

    def __init__(self, status_key: str, ticket_id: int):
        self.status_key = status_key
        self.ticket_id = ticket_id
        title = "Resolution note" if status_key == "resolved" else "Reason for denial"
        super().__init__(title=title[:45])

        self.note = discord.ui.TextInput(
            label=("How was this resolved?" if status_key == "resolved"
                   else "Why is this being denied?"),
            placeholder=("Summary that the client will see…"),
            style=discord.TextStyle.paragraph,
            required=True, max_length=1000,
        )
        self.add_item(self.note)

    async def on_submit(self, interaction: discord.Interaction):
        await interaction.response.defer(ephemeral=True, thinking=True)
        await _apply_status_change(
            interaction=interaction,
            new_status=self.status_key,
            note=self.note.value.strip(),
        )


async def _apply_status_change(*, interaction: discord.Interaction,
                               new_status: str, note: str | None = None):
    """Send status change to Flask, refresh the embed, schedule deletion if terminal."""
    if not isinstance(interaction.channel, discord.TextChannel):
        return await interaction.followup.send("Not a ticket channel.", ephemeral=True)

    status_obj, body = await post_web("/bridge/discord/status", {
        "channel_id": str(interaction.channel.id),
        "status": new_status,
        "actor": str(interaction.user),
        "resolution_note": note,
    })
    if status_obj != 200 or not body or not body.get("ok"):
        return await interaction.followup.send(
            "❌ Couldn't update the status. Try again in a moment.",
            ephemeral=True,
        )

    ticket = body.get("ticket") or {}
    meta = STATUS_META.get(new_status, STATUS_META["seen"])

    # Refresh the intake embed by editing the bot's first message in the channel
    await _refresh_pinned_intake_embed(interaction.channel, ticket)

    # Announcement message in-channel
    announce = brand_embed(
        title=f"{meta['emoji']} Status: {meta['label']}",
        description=f"Updated by {interaction.user.mention}",
        colour=meta["color"],
    )
    if note:
        announce.add_field(name="📋 Note", value=f">>> {note[:1000]}", inline=False)
    try:
        await interaction.channel.send(embed=announce)
    except discord.HTTPException:
        pass

    await interaction.followup.send(
        f"{meta['emoji']} Marked as **{meta['label']}**.",
        ephemeral=True,
    )

    # If terminal → schedule auto-delete
    if meta.get("terminal"):
        await _schedule_channel_delete(interaction.channel, meta["label"])


async def _refresh_pinned_intake_embed(channel: discord.TextChannel, ticket: dict):
    """Find the original intake embed (bot's first message with our footer) and
    update it to reflect the new status."""
    try:
        async for msg in channel.history(limit=20, oldest_first=True):
            if msg.author == bot.user and msg.embeds:
                old = msg.embeds[0]
                if old.title and "Ticket #" in (old.title or ""):
                    guild = channel.guild
                    owner_member = None
                    if ticket.get("owner_discord_id"):
                        try:
                            owner_member = guild.get_member(int(ticket["owner_discord_id"]))
                        except (TypeError, ValueError):
                            pass
                    embed = build_ticket_embed(
                        ticket_id=ticket.get("id", "?"),
                        subject=ticket.get("subject", "Ticket"),
                        status=ticket.get("status", "seen"),
                        priority=ticket.get("priority", "normal"),
                        owner=ticket.get("owner", "user"),
                        owner_member=owner_member,
                        company_name=ticket.get("company", BRAND_NAME),
                        category_name=ticket.get("category", "General"),
                        initial_msg="",                       # leave existing message field
                        resolution_note=ticket.get("resolution_note"),
                    )
                    # Preserve the initial-message field from the old embed if it had one
                    for f in old.fields:
                        if f.name and "Initial Message" in f.name:
                            embed.add_field(name=f.name, value=f.value, inline=False)
                            break

                    try:
                        await msg.edit(embed=embed,
                                       view=TicketControlView(ticket.get("status", "seen")))
                    except discord.HTTPException as e:
                        log.warning("Couldn't refresh intake embed: %s", e)
                    return
    except Exception as e:
        log.warning("Couldn't find intake embed to refresh: %s", e)


async def _schedule_channel_delete(channel: discord.TextChannel, reason_label: str):
    """Post a countdown and delete the channel after CLOSE_DELETE_DELAY seconds."""
    delay = CLOSE_DELETE_DELAY
    if delay <= 0:
        try: await channel.delete(reason=f"Ticket {reason_label}")
        except discord.HTTPException: pass
        return

    embed = brand_embed(
        title="🗑️ Channel will be deleted",
        description=(f"This ticket is **{reason_label}**.\n\n"
                     f"The channel will be deleted in **{delay}** seconds.\n"
                     f"The full transcript is saved on the web."),
        colour=0x94A3B8,
    )
    try:
        warn_msg = await channel.send(embed=embed)
    except discord.HTTPException:
        warn_msg = None

    await asyncio.sleep(delay)
    try:
        await channel.delete(reason=f"Ticket {reason_label} — auto-cleanup")
    except discord.HTTPException as e:
        log.warning("Failed to delete ticket channel %s: %s", channel.id, e)
        # Fall back: rename + lock instead
        try:
            await channel.edit(name=channel.name[:90] + "-archived",
                               sync_permissions=False)
        except discord.HTTPException:
            pass


class TicketControlView(discord.ui.View):
    """Persistent view with status-change buttons. Rendered under every ticket."""

    def __init__(self, current_status: str = "seen"):
        super().__init__(timeout=None)
        # Add buttons; visually de-emphasise the current one
        for key, style in [
            ("seen",        discord.ButtonStyle.secondary),
            ("pending",     discord.ButtonStyle.secondary),
            ("in_progress", discord.ButtonStyle.primary),
        ]:
            meta = STATUS_META[key]
            btn = discord.ui.Button(
                label=meta["label"],
                emoji=meta["emoji"],
                style=(discord.ButtonStyle.success
                       if key == current_status else style),
                custom_id=f"opslab:status:{key}",
                row=0,
            )
            btn.callback = self._make_callback(key)
            self.add_item(btn)

        # Terminal actions on row 1
        for key, style in [("resolved", discord.ButtonStyle.success),
                           ("denied",   discord.ButtonStyle.danger)]:
            meta = STATUS_META[key]
            btn = discord.ui.Button(
                label=meta["label"],
                emoji=meta["emoji"],
                style=style,
                custom_id=f"opslab:status:{key}",
                row=1,
            )
            btn.callback = self._make_callback(key)
            self.add_item(btn)

        # Close button (deletes the channel without changing status — for legacy)
        close_btn = discord.ui.Button(
            label="Close",
            emoji="🗑️",
            style=discord.ButtonStyle.secondary,
            custom_id="opslab:close",
            row=1,
        )
        close_btn.callback = self._close_callback
        self.add_item(close_btn)

    def _make_callback(self, status_key: str):
        async def cb(interaction: discord.Interaction):
            # Permission: only staff or admin can change status
            if not (isinstance(interaction.user, discord.Member)
                    and is_staff(interaction.user)):
                return await interaction.response.send_message(
                    "Only staff can update ticket status.", ephemeral=True,
                )
            # Terminal statuses ask for a note
            if status_key in ("resolved", "denied"):
                return await interaction.response.send_modal(
                    ResolutionNoteModal(status_key, ticket_id=0)
                )
            await interaction.response.defer(ephemeral=True, thinking=True)
            await _apply_status_change(
                interaction=interaction, new_status=status_key,
            )
        return cb

    async def _close_callback(self, interaction: discord.Interaction):
        if not (isinstance(interaction.user, discord.Member)
                and is_staff(interaction.user)):
            return await interaction.response.send_message(
                "Only staff can close tickets.", ephemeral=True,
            )
        await interaction.response.defer(ephemeral=True, thinking=True)
        # "Close" = mark resolved with no specific note
        await _apply_status_change(
            interaction=interaction, new_status="resolved", note=None,
        )


# ═══════════════════════════════════════════════════════════════════════════
#  /setup-server  —  builds the whole server (unchanged from prior version)
# ═══════════════════════════════════════════════════════════════════════════
async def _ensure_role(guild, spec):
    existing = find_role(guild, spec["name"])
    if existing: return existing, "exists"
    try:
        r = await guild.create_role(
            name=spec["name"], colour=discord.Colour(spec["colour"]),
            hoist=spec["hoist"], mentionable=spec["mentionable"],
            reason="OpsLab Systems server blueprint",
        )
        return r, "created"
    except discord.Forbidden: return None, "no-perms"
    except discord.HTTPException as e: return None, f"err:{e.text}"


async def _ensure_category(guild, name, private):
    existing = find_category(guild, name)
    overwrites = {}
    if private:
        overwrites[guild.default_role] = discord.PermissionOverwrite(view_channel=False)
        for r in staff_roles(guild):
            overwrites[r] = discord.PermissionOverwrite(
                view_channel=True, send_messages=True, manage_messages=True)
        if guild.me:
            overwrites[guild.me] = discord.PermissionOverwrite(
                view_channel=True, send_messages=True,
                manage_channels=True, manage_messages=True)
    if existing:
        if private:
            try: await existing.edit(overwrites=overwrites)
            except discord.Forbidden: pass
        return existing, "exists"
    try:
        c = await guild.create_category(name=name, overwrites=overwrites,
                                        reason="OpsLab Systems blueprint")
        return c, "created"
    except discord.Forbidden: return None, "no-perms"


async def _ensure_channel(guild, cat, spec):
    name = spec["name"]
    existing = discord.utils.get(cat.channels, name=name)
    if existing: return existing, "exists"
    ctype = spec.get("type", "text")
    topic = spec.get("topic")
    try:
        if ctype == "voice":
            return await guild.create_voice_channel(name=name, category=cat), "created"
        if ctype == "announcement":
            try:
                return await guild.create_text_channel(
                    name=name, category=cat, topic=topic, news=True), "created"
            except (discord.HTTPException, TypeError):
                return await guild.create_text_channel(
                    name=name, category=cat, topic=topic), "created"
        return await guild.create_text_channel(
            name=name, category=cat, topic=topic), "created"
    except discord.Forbidden: return None, "no-perms"
    except discord.HTTPException as e: return None, f"err:{e.text}"


@bot.tree.command(name="setup-server",
                  description="Build the full OpsLab Systems server. Admin only.")
@app_commands.default_permissions(administrator=True)
async def setup_server(interaction: discord.Interaction):
    await interaction.response.defer(ephemeral=True, thinking=True)
    guild = interaction.guild
    if guild is None:
        return await interaction.followup.send("Run this inside a server.", ephemeral=True)

    lines = ["┏━━ ROLES ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"]
    for spec in ROLES:
        _, status = await _ensure_role(guild, spec)
        mark = "✅" if status in ("exists", "created") else "❌"
        lines.append(f"┃ {mark} {spec['name']:<28} {status}")
    lines.append("┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

    for section in SERVER_STRUCTURE:
        lines.append(f"\n┏━━ {section['category']}")
        cat, cstatus = await _ensure_category(guild, section["category"], section["private"])
        if not cat:
            lines.append(f"┃ ❌ category — {cstatus}"); continue
        lines.append(f"┃ 📁 category {cstatus}")
        for ch_spec in section["channels"]:
            _, chstatus = await _ensure_channel(guild, cat, ch_spec)
            mark = "✅" if chstatus in ("exists", "created") else "❌"
            lines.append(f"┃   {mark} {ch_spec['name']:<28} {chstatus}")
        lines.append("┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

    summary = brand_embed(
        title="✅ Server setup complete",
        description=(f"**Welcome to {BRAND_NAME}.**\n\n"
                     f"Next steps:\n"
                     f"• Run `/post-ticket-panel`\n"
                     f"• Run `/post-services`\n"
                     f"• Drag the bot's role above all custom roles."),
        colour=COLOR_RESOLVED, url=WEB_URL,
    )
    await interaction.followup.send(embed=summary, ephemeral=True)

    chunks, cur = [], ""
    for ln in lines:
        if len(cur) + len(ln) + 1 > 1800:
            chunks.append(cur); cur = ""
        cur += ln + "\n"
    if cur: chunks.append(cur)
    for ch in chunks:
        await interaction.followup.send(f"```\n{ch}\n```", ephemeral=True)


# ═══════════════════════════════════════════════════════════════════════════
#  Ticket panel — buttons & modal (mostly unchanged)
# ═══════════════════════════════════════════════════════════════════════════
class TicketDetailsModal(discord.ui.Modal):
    def __init__(self, service_key: str):
        self.service_key = service_key
        svc = SERVICES[service_key]
        super().__init__(title=f"{svc['emoji']} {svc['label']}"[:45])

        self.subject_input = discord.ui.TextInput(
            label="Subject", placeholder="One-line summary of what you need",
            style=discord.TextStyle.short, required=True, max_length=180,
        )
        self.add_item(self.subject_input)

        self.q_inputs = []
        self.q_labels = []
        for q_label, q_placeholder in svc["questions"][:4]:
            ti = discord.ui.TextInput(
                label=q_label[:45], placeholder=q_placeholder[:100],
                style=discord.TextStyle.paragraph, required=True, max_length=1000,
            )
            self.q_inputs.append(ti)
            self.q_labels.append(q_label[:45])
            self.add_item(ti)

    async def on_submit(self, interaction: discord.Interaction):
        await interaction.response.defer(ephemeral=True, thinking=True)
        svc = SERVICES[self.service_key]
        user = interaction.user

        body_lines = [f"**{label}**\n{q_in.value}"
                      for label, q_in in zip(self.q_labels, self.q_inputs)]
        body = "\n\n".join(body_lines)

        status, lookup = await post_web("/bridge/discord/resolve-user", {
            "discord_id": str(user.id),
            "discord_username": str(user),
        })
        if status != 200 or not lookup or "user_id" not in (lookup or {}):
            return await interaction.followup.send(
                f"⚠️ Couldn't link your Discord account to a website user.\n"
                f"Sign up at {WEB_URL} or ask staff to link your account.",
                ephemeral=True,
            )

        user_id = lookup["user_id"]
        company_id = lookup.get("default_company_id")
        category_id = lookup.get("categories", {}).get(svc["category"])
        is_placeholder = lookup.get("is_placeholder", False)

        status, created = await api_post("/api/v1/tickets", {
            "user_id":     user_id,
            "subject":     self.subject_input.value[:180],
            "body":        body,
            "company_id":  company_id,
            "category_id": category_id,
            "priority":    "normal",
        })

        if status not in (200, 201) or not created:
            return await interaction.followup.send(
                "❌ Failed to create the ticket. Please try again in a moment, "
                "or open the ticket directly at " + WEB_URL + "/tickets/new",
                ephemeral=True,
            )

        ticket_id = created.get("id")
        chan_id = created.get("discord_channel_id")
        link = f"{WEB_URL}/tickets/{ticket_id}"

        embed = brand_embed(
            title=f"✅ Ticket #{ticket_id} created",
            description=f"**{self.subject_input.value[:180]}**",
            colour=COLOR_RESOLVED, url=link,
        )
        if chan_id:
            chan = interaction.guild.get_channel(int(chan_id)) if interaction.guild else None
            if chan:
                embed.add_field(name="💬 Discord channel", value=chan.mention, inline=True)
        embed.add_field(name="🌐 Web", value=f"[Open on the dashboard]({link})", inline=True)

        if is_placeholder:
            embed.add_field(
                name="💡 Tip — link your account",
                value=(f"Run `/link-account <your-website-username>` to connect this "
                       f"ticket to your real website account."),
                inline=False,
            )
        await interaction.followup.send(embed=embed, ephemeral=True)


class ServiceSelect(discord.ui.Select):
    def __init__(self):
        opts = [
            discord.SelectOption(label=s["label"], description=s["tagline"][:100],
                                 emoji=s["emoji"], value=k)
            for k, s in SERVICES.items()
        ]
        super().__init__(placeholder="📋 Choose a service to open a ticket…",
                         options=opts, min_values=1, max_values=1,
                         custom_id="opslab:service_select")

    async def callback(self, interaction: discord.Interaction):
        await interaction.response.send_modal(TicketDetailsModal(self.values[0]))


class QuickServiceButton(discord.ui.Button):
    def __init__(self, key: str, row: int):
        s = SERVICES[key]
        super().__init__(label=s["label"], emoji=s["emoji"], style=s["style"],
                         row=row, custom_id=f"opslab:btn:{key}")
        self.key = key

    async def callback(self, interaction: discord.Interaction):
        await interaction.response.send_modal(TicketDetailsModal(self.key))


class TicketPanelView(discord.ui.View):
    def __init__(self):
        super().__init__(timeout=None)
        self.add_item(ServiceSelect())
        self.add_item(QuickServiceButton("web",     row=1))
        self.add_item(QuickServiceButton("fivem",   row=1))
        self.add_item(QuickServiceButton("tech",    row=1))
        self.add_item(QuickServiceButton("hosting", row=2))
        self.add_item(QuickServiceButton("setup",   row=2))
        self.add_item(QuickServiceButton("other",   row=2))


@bot.tree.command(name="post-ticket-panel",
                  description="Publish the ticket panel. Admin only.")
@app_commands.default_permissions(administrator=True)
async def post_ticket_panel(interaction: discord.Interaction,
                            channel: Optional[discord.TextChannel] = None):
    channel = channel or interaction.channel
    if not isinstance(channel, discord.TextChannel):
        return await interaction.response.send_message("Pick a text channel.", ephemeral=True)

    e = brand_embed(
        title="🎫 Open a Support Ticket",
        description=(
            f"**{BRAND_TAGLINE}**\n\n"
            f"From custom websites to FiveM scripts, hosting to system setup — "
            f"under one roof, one team, one ticket system.\n\n"
            f"**Choose a service** from the dropdown or click a button below."
        ),
        url=f"{WEB_URL}/#services",
    )
    for s in SERVICES.values():
        e.add_field(name=f"{s['emoji']} {s['label']}", value=s["tagline"], inline=True)
    e.add_field(name="\u200b",
                value=("🔒 **Private** — only you & staff see your ticket\n"
                       "⚡ **Live sync** — replies appear on web & Discord within seconds\n"
                       "🎯 **Specialist routing** — your ticket goes to the right expert\n"
                       f"🌐 **Web:** [{WEB_URL}]({WEB_URL})"),
                inline=False)

    await channel.send(embed=e, view=TicketPanelView())
    await interaction.response.send_message(f"✅ Posted in {channel.mention}", ephemeral=True)


@bot.tree.command(name="post-services",
                  description="Publish the services embed. Admin only.")
@app_commands.default_permissions(administrator=True)
async def post_services(interaction: discord.Interaction,
                        channel: Optional[discord.TextChannel] = None):
    channel = channel or interaction.channel
    if not isinstance(channel, discord.TextChannel):
        return await interaction.response.send_message("Pick a text channel.", ephemeral=True)

    e = brand_embed(
        title="💡 Our Services",
        description=(f"**{BRAND_TAGLINE}**\n\n"
                     f"🔗 [View on the site]({WEB_URL}/#services)"),
        url=f"{WEB_URL}/#services",
    )
    for s in SERVICES.values():
        e.add_field(
            name=f"{s['emoji']} {s['label']}",
            value=f"*{s['tagline']}*\n{s['blurb']}",
            inline=False,
        )
    await channel.send(embed=e)
    await interaction.response.send_message(f"✅ Posted in {channel.mention}", ephemeral=True)


# ═══════════════════════════════════════════════════════════════════════════
#  /link-account, /my-tickets, /ping
# ═══════════════════════════════════════════════════════════════════════════
LINK_CODE_RE = re.compile(r"^\s*([A-HJ-NP-Z2-9]{4})-?([A-HJ-NP-Z2-9]{4})\s*$", re.I)


async def _link_with_code(user: discord.abc.User, code: str) -> discord.Embed:
    """Redeem a one-time website link code for this Discord user."""
    status, body = await post_web("/bridge/discord/link", {
        "code": code.strip(),
        "discord_id": str(user.id),
        "discord_username": str(user),
    })
    if status == 200 and body and body.get("ok"):
        username = body.get("user", "your account")
        moved = body.get("transferred_tickets", 0)
        embed = brand_embed(
            title="✅ Account linked",
            description=(f"Your Discord is now linked to web user **{username}**.\n"
                         f"If you chose Discord replies on a ticket, updates will arrive here in DMs."),
            colour=COLOR_RESOLVED, url=WEB_URL,
        )
        if moved:
            embed.add_field(
                name="🎫 Tickets transferred",
                value=(f"Found **{moved}** ticket{'s' if moved != 1 else ''} you opened on Discord "
                       f"before linking — all moved to your `{username}` account."),
                inline=False,
            )
        embed.add_field(name="🌐 Manage your tickets",
                        value=f"[{WEB_URL}/tickets]({WEB_URL}/tickets)", inline=False)
        return embed
    if status == 409 and body:
        return brand_embed(title="⚠️ Already linked",
                           description=body.get("error", "This Discord account is already linked to someone else."),
                           colour=COLOR_PENDING)
    if status in (400, 404) and body and body.get("error"):
        return brand_embed(title="❌ Couldn't link account", description=body["error"], colour=COLOR_DANGER)
    return brand_embed(title="❌ Couldn't link account",
                       description=f"Something went wrong. Try again from {WEB_URL}/tickets/new.",
                       colour=COLOR_DANGER)


@bot.tree.command(name="link-account",
                  description="Link your Discord to your website account using the code from the website.")
@app_commands.describe(code="The 8-character code shown on the website (e.g. ABCD-2345)")
async def link_account(interaction: discord.Interaction, code: str):
    await interaction.response.defer(ephemeral=True, thinking=True)
    embed = await _link_with_code(interaction.user, code)
    await interaction.followup.send(embed=embed, ephemeral=True)


@bot.tree.command(name="my-tickets",
                  description="List your open & recent tickets.")
async def my_tickets(interaction: discord.Interaction):
    await interaction.response.defer(ephemeral=True, thinking=True)
    status, body = await post_web("/bridge/discord/my-tickets", {
        "discord_id": str(interaction.user.id), "limit": 15,
    })

    if status != 200 or not body:
        return await interaction.followup.send(
            embed=brand_embed(
                title="❌ Couldn't fetch your tickets",
                description="The website isn't responding. Try again in a moment.",
                colour=COLOR_DANGER,
            ), ephemeral=True,
        )

    tickets = body.get("tickets", [])
    is_placeholder = body.get("is_placeholder", False)

    if not tickets:
        return await interaction.followup.send(
            embed=brand_embed(
                title="📭 No tickets yet",
                description=("You haven't opened any tickets.\n"
                             "Click a service button on the ticket panel to open your first one."),
            ), ephemeral=True,
        )

    embed = brand_embed(
        title=f"🎫 Your tickets ({len(tickets)})",
        description=(f"Your **{len(tickets)}** most recent tickets."
                     + (f"\n\n💡 Run `/link-account <username>` to merge these into your "
                        f"main website account." if is_placeholder else "")),
        url=f"{WEB_URL}/tickets",
    )

    for t in tickets[:10]:
        meta = STATUS_META.get(t.get("status"), STATUS_META["seen"])
        pri_emoji = {"low":"⚪","normal":"🔵","high":"🟠","urgent":"🔴"}.get(t.get("priority"), "")
        subject = (t.get("subject") or "Untitled")[:80]
        link = f"{WEB_URL}/tickets/{t['id']}"
        embed.add_field(
            name=f"#{t['id']:04d} · {meta['emoji']} {meta['label']} · {pri_emoji}",
            value=f"[{subject}]({link})",
            inline=False,
        )
    if len(tickets) > 10:
        embed.add_field(
            name="\u200b",
            value=f"…and {len(tickets) - 10} more. [View all on the web]({WEB_URL}/tickets)",
            inline=False,
        )
    await interaction.followup.send(embed=embed, ephemeral=True)


@bot.tree.command(name="ping", description="Check the bot is alive.")
async def ping_cmd(interaction: discord.Interaction):
    await interaction.response.send_message(
        f"🏓 Pong! `{round(bot.latency * 1000)}ms`", ephemeral=True,
    )


# ═══════════════════════════════════════════════════════════════════════════
#  Ticket channel utilities
# ═══════════════════════════════════════════════════════════════════════════
TICKET_NAME_RE = re.compile(r"^ticket-\d+(-[\w-]*)?(?:-closed|-archived)?$")


def is_ticket_channel(channel):
    return isinstance(channel, discord.TextChannel) and bool(TICKET_NAME_RE.match(channel.name))


@bot.tree.command(name="status",
                  description="Change this ticket's status. Staff only.")
@app_commands.describe(new_status="The new status to set")
@app_commands.choices(new_status=[
    app_commands.Choice(name="👀 Seen", value="seen"),
    app_commands.Choice(name="⏳ Pending", value="pending"),
    app_commands.Choice(name="🛠️ In Progress", value="in_progress"),
    app_commands.Choice(name="✅ Resolved", value="resolved"),
    app_commands.Choice(name="🚫 Denied", value="denied"),
])
async def status_cmd(interaction: discord.Interaction,
                     new_status: app_commands.Choice[str]):
    if not is_ticket_channel(interaction.channel):
        return await interaction.response.send_message("Not a ticket channel.", ephemeral=True)
    if not (isinstance(interaction.user, discord.Member) and is_staff(interaction.user)):
        return await interaction.response.send_message("Staff only.", ephemeral=True)

    if new_status.value in ("resolved", "denied"):
        return await interaction.response.send_modal(
            ResolutionNoteModal(new_status.value, ticket_id=0)
        )

    await interaction.response.defer(ephemeral=True, thinking=True)
    await _apply_status_change(interaction=interaction, new_status=new_status.value)


@bot.tree.command(name="close", description="Close this ticket (= resolve).")
async def close_cmd(interaction: discord.Interaction):
    if not is_ticket_channel(interaction.channel):
        return await interaction.response.send_message("Not a ticket channel.", ephemeral=True)
    if not (isinstance(interaction.user, discord.Member) and is_staff(interaction.user)):
        return await interaction.response.send_message("Staff only.", ephemeral=True)
    return await interaction.response.send_modal(
        ResolutionNoteModal("resolved", ticket_id=0)
    )


@bot.tree.command(name="reopen", description="Reopen this ticket as Seen.")
async def reopen_cmd(interaction: discord.Interaction):
    if not is_ticket_channel(interaction.channel):
        return await interaction.response.send_message("Not a ticket channel.", ephemeral=True)
    if not (isinstance(interaction.user, discord.Member) and is_staff(interaction.user)):
        return await interaction.response.send_message("Staff only.", ephemeral=True)
    await interaction.response.defer(ephemeral=False)
    await _apply_status_change(interaction=interaction, new_status="seen")


# ═══════════════════════════════════════════════════════════════════════════
#  Live message bridge: Discord → Web
# ═══════════════════════════════════════════════════════════════════════════
TICKET_REF_RE = re.compile(r"Ticket #(\d+)")


def _ticket_id_from_message(msg: discord.Message) -> Optional[int]:
    """Our DM embeds carry 'Ticket #N' in the title/footer — read it back."""
    if not msg or msg.author != bot.user:
        return None
    for e in msg.embeds:
        for text in (e.title or "", e.footer.text if e.footer else ""):
            m = TICKET_REF_RE.search(text or "")
            if m:
                return int(m.group(1))
    return None


def _attachment_text(message: discord.Message) -> str:
    if not message.attachments:
        return ""
    return "📎 Attachments:\n" + "\n".join(a.url for a in message.attachments)


async def _handle_dm(message: discord.Message):
    content = (message.content or "").strip()

    # Staff: Discord "Reply" on a staff-inbox message answers that ticket.
    ref = message.reference
    if ref and ref.message_id:
        try:
            ref_msg = ref.resolved if isinstance(ref.resolved, discord.Message) \
                else await message.channel.fetch_message(ref.message_id)
        except discord.HTTPException:
            ref_msg = None
        if _is_staff_inbox_message(ref_msg):
            tid = _ticket_id_from_message(ref_msg)
            body = content + (("\n\n" + _attachment_text(message)) if message.attachments else "")
            if tid and body.strip():
                await message.channel.send(await _staff_reply(message.author, tid, body.strip()))
            return

    if content.lower() in ("menu", "tickets", "inbox", "!menu", "/menu"):
        if await _staff_menu(message):
            return

    code = LINK_CODE_RE.match(content)
    if code and not message.attachments:
        await message.channel.send(embed=await _link_with_code(message.author, code.group(1) + code.group(2)))
        return

    status, data = await post_web("/bridge/discord/dm/open-tickets", {"discord_id": str(message.author.id)})
    if status != 200 or not data:
        await message.channel.send("⚠️ I couldn't reach the ticket system — please try again in a minute.")
        return
    if not data.get("linked"):
        await message.channel.send(embed=brand_embed(
            title="👋 Link your account first",
            description=(f"Open a ticket at {WEB_URL}/tickets/new, choose **Discord DMs**, "
                         f"click **Get my link code**, then send that code here."),
            url=f"{WEB_URL}/tickets/new"))
        return

    tickets = data.get("tickets") or []
    open_ids = {t["id"] for t in tickets}
    ticket_id = None
    body = content

    ref = message.reference
    if ref and ref.message_id:
        try:
            ref_msg = ref.resolved if isinstance(ref.resolved, discord.Message) \
                else await message.channel.fetch_message(ref.message_id)
            ticket_id = _ticket_id_from_message(ref_msg)
        except discord.HTTPException:
            pass
    prefix = re.match(r"^#(\d{1,7})\b[\s:,-]*", content)
    if ticket_id is None and prefix:
        ticket_id = int(prefix.group(1))
        body = content[prefix.end():].strip()
    if ticket_id is None and len(tickets) == 1:
        ticket_id = tickets[0]["id"]

    if ticket_id is None or ticket_id not in open_ids:
        if not tickets:
            desc = (f"You don't have any open tickets that use Discord replies.\n"
                    f"Open one at {WEB_URL}/tickets/new and pick **Discord DMs** or **Both**.")
        else:
            lines = "\n".join(f"• `#{t['id']}` {t['subject'][:60]}" for t in tickets[:10])
            desc = ("Which ticket is this for? **Reply** to one of my ticket messages, "
                    f"or start your message with the number, e.g. `#{tickets[0]['id']} your message`.\n\n{lines}")
        await message.channel.send(embed=brand_embed(title="🎫 Which ticket?", description=desc))
        return

    attach = _attachment_text(message)
    if attach:
        body = (body + "\n\n" if body else "") + attach
    if not body:
        return

    status, res = await post_web("/bridge/discord/dm/message", {
        "discord_id": str(message.author.id),
        "ticket_id": ticket_id,
        "discord_message_id": str(message.id),
        "author": str(message.author),
        "body": body,
    })
    if status == 200 and res and res.get("ok"):
        try:
            await message.add_reaction("✅")
        except discord.HTTPException:
            pass
        ch_id = res.get("channel_id")
        channel = bot.get_channel(int(ch_id)) if ch_id else None
        if channel:
            e = discord.Embed(description=body[:4000], color=0x5865F2, timestamp=datetime.now(timezone.utc))
            e.set_author(name=f"👤 Client · {message.author} (via DM)")
            brand_footer(e)
            try:
                await channel.send(embed=e)
            except discord.HTTPException:
                log.warning("Could not mirror DM into ticket channel %s", ch_id)
    else:
        err = (res or {}).get("error") or "Could not deliver your message — please try again."
        await message.channel.send(f"❌ {err}")


# ═══════════════════════════════════════════════════════════════════════════
#  Staff inbox in DMs: new tickets + customer replies, with action buttons
# ═══════════════════════════════════════════════════════════════════════════
STAFF_FOOTER = "🛠 Staff inbox"
STATUS_BUTTONS = {"pending": "pending", "progress": "in_progress"}


def _is_staff_inbox_message(msg: Optional[discord.Message]) -> bool:
    return bool(msg and msg.author == bot.user and msg.embeds
                and (msg.embeds[0].footer.text or "").startswith(STAFF_FOOTER))


async def _staff_reply(user: discord.abc.User, ticket_id: int, body: str, internal: bool = False) -> str:
    status, res = await post_web("/bridge/discord/staff/reply", {
        "discord_id": str(user.id), "ticket_id": ticket_id, "body": body, "internal": internal})
    if status == 200 and res and res.get("ok"):
        return (f"📝 Internal note added to ticket #{ticket_id}." if internal
                else f"✅ Reply sent to ticket #{ticket_id} (website, ticket channel and customer DMs).")
    if status == 403:
        return "⛔ Only linked staff accounts can do that."
    return f"❌ {(res or {}).get('error') or 'Could not send — please try again.'}"


async def _staff_status(user: discord.abc.User, ticket_id: int, status_key: str, note: str = "") -> str:
    status, res = await post_web("/bridge/discord/staff/status", {
        "discord_id": str(user.id), "ticket_id": ticket_id, "status": status_key, "note": note})
    if status == 200 and res and res.get("ok"):
        meta = STATUS_META.get(res["status"], STATUS_META["seen"])
        return f"{meta['emoji']} Ticket #{ticket_id} is now **{meta['label']}**."
    if status == 403:
        return "⛔ Only linked staff accounts can do that."
    return f"❌ {(res or {}).get('error') or 'Could not update the status.'}"


class StaffTextModal(discord.ui.Modal):
    def __init__(self, ticket_id: int, mode: str):
        titles = {"reply": f"Reply to ticket #{ticket_id}", "note": f"Internal note · #{ticket_id}",
                  "resolve": f"Resolve ticket #{ticket_id}", "deny": f"Deny ticket #{ticket_id}"}
        super().__init__(title=titles[mode][:45], timeout=900)
        self.ticket_id, self.mode = ticket_id, mode
        required = mode in ("reply", "note", "deny")
        label = {"reply": "Your reply to the customer", "note": "Note (staff only)",
                 "resolve": "Resolution note (optional)", "deny": "Reason (the customer sees this)"}[mode]
        self.text = discord.ui.TextInput(label=label, style=discord.TextStyle.paragraph,
                                         required=required, max_length=2000)
        self.add_item(self.text)

    async def on_submit(self, interaction: discord.Interaction):
        await interaction.response.defer(thinking=True)
        value = str(self.text.value or "").strip()
        if self.mode in ("reply", "note"):
            msg = await _staff_reply(interaction.user, self.ticket_id, value, internal=self.mode == "note")
        else:
            msg = await _staff_status(interaction.user, self.ticket_id,
                                      "resolved" if self.mode == "resolve" else "denied", value)
        await interaction.followup.send(msg)


class StaffAction(discord.ui.DynamicItem[discord.ui.Button],
                  template=r"sdm:(?P<action>reply|note|view|pending|progress|resolve|deny):(?P<tid>\d+)"):
    """Persistent staff buttons — custom_id carries the ticket, so they work after restarts."""
    STYLE = {
        "reply":    ("💬 Reply", discord.ButtonStyle.primary, 0),
        "note":     ("📝 Internal note", discord.ButtonStyle.secondary, 0),
        "view":     ("🔍 View", discord.ButtonStyle.secondary, 0),
        "pending":  ("⏳ Pending", discord.ButtonStyle.secondary, 1),
        "progress": ("🔧 In progress", discord.ButtonStyle.secondary, 1),
        "resolve":  ("✅ Resolve", discord.ButtonStyle.success, 1),
        "deny":     ("🚫 Deny", discord.ButtonStyle.danger, 1),
    }

    def __init__(self, action: str, ticket_id: int):
        label, style, row = self.STYLE[action]
        super().__init__(discord.ui.Button(label=label, style=style, row=row,
                                           custom_id=f"sdm:{action}:{ticket_id}"))
        self.action, self.ticket_id = action, ticket_id

    @classmethod
    async def from_custom_id(cls, interaction, item, match):
        return cls(match["action"], int(match["tid"]))

    async def callback(self, interaction: discord.Interaction):
        a, tid = self.action, self.ticket_id
        if a in ("reply", "note", "resolve", "deny"):
            await interaction.response.send_modal(StaffTextModal(tid, a))
            return
        await interaction.response.defer(thinking=True)
        if a in STATUS_BUTTONS:
            await interaction.followup.send(await _staff_status(interaction.user, tid, STATUS_BUTTONS[a]))
        elif a == "view":
            await interaction.followup.send(**await _staff_ticket_card(interaction.user, tid))


def staff_view(ticket_id: int, web_url: str) -> discord.ui.View:
    v = discord.ui.View(timeout=None)
    for action in ("reply", "note", "view", "pending", "progress", "resolve", "deny"):
        v.add_item(StaffAction(action, ticket_id))
    v.add_item(discord.ui.Button(label="🔗 Open on web", url=web_url, row=2))
    return v


def _staff_footer(e: discord.Embed, ticket_id) -> discord.Embed:
    e.set_footer(text=f"{STAFF_FOOTER} · Ticket #{ticket_id} · Reply to this message to answer the customer")
    return e


async def _staff_ticket_card(user: discord.abc.User, ticket_id: int) -> dict:
    status, res = await post_web("/bridge/discord/staff/ticket",
                                 {"discord_id": str(user.id), "ticket_id": ticket_id})
    if status == 403:
        return {"content": "⛔ Only linked staff accounts can do that."}
    if status != 200 or not res:
        return {"content": f"❌ Couldn't load ticket #{ticket_id}."}
    t = res["ticket"]
    meta = STATUS_META.get(t["status"], STATUS_META["seen"])
    e = discord.Embed(title=f"🎫 Ticket #{t['id']} · {t['subject']}"[:256], url=res["web_url"],
                      color=meta["color"],
                      description=(f"{meta['emoji']} **{meta['label']}** · priority **{t['priority']}** · "
                                   f"{t['category']} · owner `{t['owner']}` · replies via **{t['reply_via']}**"))
    for m in res.get("messages", [])[-8:]:
        who = "⚙️ system" if m["source"] == "system" else f"{m['author']} ({m['author_role']})"
        if m.get("is_internal"):
            who = "📝 " + who + " · internal"
        text = (m["body"] or "(attachment)")
        if m.get("attachments"):
            text += "\n" + "\n".join(f"📎 {a['name']}" for a in m["attachments"])
        e.add_field(name=who[:256], value=text[:1000], inline=False)
    _staff_footer(e, t["id"])
    return {"embed": e, "view": staff_view(t["id"], res["web_url"])}


class StaffTicketSelect(discord.ui.Select):
    def __init__(self, tickets):
        options = []
        for t in tickets[:25]:
            meta = STATUS_META.get(t["status"], STATUS_META["seen"])
            options.append(discord.SelectOption(
                label=f"#{t['id']} · {t['subject']}"[:100], value=str(t["id"]), emoji=meta["emoji"],
                description=f"{meta['label']} · {t['priority']} · {t['owner']}"[:100]))
        super().__init__(placeholder="Pick a ticket to open…", options=options)

    async def callback(self, interaction: discord.Interaction):
        await interaction.response.defer(thinking=True)
        await interaction.followup.send(**await _staff_ticket_card(interaction.user, int(self.values[0])))


async def _staff_menu(message: discord.Message) -> bool:
    """DM 'menu' → list of open tickets. Returns False if the user isn't staff."""
    status, res = await post_web("/bridge/discord/staff/tickets", {"discord_id": str(message.author.id)})
    if status == 403:
        return False
    if status != 200 or not res:
        await message.channel.send("⚠️ I couldn't reach the ticket system — try again in a minute.")
        return True
    tickets = res.get("tickets") or []
    if not tickets:
        await message.channel.send(embed=brand_embed(title="📭 No open tickets", description="All caught up!"))
        return True
    v = discord.ui.View(timeout=900)
    v.add_item(StaffTicketSelect(tickets))
    e = brand_embed(title=f"🛠 Open tickets ({len(tickets)})",
                    description="Pick one below to see the conversation and reply, "
                                "change status, or add an internal note.")
    await message.channel.send(embed=e, view=v)
    return True


@bot.event
async def on_message(message: discord.Message):
    if message.author.bot: return
    if message.guild is None:
        await _handle_dm(message)
        return
    if not is_ticket_channel(message.channel): return
    content = (message.content or "").strip()
    if not content and not message.attachments: return

    body = content
    if message.attachments:
        urls = "\n".join(a.url for a in message.attachments)
        body = (body + "\n\n" if body else "") + f"📎 Attachments:\n{urls}"

    await post_web("/bridge/discord/message", {
        "channel_id": str(message.channel.id),
        "discord_message_id": str(message.id),
        "author": str(message.author),
        "discord_id": str(message.author.id),
        "body": body,
    })


@bot.event
async def on_ready():
    log.info("Bot online as %s (id=%s)", bot.user, bot.user.id)
    await bot.change_presence(activity=discord.Activity(
        type=discord.ActivityType.watching,
        name=f"tickets • {BRAND_NAME}",
    ))


@bot.event
async def setup_hook():
    bot.add_view(TicketPanelView())
    # Register a default control view so persistent buttons on old tickets still work
    bot.add_view(TicketControlView())
    bot.add_dynamic_items(StaffAction)   # staff-inbox DM buttons survive restarts

    try:
        if GUILD_ID:
            g = discord.Object(id=GUILD_ID)
            bot.tree.copy_global_to(guild=g)
            await bot.tree.sync(guild=g)
            log.info("Slash commands synced to guild %s", GUILD_ID)
        else:
            await bot.tree.sync()
            log.info("Slash commands synced globally")
    except Exception as e:
        log.warning("Slash sync failed: %s", e)

    asyncio.create_task(_run_http_server())


# ═══════════════════════════════════════════════════════════════════════════
#  HTTP server: Web → Bot
# ═══════════════════════════════════════════════════════════════════════════
def _bridge_auth_ok(request: web.Request) -> bool:
    return request.headers.get("X-Bridge-Key", "") == BRIDGE_KEY


async def http_health(_):
    return web.json_response({"ok": True, "service": f"{BRAND_NAME} discord bot"})


async def http_ticket_create(request: web.Request):
    if not _bridge_auth_ok(request):
        return web.json_response({"error": "unauthorized"}, status=401)
    data = await request.json()

    guild = bot.get_guild(GUILD_ID)
    if not guild:
        return web.json_response({"error": "guild not found"}, status=500)

    ticket_id        = data.get("ticket_id")
    subject          = data.get("subject", "ticket")
    owner            = data.get("owner", "user")
    owner_discord_id = data.get("owner_discord_id")
    category_name    = data.get("category", "General")
    company_name     = data.get("company", BRAND_NAME)
    priority         = (data.get("priority") or "normal").lower()
    initial_msg      = data.get("initial_message", "")
    status_in        = data.get("status", "seen")

    specialist_role = None
    for s in SERVICES.values():
        if s["category"] == category_name:
            specialist_role = find_role(guild, s["specialist_role"])
            break

    overwrites = {guild.default_role: discord.PermissionOverwrite(view_channel=False)}
    if guild.me:
        overwrites[guild.me] = discord.PermissionOverwrite(
            view_channel=True, send_messages=True,
            read_message_history=True, manage_channels=True, manage_messages=True)

    for r in staff_roles(guild):
        overwrites[r] = discord.PermissionOverwrite(
            view_channel=True, send_messages=True,
            read_message_history=True, manage_messages=True)

    if specialist_role:
        overwrites[specialist_role] = discord.PermissionOverwrite(
            view_channel=True, send_messages=True, read_message_history=True)

    if STAFF_ROLE_ID:
        role = guild.get_role(STAFF_ROLE_ID)
        if role:
            overwrites[role] = discord.PermissionOverwrite(
                view_channel=True, send_messages=True, read_message_history=True)

    owner_member = None
    if owner_discord_id:
        try:
            owner_member = guild.get_member(int(owner_discord_id))
            if owner_member:
                overwrites[owner_member] = discord.PermissionOverwrite(
                    view_channel=True, send_messages=True,
                    read_message_history=True, attach_files=True)
        except (TypeError, ValueError):
            pass

    parent = None
    if TICKET_CATEGORY_ID:
        parent = guild.get_channel(TICKET_CATEGORY_ID)
    if parent is None:
        parent = find_category(guild, "🎫 ─ ACTIVE TICKETS ─")

    safe_subject = re.sub(r"[^a-z0-9]+", "-", subject.lower())[:40].strip("-") or "ticket"
    chan_name = (f"ticket-{ticket_id:04d}-{safe_subject}"
                 if isinstance(ticket_id, int) else f"ticket-{ticket_id}")

    try:
        channel = await guild.create_text_channel(
            name=chan_name, category=parent, overwrites=overwrites,
            topic=(f"#{ticket_id} · {company_name} · {category_name} · "
                   f"priority: {priority} · owner: {owner}"),
        )
    except discord.Forbidden:
        return web.json_response({"error": "bot lacks Manage Channels"}, status=500)
    except discord.HTTPException as e:
        log.exception("Channel create failed")
        return web.json_response({"error": str(e)}, status=500)

    embed = build_ticket_embed(
        ticket_id=ticket_id, subject=subject, status=status_in,
        priority=priority, owner=owner, owner_member=owner_member,
        company_name=company_name, category_name=category_name,
        initial_msg=initial_msg,
    )

    mentions = []
    if owner_member:    mentions.append(owner_member.mention)
    if specialist_role: mentions.append(specialist_role.mention)
    elif STAFF_ROLE_ID:
        r = guild.get_role(STAFF_ROLE_ID)
        if r: mentions.append(r.mention)

    try:
        await channel.send(
            content=" ".join(mentions) if mentions else None,
            embed=embed,
            view=TicketControlView(status_in),
            allowed_mentions=discord.AllowedMentions(users=True, roles=True),
        )
    except discord.HTTPException:
        log.exception("Initial embed send failed")

    return web.json_response({"channel_id": str(channel.id), "channel_name": channel.name})


async def http_ticket_message(request: web.Request):
    if not _bridge_auth_ok(request):
        return web.json_response({"error": "unauthorized"}, status=401)
    data = await request.json()
    channel = bot.get_channel(int(data["channel_id"]))
    if not channel:
        return web.json_response({"error": "channel not found"}, status=404)

    author = data.get("author", "web")
    role   = (data.get("author_role") or "user").lower()
    body   = data.get("body", "")

    badge = ROLE_BADGES.get(role, f"💬 {role.title()}")
    role_color = {"admin": 0x2196F3, "staff": 0xA855F7,
                  "user":  0x94A3B8, "api":   0x22C55E}.get(role, BRAND_BLUE)

    e = discord.Embed(description=body[:4000], color=role_color,
                      timestamp=datetime.now(timezone.utc))
    e.set_author(name=f"{badge} · {author} (via web)")
    brand_footer(e)

    try:
        await channel.send(embed=e)
    except discord.HTTPException as ex:
        return web.json_response({"error": str(ex)}, status=500)
    return web.json_response({"ok": True})


async def http_ticket_status(request: web.Request):
    """Called when the WEB updates a status — refresh the embed + maybe delete."""
    if not _bridge_auth_ok(request):
        return web.json_response({"error": "unauthorized"}, status=401)
    data = await request.json()
    channel = bot.get_channel(int(data["channel_id"]))
    if not channel:
        return web.json_response({"error": "channel not found"}, status=404)

    new_status = data.get("status", "seen")
    actor      = data.get("actor", "system")
    note       = data.get("resolution_note")
    meta       = STATUS_META.get(new_status, STATUS_META["seen"])

    # Announcement
    e = discord.Embed(
        title=f"{meta['emoji']} Status changed: {meta['label']}",
        description=f"Updated by **{actor}** (via web)",
        color=meta["color"], timestamp=datetime.now(timezone.utc),
    )
    if note:
        e.add_field(name="📋 Note", value=f">>> {note[:1000]}", inline=False)
    brand_footer(e)
    try: await channel.send(embed=e)
    except discord.HTTPException as ex:
        return web.json_response({"error": str(ex)}, status=500)

    # Refresh intake embed (need to fetch fresh ticket data)
    ticket_status_resp, ticket_body = await post_web(
        "/bridge/discord/my-tickets",  # dummy — we just need to fetch one ticket
        {"discord_id": "0"},           # this will return empty; we need a real lookup
    )
    # ↑ Simple fallback: just rebuild the embed locally with what we know
    fake_ticket = {
        "id": data.get("ticket_id", "?"),
        "subject": data.get("subject", ""),
        "status": new_status,
        "priority": data.get("priority", "normal"),
        "owner": data.get("owner", "user"),
        "owner_discord_id": data.get("owner_discord_id"),
        "company": data.get("company", BRAND_NAME),
        "category": data.get("category", "General"),
        "resolution_note": note,
    }
    await _refresh_pinned_intake_embed(channel, fake_ticket)

    # Auto-delete on terminal
    if meta.get("terminal"):
        asyncio.create_task(_schedule_channel_delete(channel, meta["label"]))

    return web.json_response({"ok": True})


async def _resolve_user(discord_id):
    try:
        uid = int(discord_id)
    except (TypeError, ValueError):
        return None
    user = bot.get_user(uid)
    if user is None:
        try:
            user = await bot.fetch_user(uid)
        except discord.HTTPException:
            return None
    return user


async def http_dm_send(request: web.Request):
    """Web → customer DM (ticket opened / new reply / status change)."""
    if not _bridge_auth_ok(request):
        return web.json_response({"error": "unauthorized"}, status=401)
    data = await request.json()
    user = await _resolve_user(data.get("discord_id"))
    if not user:
        return web.json_response({"ok": False, "error": "user_not_found"})

    tid = data.get("ticket_id")
    subject = (data.get("subject") or "")[:180]
    kind = data.get("kind", "message")
    body = data.get("body") or ""
    status = data.get("status") or "seen"
    web_url = data.get("web_url") or f"{WEB_URL}/tickets/{tid}"
    title = f"🎫 Ticket #{tid} · {subject}"[:256]

    if kind == "opened":
        # Same intake card the staff see in the ticket channel.
        e = build_ticket_embed(
            ticket_id=tid, subject=subject, status=status,
            priority=(data.get("priority") or "normal").lower(), owner=data.get("owner") or "you",
            owner_member=user, company_name=data.get("company") or BRAND_NAME,
            category_name=data.get("category") or "General", initial_msg=body,
            resolution_note=data.get("resolution_note"))
        e.set_field_at(len(e.fields) - 1, name="\u200b", inline=False, value=(
            f"🔗 [Open on the website]({web_url})\n"
            "💬 **Reply to this message** to talk to the team — everything from the "
            "ticket channel and the website is copied here, both ways."))
    elif kind == "status":
        meta = STATUS_META.get(status, STATUS_META["seen"])
        e = discord.Embed(title=title, url=web_url, color=meta["color"],
                          timestamp=datetime.now(timezone.utc),
                          description=f"{meta['emoji']} Status changed to **{meta['label']}** "
                                      f"by {data.get('author') or 'staff'}")
        e.add_field(name="Progress", value=f"{render_progress_bar(status)}\n\n{render_status_track(status)}",
                    inline=False)
        if body:
            e.add_field(name="📋 Note", value=f">>> {body[:1000]}", inline=False)
    else:
        via = "website" if data.get("via") == "web" else "ticket channel"
        if data.get("from_owner"):
            label, color = f"👤 You · via {via}", 0x94A3B8
        else:
            role = (data.get("author_role") or "staff").lower()
            label = f"{ROLE_BADGES.get(role, '🎫 Staff')} · {data.get('author') or 'OpsLabs'} · via {via}"
            color = {"admin": 0x2196F3, "founder": 0x2196F3, "staff": 0xA855F7}.get(role, BRAND_BLUE)
        e = discord.Embed(title=title, url=web_url, description=body[:4000] or "(attachment)",
                          color=color, timestamp=datetime.now(timezone.utc))
        e.set_author(name=label)
    e.set_footer(text=f"Reply to this message to respond · Ticket #{tid}")
    try:
        await user.send(embed=e)
    except discord.Forbidden:
        return web.json_response({"ok": False, "error": "dm_closed"})
    except discord.HTTPException as ex:
        return web.json_response({"ok": False, "error": str(ex)})
    return web.json_response({"ok": True})


async def http_dm_test(request: web.Request):
    """Can the bot DM this user? Sends a short confirmation DM."""
    if not _bridge_auth_ok(request):
        return web.json_response({"error": "unauthorized"}, status=401)
    data = await request.json()
    user = await _resolve_user(data.get("discord_id"))
    if not user:
        return web.json_response({"in_guild": False, "dm_ok": False, "error": "Discord account not found."})
    guild = bot.get_guild(GUILD_ID)
    member = guild.get_member(user.id) if guild else None
    if guild and member is None:
        try:
            member = await guild.fetch_member(user.id)
        except discord.HTTPException:
            member = None
    if guild and member is None:
        return web.json_response({"in_guild": False, "dm_ok": False,
                                  "error": "You're not in the OpsLabs Discord server yet."})
    try:
        await user.send(embed=brand_embed(
            title="✅ DMs are working",
            description="OpsLabs can reach you here. Replies to your tickets will show up in this chat."))
    except discord.Forbidden:
        return web.json_response({"in_guild": True, "dm_ok": False,
                                  "error": "Your privacy settings block DMs from the OpsLabs server (see step 2)."})
    except discord.HTTPException as ex:
        return web.json_response({"in_guild": True, "dm_ok": False, "error": str(ex)})
    return web.json_response({"in_guild": True, "dm_ok": True})


async def http_staff_notify(request: web.Request):
    """Web → staff inbox DMs (new ticket / customer reply) with action buttons."""
    if not _bridge_auth_ok(request):
        return web.json_response({"error": "unauthorized"}, status=401)
    data = await request.json()
    tid = data.get("ticket_id")
    web_url = data.get("web_url") or f"{WEB_URL}/tickets/{tid}"
    body = data.get("body") or ""
    if data.get("kind") == "new":
        e = build_ticket_embed(
            ticket_id=tid, subject=data.get("subject") or "", status=data.get("status") or "seen",
            priority=(data.get("priority") or "normal").lower(), owner=data.get("owner") or "",
            owner_member=None, company_name=data.get("company") or BRAND_NAME,
            category_name=data.get("category") or "General", initial_msg=body)
        e.title = f"🆕 New ticket #{tid}"
        e.set_field_at(len(e.fields) - 1, name="\u200b", inline=False, value=(
            f"Opened via **{data.get('via') or 'web'}** · customer replies via **{data.get('reply_via') or 'web'}**\n"
            "Use the buttons, or **reply to this message** to answer the customer."))
    else:
        e = discord.Embed(title=f"💬 Ticket #{tid} · {data.get('subject') or ''}"[:256], url=web_url,
                          description=body[:4000] or "(attachment)", color=0x94A3B8,
                          timestamp=datetime.now(timezone.utc))
        e.set_author(name=f"👤 {data.get('author') or 'Customer'} · via {data.get('via') or 'web'}")
    _staff_footer(e, tid)

    results = {}
    for did in data.get("discord_ids") or []:
        user = await _resolve_user(did)
        if not user:
            results[did] = "user_not_found"
            continue
        try:
            await user.send(embed=e, view=staff_view(int(tid), web_url))
            results[did] = "ok"
        except discord.Forbidden:
            results[did] = "dm_closed"
        except discord.HTTPException as ex:
            results[did] = str(ex)
    return web.json_response({"ok": True, "results": results})


async def _run_http_server():
    app = web.Application()
    app.router.add_post("/discord/staff/notify",   http_staff_notify)
    app.router.add_post("/discord/dm/send",        http_dm_send)
    app.router.add_post("/discord/dm/test",        http_dm_test)
    app.router.add_post("/discord/ticket/create",  http_ticket_create)
    app.router.add_post("/discord/ticket/message", http_ticket_message)
    app.router.add_post("/discord/ticket/status",  http_ticket_status)
    app.router.add_get ("/health",                 http_health)

    runner = web.AppRunner(app)
    await runner.setup()
    host = os.environ.get("BOT_LISTEN_HOST", "127.0.0.1")   # web app is on this VM
    site = web.TCPSite(runner, host, LISTEN_PORT)
    await site.start()
    log.info("Bot HTTP server listening on %s:%d", host, LISTEN_PORT)


# ═══════════════════════════════════════════════════════════════════════════
#  Entrypoint
# ═══════════════════════════════════════════════════════════════════════════
def main():
    if not TOKEN:
        raise SystemExit("DISCORD_TOKEN is required.")
    bot.run(TOKEN)


if __name__ == "__main__":
    main()
