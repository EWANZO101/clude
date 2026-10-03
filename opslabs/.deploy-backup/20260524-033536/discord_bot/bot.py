"""
╔══════════════════════════════════════════════════════════════════════════╗
║  OpsLab Systems — Discord Bot                                            ║
║  ─────────────────────────────                                           ║
║  Talks to the Flask site over HTTP in BOTH directions:                   ║
║                                                                          ║
║    Web → Bot                                                             ║
║      POST /discord/ticket/create   → bot makes a channel                 ║
║      POST /discord/ticket/message  → bot relays a message                ║
║      POST /discord/ticket/status   → bot announces status change         ║
║                                                                          ║
║    Bot → Web   (live sync)                                               ║
║      POST /bridge/discord/message       → mirror message into ticket     ║
║      POST /bridge/discord/status        → update ticket status           ║
║      POST /bridge/discord/link          → link Discord → web user        ║
║      POST /bridge/discord/resolve-user  → ticket-panel auto-create       ║
║      POST /bridge/discord/my-tickets    → user's tickets for /my-tickets ║
║                                                                          ║
║    Bot → Web API   (ticket panel button creates a real ticket)           ║
║      POST /api/v1/tickets         → using a write-scope API key          ║
║                                                                          ║
║  Slash commands:                                                         ║
║      /setup-server        admin   builds roles + categories + channels   ║
║      /post-ticket-panel   admin   publishes the public ticket panel      ║
║      /post-services       admin   publishes the services embed           ║
║      /link-account        anyone  link Discord → web (transfers tickets) ║
║      /my-tickets          anyone  list your tickets in Discord           ║
║      /ping                anyone  latency check                          ║
║      /close, /reopen      in ticket channels                             ║
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

BRIDGE_KEY         = os.environ.get("BRIDGE_KEY", "fahnhfawhfaihwfaihaihfhwahfi")
WEB_URL            = os.environ.get("WEB_URL", "https://web.opslabsystems.cloud").rstrip("/")
WEB_INTERNAL_URL   = os.environ.get("WEB_INTERNAL_URL", WEB_URL).rstrip("/")
LISTEN_PORT        = _i("BOT_LISTEN_PORT", 5090)

API_KEY            = os.environ.get("OPSLAB_API_KEY", "")

BRAND_NAME         = os.environ.get("BRAND_NAME", "OpsLab Systems")
BRAND_TAGLINE      = os.environ.get("BRAND_TAGLINE", "Build. Support. Scale. Together.")
BRAND_LOGO_URL     = os.environ.get("BRAND_LOGO_URL", "").strip()

BRAND_BLUE         = _i("BRAND_BLUE",     0x2196F3)
COLOR_OPEN         = _i("COLOR_OPEN",     0x22C55E)
COLOR_PENDING      = _i("COLOR_PENDING",  0xF59E0B)
COLOR_CLOSED       = _i("COLOR_CLOSED",   0x94A3B8)
COLOR_DANGER       = _i("COLOR_DANGER",   0xEF4444)

PRIORITY_STYLES = {
    "low":    ("⚪", 0x94A3B8, "Low"),
    "normal": ("🔵", 0x2196F3, "Normal"),
    "high":   ("🟠", 0xF59E0B, "High"),
    "urgent": ("🔴", 0xEF4444, "Urgent"),
}
STATUS_STYLES = {
    "open":    ("🔓", COLOR_OPEN,    "Open"),
    "pending": ("⏳", COLOR_PENDING, "Pending"),
    "closed":  ("🔒", COLOR_CLOSED,  "Closed"),
}
ROLE_BADGES = {
    "admin": "🛡️ Admin", "staff": "🎫 Staff",
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
    {
        "category": "📌 ─ INFORMATION ─",
        "private": False,
        "channels": [
            {"name": "👋・welcome",          "type": "text",         "topic": f"Welcome to {BRAND_NAME}. Start here."},
            {"name": "📜・rules",            "type": "text",         "topic": "Server rules and code of conduct."},
            {"name": "🗺️・getting-started",  "type": "text",         "topic": "How the platform works + how to open a ticket."},
            {"name": "📣・announcements",    "type": "announcement", "topic": "Official announcements."},
            {"name": "🚀・releases",         "type": "announcement", "topic": "New services, features, and product releases."},
            {"name": "📡・site-updates",     "type": "text",         "topic": f"Updates from {WEB_URL}"},
        ],
    },
    {
        "category": "🎫 ─ CLIENT PORTAL ─",
        "private": False,
        "channels": [
            {"name": "🎟️・open-a-ticket",    "type": "text", "topic": "Pick a service below to open a ticket."},
            {"name": "💡・our-services",     "type": "text", "topic": "Full overview of every service."},
            {"name": "💰・pricing-info",     "type": "text", "topic": "Pricing tiers and quote process."},
            {"name": "📚・knowledge-base",   "type": "text", "topic": "FAQs, guides, how-tos."},
            {"name": "⭐・testimonials",      "type": "text", "topic": "Reviews and success stories."},
        ],
    },
    {
        "category": "🎫 ─ ACTIVE TICKETS ─",
        "private": True,
        "channels": [],
    },
    {
        "category": "🌐 ─ WEB DEVELOPMENT ─",
        "private": False,
        "channels": [
            {"name": "🌐・web-lounge",       "type": "text", "topic": "Web dev — frameworks, design, best practices."},
            {"name": "🎨・design-showcase",  "type": "text", "topic": "Mockups and finished builds."},
            {"name": "🧠・web-resources",    "type": "text", "topic": "Libraries, articles, and tools."},
            {"name": "🔬・web-lab",          "type": "text", "topic": "Experiments and prototypes."},
        ],
    },
    {
        "category": "🎮 ─ FIVEM DEVELOPMENT ─",
        "private": False,
        "channels": [
            {"name": "🎮・fivem-lounge",      "type": "text", "topic": "FiveM scripting and server dev."},
            {"name": "🗺️・maps-and-mlos",     "type": "text", "topic": "Custom maps and MLO discussion."},
            {"name": "📜・scripts-resources", "type": "text", "topic": "Scripts, resources, framework integrations."},
            {"name": "🧪・fivem-showcase",    "type": "text", "topic": "Show off your FiveM work."},
        ],
    },
    {
        "category": "☁️ ─ HOSTING & INFRASTRUCTURE ─",
        "private": False,
        "channels": [
            {"name": "☁️・hosting-lounge",   "type": "text", "topic": "VPS, dedicated, game-server hosting talk."},
            {"name": "🖥️・system-setup",     "type": "text", "topic": "OS install, server config, optimisation."},
            {"name": "🛡️・security-corner",  "type": "text", "topic": "Hardening, backups, monitoring, incident response."},
            {"name": "📈・performance",      "type": "text", "topic": "Benchmarks, tuning, load testing."},
        ],
    },
    {
        "category": "💬 ─ COMMUNITY ─",
        "private": False,
        "channels": [
            {"name": "💬・general-chat",     "type": "text", "topic": "General discussion."},
            {"name": "🤝・introductions",    "type": "text", "topic": "New here? Say hi!"},
            {"name": "💡・tech-news",        "type": "text", "topic": "Latest in tech, AI, dev tools."},
            {"name": "📸・media-share",      "type": "text", "topic": "Screenshots, gifs, memes."},
            {"name": "🤖・bot-commands",     "type": "text", "topic": "Bot commands here."},
        ],
    },
    {
        "category": "🔊 ─ VOICE CHANNELS ─",
        "private": False,
        "channels": [
            {"name": "🔊 Public Lounge",        "type": "voice"},
            {"name": "💼 Client Meeting Room",  "type": "voice"},
            {"name": "🧠 Dev Standup",          "type": "voice"},
            {"name": "🎧 Music & Chill",        "type": "voice"},
            {"name": "💤 AFK",                  "type": "voice"},
        ],
    },
    {
        "category": "🔒 ─ STAFF OPERATIONS ─",
        "private": True,
        "channels": [
            {"name": "📋・staff-lounge",     "type": "text",  "topic": "Internal staff chat."},
            {"name": "📊・staff-briefings",  "type": "text",  "topic": "Internal announcements."},
            {"name": "🗂️・ticket-archive",   "type": "text",  "topic": "Closed-ticket transcripts."},
            {"name": "📝・audit-log",        "type": "text",  "topic": "Moderation/action audit log."},
            {"name": "🧾・internal-notes",   "type": "text",  "topic": "Notes and to-dos."},
            {"name": "🔊 Staff Voice",       "type": "voice"},
            {"name": "🎯 Leadership Voice",  "type": "voice"},
        ],
    },
]


# ═══════════════════════════════════════════════════════════════════════════
#  Service catalogue — drives the ticket panel
# ═══════════════════════════════════════════════════════════════════════════
SERVICES = {
    "web": {
        "label":    "Website Development",
        "tagline":  "Custom websites and updates",
        "blurb":    "Bespoke sites, landing pages, dashboards, e-commerce, and ongoing maintenance.",
        "emoji":    "🌐",
        "style":    discord.ButtonStyle.primary,
        "specialist_role": "🌐 Web Engineering",
        "category": "Website Development",
        "questions": [
            ("Project type",       "Landing page, dashboard, e-commerce, portfolio, app…"),
            ("Tech preference",    "React, Next.js, plain HTML/CSS, Wordpress, no preference…"),
            ("Timeline",           "When do you need this delivered?"),
            ("Budget range",       "Rough budget so we can scope it."),
        ],
    },
    "fivem": {
        "label":    "FiveM Development",
        "tagline":  "Scripts, maps, resources, and more",
        "blurb":    "QBCore / ESX / standalone scripts, MLOs, custom maps, and full server builds.",
        "emoji":    "🎮",
        "style":    discord.ButtonStyle.success,
        "specialist_role": "🎮 FiveM Engineering",
        "category": "FiveM Development",
        "questions": [
            ("Framework",          "QBCore, ESX, standalone, or other?"),
            ("What do you need?",  "Script, MLO, map, full server build — describe in detail."),
            ("Existing setup",     "Any current resources we should integrate with?"),
            ("Deadline",           "When do you need this live?"),
        ],
    },
    "tech": {
        "label":    "Tech Support",
        "tagline":  "Fix issues and get the help you need",
        "blurb":    "Debugging, troubleshooting, and rapid fixes for any tech problem.",
        "emoji":    "🛠️",
        "style":    discord.ButtonStyle.secondary,
        "specialist_role": "🛎️ Support Specialist",
        "category": "Tech Support",
        "questions": [
            ("The problem",        "Describe the issue in detail."),
            ("What you've tried",  "Steps already attempted."),
            ("Error messages",     "Paste any errors, logs, screenshots."),
            ("Urgency",            "Low / Normal / High / Urgent"),
        ],
    },
    "hosting": {
        "label":    "Hosting Support",
        "tagline":  "Reliable hosting solutions",
        "blurb":    "VPS, dedicated, game-server hosting — provisioning, migration, ongoing management.",
        "emoji":    "☁️",
        "style":    discord.ButtonStyle.primary,
        "specialist_role": "☁️ Infrastructure",
        "category": "Hosting Support",
        "questions": [
            ("Hosting type",       "VPS, dedicated, shared, game server, cloud?"),
            ("Current provider",   "Where are you hosted now? (or 'new setup')"),
            ("Specs required",     "RAM / CPU / storage / location."),
            ("Monthly budget",     "Rough monthly budget."),
        ],
    },
    "setup": {
        "label":    "System Setup",
        "tagline":  "Setup and optimize your systems",
        "blurb":    "Provisioning, OS install, hardening, monitoring, and performance tuning.",
        "emoji":    "⚙️",
        "style":    discord.ButtonStyle.success,
        "specialist_role": "🖥️ Systems Engineering",
        "category": "System Setup",
        "questions": [
            ("System / OS",        "Linux distro, Windows Server, or other?"),
            ("Use case",           "Game server, web server, dev env, other?"),
            ("Access available",   "Do you have SSH / RDP credentials ready?"),
            ("Deadline",           "When does it need to be ready?"),
        ],
    },
    "other": {
        "label":    "General Enquiry",
        "tagline":  "Anything tech related",
        "blurb":    "Doesn't fit a category? Open a general ticket and we'll route you.",
        "emoji":    "✨",
        "style":    discord.ButtonStyle.secondary,
        "specialist_role": "🛎️ Support Specialist",
        "category": "Other",
        "questions": [
            ("What do you need?",  "Describe in as much detail as you can."),
            ("Urgency",            "Low / Normal / High / Urgent"),
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


def brand_embed(title: str = "", description: str = "",
                colour: int = BRAND_BLUE, url: Optional[str] = None) -> discord.Embed:
    e = discord.Embed(
        title=title or None,
        description=description or None,
        colour=colour,
        timestamp=datetime.now(timezone.utc),
        url=url,
    )
    brand_footer(e)
    if BRAND_LOGO_URL:
        e.set_thumbnail(url=BRAND_LOGO_URL)
    return e


def find_role(guild: discord.Guild, name: str) -> Optional[discord.Role]:
    return discord.utils.get(guild.roles, name=name)


def find_channel(guild: discord.Guild, name: str) -> Optional[discord.TextChannel]:
    return discord.utils.get(guild.text_channels, name=name)


def find_category(guild: discord.Guild, name: str) -> Optional[discord.CategoryChannel]:
    return discord.utils.get(guild.categories, name=name)


def staff_roles(guild: discord.Guild) -> list[discord.Role]:
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


async def post_web(path: str, payload: dict, *, headers_extra: dict | None = None) -> tuple[int, dict | None]:
    """POST JSON to the Flask site. Used for bridge + API calls."""
    url = WEB_INTERNAL_URL + path
    headers = {"X-Bridge-Key": BRIDGE_KEY}
    if headers_extra:
        headers.update(headers_extra)
    try:
        async with ClientSession(timeout=ClientTimeout(total=8)) as s:
            async with s.post(url, json=payload, headers=headers) as r:
                try:
                    body = await r.json()
                except Exception:
                    body = None
                if r.status >= 300:
                    log.warning("POST %s -> %s: %s", path, r.status, body or await r.text())
                return r.status, body
    except Exception as e:
        log.warning("POST %s failed: %s", path, e)
        return 0, None


async def api_post(path: str, payload: dict) -> tuple[int, dict | None]:
    if not API_KEY:
        log.error("OPSLAB_API_KEY is not set — ticket panel cannot create tickets.")
        return 0, None
    return await post_web(path, payload, headers_extra={"Authorization": f"Bearer {API_KEY}"})


# ═══════════════════════════════════════════════════════════════════════════
#  /setup-server  —  builds the whole server
# ═══════════════════════════════════════════════════════════════════════════
async def _ensure_role(guild: discord.Guild, spec: dict) -> tuple[discord.Role | None, str]:
    existing = find_role(guild, spec["name"])
    if existing:
        return existing, "exists"
    try:
        r = await guild.create_role(
            name=spec["name"],
            colour=discord.Colour(spec["colour"]),
            hoist=spec["hoist"],
            mentionable=spec["mentionable"],
            reason="OpsLab Systems server blueprint",
        )
        return r, "created"
    except discord.Forbidden:
        return None, "no-perms"
    except discord.HTTPException as e:
        return None, f"err:{e.text}"


async def _ensure_category(guild: discord.Guild, name: str, private: bool) -> tuple[discord.CategoryChannel | None, str]:
    existing = find_category(guild, name)

    overwrites = {}
    if private:
        overwrites[guild.default_role] = discord.PermissionOverwrite(view_channel=False)
        for r in staff_roles(guild):
            overwrites[r] = discord.PermissionOverwrite(
                view_channel=True, send_messages=True, manage_messages=True
            )
        if guild.me:
            overwrites[guild.me] = discord.PermissionOverwrite(
                view_channel=True, send_messages=True, manage_channels=True, manage_messages=True
            )

    if existing:
        if private:
            try:
                await existing.edit(overwrites=overwrites)
            except discord.Forbidden:
                pass
        return existing, "exists"

    try:
        c = await guild.create_category(name=name, overwrites=overwrites, reason="OpsLab Systems blueprint")
        return c, "created"
    except discord.Forbidden:
        return None, "no-perms"


async def _ensure_channel(guild: discord.Guild, cat: discord.CategoryChannel, spec: dict) -> tuple[discord.abc.GuildChannel | None, str]:
    name = spec["name"]
    existing = discord.utils.get(cat.channels, name=name)
    if existing:
        return existing, "exists"
    ctype = spec.get("type", "text")
    topic = spec.get("topic")
    try:
        if ctype == "voice":
            return await guild.create_voice_channel(name=name, category=cat), "created"
        if ctype == "announcement":
            try:
                return await guild.create_text_channel(name=name, category=cat, topic=topic, news=True), "created"
            except (discord.HTTPException, TypeError):
                return await guild.create_text_channel(name=name, category=cat, topic=topic), "created"
        return await guild.create_text_channel(name=name, category=cat, topic=topic), "created"
    except discord.Forbidden:
        return None, "no-perms"
    except discord.HTTPException as e:
        return None, f"err:{e.text}"


@bot.tree.command(name="setup-server",
                  description="Build the full OpsLab Systems server. Admin only.")
@app_commands.default_permissions(administrator=True)
async def setup_server(interaction: discord.Interaction):
    await interaction.response.defer(ephemeral=True, thinking=True)
    guild = interaction.guild
    if guild is None:
        return await interaction.followup.send("Run this inside a server.", ephemeral=True)

    lines: list[str] = []

    lines.append("┏━━ ROLES ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    for spec in ROLES:
        _, status = await _ensure_role(guild, spec)
        mark = "✅" if status in ("exists", "created") else "❌"
        lines.append(f"┃ {mark} {spec['name']:<28} {status}")
    lines.append("┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

    for section in SERVER_STRUCTURE:
        lines.append(f"\n┏━━ {section['category']}")
        cat, cstatus = await _ensure_category(guild, section["category"], section["private"])
        if not cat:
            lines.append(f"┃ ❌ category — {cstatus}")
            continue
        lines.append(f"┃ 📁 category {cstatus}")
        for ch_spec in section["channels"]:
            _, chstatus = await _ensure_channel(guild, cat, ch_spec)
            mark = "✅" if chstatus in ("exists", "created") else "❌"
            lines.append(f"┃   {mark} {ch_spec['name']:<28} {chstatus}")
        lines.append("┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

    await _seed_content(guild)

    ticket_chan = find_channel(guild, "🎟️・open-a-ticket")
    services_chan = find_channel(guild, "💡・our-services")
    summary = brand_embed(
        title="✅ Server setup complete",
        description=(
            f"**Welcome to {BRAND_NAME}.**\n\n"
            f"Next steps:\n"
            f"• Run `/post-ticket-panel` "
            f"{'in ' + ticket_chan.mention if ticket_chan else ''}\n"
            f"• Run `/post-services` "
            f"{'in ' + services_chan.mention if services_chan else ''}\n"
            f"• Drag the bot's role above all custom roles in **Settings → Roles**"
        ),
        colour=COLOR_OPEN,
        url=WEB_URL,
    )
    await interaction.followup.send(embed=summary, ephemeral=True)

    chunks, cur = [], ""
    for ln in lines:
        if len(cur) + len(ln) + 1 > 1800:
            chunks.append(cur); cur = ""
        cur += ln + "\n"
    if cur:
        chunks.append(cur)
    for ch in chunks:
        await interaction.followup.send(f"```\n{ch}\n```", ephemeral=True)


async def _seed_content(guild: discord.Guild) -> None:
    async def empty(ch: discord.TextChannel) -> bool:
        async for m in ch.history(limit=10):
            if m.author == bot.user:
                return False
        return True

    welcome = find_channel(guild, "👋・welcome")
    rules   = find_channel(guild, "📜・rules")
    start   = find_channel(guild, "🗺️・getting-started")
    ticket  = find_channel(guild, "🎟️・open-a-ticket")
    svcs    = find_channel(guild, "💡・our-services")
    price   = find_channel(guild, "💰・pricing-info")
    kb      = find_channel(guild, "📚・knowledge-base")

    if welcome and await empty(welcome):
        e = brand_embed(
            title=f"Welcome to {BRAND_NAME}",
            description=(
                f"**{BRAND_TAGLINE}**\n\n"
                f"From custom websites to FiveM scripts, hosting to system setup — "
                f"under one roof, one team, one ticket system.\n\n"
                f"🌐 [Visit our site]({WEB_URL})"
            ),
            url=WEB_URL,
        )
        if rules:  e.add_field(name="📜 Rules",            value=rules.mention,  inline=True)
        if start:  e.add_field(name="🗺️ Getting Started",  value=start.mention,  inline=True)
        if ticket: e.add_field(name="🎟️ Open a Ticket",    value=ticket.mention, inline=True)
        if svcs:   e.add_field(name="💡 Our Services",     value=svcs.mention,   inline=True)
        try: await welcome.send(embed=e)
        except discord.Forbidden: pass

    if rules and await empty(rules):
        e = brand_embed(
            title="📜 Server Rules & Code of Conduct",
            description=f"To keep **{BRAND_NAME}** a great place for everyone:",
        )
        for n, v in [
            ("1️⃣ Respect everyone",
             "No harassment, hate speech, slurs, or personal attacks."),
            ("2️⃣ Stay professional",
             "Constructive discussion. Disagree politely."),
            ("3️⃣ No spam or self-promo",
             "Don't advertise products/services without explicit staff approval."),
            ("4️⃣ Use the right channel",
             "Post in the channel that fits. Open a ticket for support — don't DM staff."),
            ("5️⃣ Safe-for-work only",
             "No NSFW, gore, or graphic content."),
            ("6️⃣ Confidentiality",
             "Don't share private ticket contents or client work outside the server."),
            ("7️⃣ Discord ToS applies",
             "Discord's Terms of Service and Community Guidelines apply at all times."),
            ("8️⃣ Staff decisions are final",
             "Disagree? DM after — not in public."),
        ]:
            e.add_field(name=n, value=v, inline=False)
        try: await rules.send(embed=e)
        except discord.Forbidden: pass

    if svcs and await empty(svcs):
        try: await svcs.send(embed=_services_embed())
        except discord.Forbidden: pass

    if kb and await empty(kb):
        e = brand_embed(title="📚 Knowledge Base — FAQ")
        e.add_field(name="❓ How do I get support?",
                    value="Head to the ticket channel and pick a service.",
                    inline=False)
        e.add_field(name="⏱️ Response time?",
                    value="Most tickets get a first response within a few hours during business hours.",
                    inline=False)
        e.add_field(name="💰 Do you do free work?",
                    value="Quotes are free. Custom work is paid — we scope it together in your ticket.",
                    inline=False)
        e.add_field(name="🔗 Link your account",
                    value=(f"Run `/link-account <your-website-username>` in any channel to link "
                           f"your Discord to your website account. Tickets you opened on Discord "
                           f"will be transferred over."),
                    inline=False)
        e.add_field(name="🌐 Portfolio?",
                    value=f"Visit [{WEB_URL}]({WEB_URL}).",
                    inline=False)
        try: await kb.send(embed=e)
        except discord.Forbidden: pass

    if price and await empty(price):
        e = brand_embed(
            title="💰 Pricing & Process",
            description="Every project is different — we quote per-project, not from a fixed price list.",
        )
        for n, v in [
            ("1️⃣ Open a ticket", "Pick the service and answer a few short questions."),
            ("2️⃣ Scope together", "A specialist clarifies requirements and timeline."),
            ("3️⃣ Get a quote", "Clear, itemised — no surprises."),
            ("4️⃣ Approve & build", "Milestones for larger projects."),
            ("5️⃣ Delivery & support", "Final delivery plus ongoing support options."),
        ]:
            e.add_field(name=n, value=v, inline=False)
        try: await price.send(embed=e)
        except discord.Forbidden: pass


def _services_embed() -> discord.Embed:
    e = brand_embed(
        title="💡 Our Services",
        description=(
            f"**{BRAND_TAGLINE}**\n\n"
            f"From custom websites to FiveM scripts, hosting to system setup — "
            f"under one roof, one team, one ticket system.\n\n"
            f"🔗 [View on the site]({WEB_URL}/#services)"
        ),
        url=f"{WEB_URL}/#services",
    )
    for s in SERVICES.values():
        e.add_field(
            name=f"{s['emoji']} {s['label']}",
            value=f"*{s['tagline']}*\n{s['blurb']}",
            inline=False,
        )
    e.add_field(
        name="\u200b",
        value="➡️ Ready to start? Open a ticket and we'll take it from there.",
        inline=False,
    )
    return e


# ═══════════════════════════════════════════════════════════════════════════
#  Ticket panel (UI) — buttons & dropdown create real tickets via the API
# ═══════════════════════════════════════════════════════════════════════════
class TicketDetailsModal(discord.ui.Modal):
    def __init__(self, service_key: str):
        self.service_key = service_key
        svc = SERVICES[service_key]
        super().__init__(title=f"{svc['emoji']} {svc['label']}"[:45])

        self.subject_input = discord.ui.TextInput(
            label="Subject",
            placeholder="One-line summary of what you need",
            style=discord.TextStyle.short,
            required=True, max_length=180,
        )
        self.add_item(self.subject_input)

        # Track labels separately to avoid the .label deprecation warning
        # when we read them back in on_submit.
        self.q_inputs: list[discord.ui.TextInput] = []
        self.q_labels: list[str] = []
        for q_label, q_placeholder in svc["questions"][:4]:
            ti = discord.ui.TextInput(
                label=q_label[:45],
                placeholder=q_placeholder[:100],
                style=discord.TextStyle.paragraph,
                required=True, max_length=1000,
            )
            self.q_inputs.append(ti)
            self.q_labels.append(q_label[:45])
            self.add_item(ti)

    async def on_submit(self, interaction: discord.Interaction):
        await interaction.response.defer(ephemeral=True, thinking=True)
        svc = SERVICES[self.service_key]
        user = interaction.user

        body_lines = []
        for label, q_in in zip(self.q_labels, self.q_inputs):
            body_lines.append(f"**{label}**\n{q_in.value}")
        body = "\n\n".join(body_lines)

        # Resolve / auto-create the Flask user
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

        # Create the ticket via the public API
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

        # Pretty confirmation embed
        embed = brand_embed(
            title=f"✅ Ticket #{ticket_id} created",
            description=f"**{self.subject_input.value[:180]}**",
            colour=COLOR_OPEN,
            url=link,
        )
        if chan_id:
            chan = interaction.guild.get_channel(int(chan_id)) if interaction.guild else None
            if chan:
                embed.add_field(name="💬 Discord channel", value=chan.mention, inline=True)
        embed.add_field(name="🌐 Web", value=f"[Open on the dashboard]({link})", inline=True)

        if is_placeholder:
            embed.add_field(
                name="💡 Tip — link your account",
                value=(
                    f"Run `/link-account <your-website-username>` to connect this "
                    f"ticket to your real website account. Don't have one yet? "
                    f"Sign up at {WEB_URL} — your existing tickets will transfer over."
                ),
                inline=False,
            )

        await interaction.followup.send(embed=embed, ephemeral=True)


class ServiceSelect(discord.ui.Select):
    def __init__(self):
        opts = [
            discord.SelectOption(
                label=s["label"],
                description=s["tagline"][:100],
                emoji=s["emoji"],
                value=k,
            )
            for k, s in SERVICES.items()
        ]
        super().__init__(
            placeholder="📋 Choose a service to open a ticket…",
            options=opts,
            min_values=1, max_values=1,
            custom_id="opslab:service_select",
        )

    async def callback(self, interaction: discord.Interaction):
        await interaction.response.send_modal(TicketDetailsModal(self.values[0]))


class QuickServiceButton(discord.ui.Button):
    def __init__(self, key: str, row: int):
        s = SERVICES[key]
        super().__init__(
            label=s["label"],
            emoji=s["emoji"],
            style=s["style"],
            row=row,
            custom_id=f"opslab:btn:{key}",
        )
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
            f"**Choose a service from the dropdown** or click a button below."
        ),
        url=f"{WEB_URL}/#services",
    )
    for s in SERVICES.values():
        e.add_field(name=f"{s['emoji']} {s['label']}", value=s["tagline"], inline=True)
    e.add_field(name="\u200b",
                value=(
                    "🔒 **Private** — only you & staff see your ticket\n"
                    "⚡ **Live sync** — replies appear on web & Discord within seconds\n"
                    "🎯 **Specialist routing** — your ticket goes to the right expert\n"
                    "💡 No website account needed — link later with `/link-account`\n"
                    f"🌐 **Web:** [{WEB_URL}]({WEB_URL})"
                ),
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
    await channel.send(embed=_services_embed())
    await interaction.response.send_message(f"✅ Posted in {channel.mention}", ephemeral=True)


# ═══════════════════════════════════════════════════════════════════════════
#  /link-account  — link Discord → web, transferring placeholder tickets
# ═══════════════════════════════════════════════════════════════════════════
@bot.tree.command(name="link-account",
                  description="Link your Discord account to your website account.")
@app_commands.describe(identifier="Your website username or email")
async def link_account(interaction: discord.Interaction, identifier: str):
    await interaction.response.defer(ephemeral=True, thinking=True)
    status, body = await post_web("/bridge/discord/link", {
        "identifier": identifier.strip(),
        "discord_id": str(interaction.user.id),
        "discord_username": str(interaction.user),
    })

    if status == 200 and body and body.get("ok"):
        username = body.get("user", identifier)
        moved_tickets = body.get("transferred_tickets", 0)

        embed = brand_embed(
            title="✅ Account linked",
            description=f"Your Discord is now linked to web user **{username}**.",
            colour=COLOR_OPEN,
            url=WEB_URL,
        )
        if moved_tickets:
            embed.add_field(
                name="🎫 Tickets transferred",
                value=(
                    f"Found **{moved_tickets}** ticket"
                    f"{'s' if moved_tickets != 1 else ''} you opened on Discord "
                    f"before linking — all moved to your `{username}` account."
                ),
                inline=False,
            )
        embed.add_field(
            name="🌐 Manage your tickets",
            value=f"[{WEB_URL}/tickets]({WEB_URL}/tickets)",
            inline=False,
        )
        await interaction.followup.send(embed=embed, ephemeral=True)

    elif status == 409 and body:
        await interaction.followup.send(
            embed=brand_embed(
                title="⚠️ Already linked",
                description=body.get("error", "This Discord account is already linked to someone else."),
                colour=COLOR_PENDING,
            ),
            ephemeral=True,
        )

    elif status == 404:
        await interaction.followup.send(
            embed=brand_embed(
                title="❌ User not found",
                description=(
                    f"No website user with username or email `{identifier}`.\n"
                    f"Don't have an account yet? Sign up at {WEB_URL}/auth/register"
                ),
                colour=COLOR_DANGER,
            ),
            ephemeral=True,
        )

    else:
        await interaction.followup.send(
            embed=brand_embed(
                title="❌ Couldn't link account",
                description=(
                    f"Something went wrong. Try again in a moment, or sign up at "
                    f"{WEB_URL} first."
                ),
                colour=COLOR_DANGER,
            ),
            ephemeral=True,
        )


# ═══════════════════════════════════════════════════════════════════════════
#  /my-tickets — see your tickets right inside Discord
# ═══════════════════════════════════════════════════════════════════════════
@bot.tree.command(name="my-tickets",
                  description="List your open & recent tickets.")
async def my_tickets(interaction: discord.Interaction):
    await interaction.response.defer(ephemeral=True, thinking=True)
    status, body = await post_web("/bridge/discord/my-tickets", {
        "discord_id": str(interaction.user.id),
        "limit": 15,
    })

    if status != 200 or not body:
        return await interaction.followup.send(
            embed=brand_embed(
                title="❌ Couldn't fetch your tickets",
                description="The website is not responding. Try again in a moment.",
                colour=COLOR_DANGER,
            ),
            ephemeral=True,
        )

    tickets = body.get("tickets", [])
    is_placeholder = body.get("is_placeholder", False)

    if not tickets:
        return await interaction.followup.send(
            embed=brand_embed(
                title="📭 No tickets yet",
                description=(
                    "You haven't opened any tickets.\n"
                    "Click a service button on the ticket panel to open your first one."
                ),
            ),
            ephemeral=True,
        )

    embed = brand_embed(
        title=f"🎫 Your tickets ({len(tickets)})",
        description=(
            f"Your **{len(tickets)}** most recent tickets."
            + (
                f"\n\n💡 Run `/link-account <username>` to merge these into your "
                f"main website account."
                if is_placeholder else ""
            )
        ),
        url=f"{WEB_URL}/tickets",
    )

    for t in tickets[:10]:
        status_emoji = {"open": "🔓", "pending": "⏳", "closed": "🔒"}.get(t.get("status"), "•")
        pri_emoji = {"low": "⚪", "normal": "🔵", "high": "🟠", "urgent": "🔴"}.get(t.get("priority"), "")
        subject = (t.get("subject") or "Untitled")[:80]
        link = f"{WEB_URL}/tickets/{t['id']}"
        embed.add_field(
            name=f"#{t['id']:04d} · {status_emoji} {t.get('status', '?').title()} · {pri_emoji}",
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


# ═══════════════════════════════════════════════════════════════════════════
#  Ticket channel utilities + slash commands
# ═══════════════════════════════════════════════════════════════════════════
TICKET_NAME_RE = re.compile(r"^ticket-\d+(-[\w-]*)?(?:-closed)?$")


def is_ticket_channel(channel: discord.abc.GuildChannel) -> bool:
    return isinstance(channel, discord.TextChannel) and bool(TICKET_NAME_RE.match(channel.name))


@bot.tree.command(name="close", description="Close this ticket")
async def close_cmd(interaction: discord.Interaction):
    if not is_ticket_channel(interaction.channel):
        return await interaction.response.send_message("Not a ticket channel.", ephemeral=True)
    await interaction.response.defer(ephemeral=False)
    await post_web("/bridge/discord/status", {
        "channel_id": str(interaction.channel.id),
        "status": "closed",
        "actor": str(interaction.user),
    })
    await interaction.followup.send(embed=brand_embed(
        title="🔒 Ticket closed",
        description=f"Closed by {interaction.user.mention}",
        colour=COLOR_CLOSED,
    ))


@bot.tree.command(name="reopen", description="Reopen this ticket")
async def reopen_cmd(interaction: discord.Interaction):
    if not is_ticket_channel(interaction.channel):
        return await interaction.response.send_message("Not a ticket channel.", ephemeral=True)
    await interaction.response.defer(ephemeral=False)
    await post_web("/bridge/discord/status", {
        "channel_id": str(interaction.channel.id),
        "status": "open",
        "actor": str(interaction.user),
    })
    await interaction.followup.send(embed=brand_embed(
        title="🔓 Ticket reopened",
        description=f"Reopened by {interaction.user.mention}",
        colour=COLOR_OPEN,
    ))


@bot.tree.command(name="ping", description="Check the bot is alive.")
async def ping_cmd(interaction: discord.Interaction):
    await interaction.response.send_message(
        f"🏓 Pong! `{round(bot.latency * 1000)}ms`", ephemeral=True
    )


# ═══════════════════════════════════════════════════════════════════════════
#  Live message bridge: Discord → Web
# ═══════════════════════════════════════════════════════════════════════════
@bot.event
async def on_message(message: discord.Message):
    if message.author.bot:
        return
    if not is_ticket_channel(message.channel):
        return
    content = (message.content or "").strip()
    if not content and not message.attachments:
        return

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


async def http_health(_request):
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

    specialist_role: Optional[discord.Role] = None
    for s in SERVICES.values():
        if s["category"] == category_name:
            specialist_role = find_role(guild, s["specialist_role"])
            break

    overwrites = {guild.default_role: discord.PermissionOverwrite(view_channel=False)}
    if guild.me:
        overwrites[guild.me] = discord.PermissionOverwrite(
            view_channel=True, send_messages=True,
            read_message_history=True, manage_channels=True, manage_messages=True,
        )

    for r in staff_roles(guild):
        overwrites[r] = discord.PermissionOverwrite(
            view_channel=True, send_messages=True,
            read_message_history=True, manage_messages=True,
        )

    if specialist_role:
        overwrites[specialist_role] = discord.PermissionOverwrite(
            view_channel=True, send_messages=True, read_message_history=True,
        )

    if STAFF_ROLE_ID:
        role = guild.get_role(STAFF_ROLE_ID)
        if role:
            overwrites[role] = discord.PermissionOverwrite(
                view_channel=True, send_messages=True, read_message_history=True,
            )

    owner_member = None
    if owner_discord_id:
        try:
            owner_member = guild.get_member(int(owner_discord_id))
            if owner_member:
                overwrites[owner_member] = discord.PermissionOverwrite(
                    view_channel=True, send_messages=True, read_message_history=True, attach_files=True,
                )
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
            topic=f"#{ticket_id} · {company_name} · {category_name} · priority: {priority} · owner: {owner}",
        )
    except discord.Forbidden:
        return web.json_response({"error": "bot lacks Manage Channels"}, status=500)
    except discord.HTTPException as e:
        log.exception("Channel create failed")
        return web.json_response({"error": str(e)}, status=500)

    pri_emoji, pri_color, pri_label = PRIORITY_STYLES.get(priority, PRIORITY_STYLES["normal"])
    stat_emoji, _, stat_label = STATUS_STYLES["open"]
    ticket_url = f"{WEB_URL}/tickets/{ticket_id}"

    embed = discord.Embed(
        title=f"🎫 Ticket #{ticket_id}",
        description=f"### {subject}",
        color=pri_color, timestamp=datetime.now(timezone.utc), url=ticket_url,
    )
    embed.add_field(name="🏢 Company",  value=f"`{company_name}`",  inline=True)
    embed.add_field(name="📂 Category", value=f"`{category_name}`", inline=True)
    embed.add_field(name="\u200b",      value="\u200b",             inline=True)
    embed.add_field(name="Status",      value=f"{stat_emoji} **{stat_label}**", inline=True)
    embed.add_field(name="Priority",    value=f"{pri_emoji} **{pri_label}**",   inline=True)
    embed.add_field(name="Owner",
                    value=f"<@{owner_member.id}>" if owner_member else f"`{owner}`",
                    inline=True)

    if initial_msg:
        b = initial_msg if len(initial_msg) <= 1000 else initial_msg[:1000] + "…"
        embed.add_field(name="📝 Initial Message", value=f">>> {b}", inline=False)

    embed.add_field(
        name="\u200b",
        value=(f"🔗 [Open on the dashboard]({ticket_url})\n"
               f"💬 Reply here or on the web — both stay in sync\n"
               f"🔒 Use `/close` to close, `/reopen` to reopen"),
        inline=False,
    )
    brand_footer(embed, f"Ticket #{ticket_id}")
    if BRAND_LOGO_URL:
        embed.set_thumbnail(url=BRAND_LOGO_URL)

    mentions = []
    if owner_member:
        mentions.append(owner_member.mention)
    if specialist_role:
        mentions.append(specialist_role.mention)
    elif STAFF_ROLE_ID:
        r = guild.get_role(STAFF_ROLE_ID)
        if r:
            mentions.append(r.mention)

    try:
        await channel.send(
            content=" ".join(mentions) if mentions else None,
            embed=embed,
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

    e = discord.Embed(
        description=body[:4000],
        color=role_color,
        timestamp=datetime.now(timezone.utc),
    )
    e.set_author(name=f"{badge} · {author} (via web)")
    brand_footer(e)

    try:
        await channel.send(embed=e)
    except discord.HTTPException as ex:
        return web.json_response({"error": str(ex)}, status=500)
    return web.json_response({"ok": True})


async def http_ticket_status(request: web.Request):
    if not _bridge_auth_ok(request):
        return web.json_response({"error": "unauthorized"}, status=401)
    data = await request.json()
    channel = bot.get_channel(int(data["channel_id"]))
    if not channel:
        return web.json_response({"error": "channel not found"}, status=404)

    new_status = data.get("status")
    actor      = data.get("actor", "system")
    emoji, color, label = STATUS_STYLES.get(new_status, ("•", BRAND_BLUE, str(new_status)))

    e = discord.Embed(
        title=f"{emoji} Status changed: {label}",
        description=f"Updated by **{actor}**",
        color=color, timestamp=datetime.now(timezone.utc),
    )
    brand_footer(e)
    try:
        await channel.send(embed=e)
        if new_status == "closed" and not channel.name.endswith("-closed"):
            try:
                await channel.edit(name=(channel.name[:90] + "-closed"))
            except discord.HTTPException:
                pass
    except discord.HTTPException as ex:
        return web.json_response({"error": str(ex)}, status=500)
    return web.json_response({"ok": True})


async def _run_http_server():
    app = web.Application()
    app.router.add_post("/discord/ticket/create",  http_ticket_create)
    app.router.add_post("/discord/ticket/message", http_ticket_message)
    app.router.add_post("/discord/ticket/status",  http_ticket_status)
    app.router.add_get ("/health",                 http_health)

    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, "0.0.0.0", LISTEN_PORT)
    await site.start()
    log.info("Bot HTTP server listening on :%d", LISTEN_PORT)


# ═══════════════════════════════════════════════════════════════════════════
#  Entrypoint
# ═══════════════════════════════════════════════════════════════════════════
def main():
    if not TOKEN:
        raise SystemExit("DISCORD_TOKEN is required.")
    bot.run(TOKEN)


if __name__ == "__main__":
    main()