"""
discord_bot.py  –  Bi-directional ticket sync bot for ciodrawz commission site.

Environment variables:
  DISCORD_BOT_TOKEN          – bot token from Discord Developer Portal
  DISCORD_TICKET_CHANNEL_ID  – TEXT channel where ticket threads are created
                               (must be a text channel, NOT a category)
  DISCORD_PANEL_CHANNEL_ID   – channel where the "Open a Ticket" button panel lives
                               (set to 1490109811394613380)
  DISCORD_BOT_SECRET         – shared secret matching site admin settings
  SITE_URL                   – e.g. https://order.ciodrawz.space
"""

import os
import re
import asyncio
from datetime import datetime
import discord
from discord import app_commands
from aiohttp import web
import requests

# ── Config ────────────────────────────────────────────────────────────────────
BOT_TOKEN  = os.environ.get("DISCORD_BOT_TOKEN", "")
SITE_URL   = os.environ.get("SITE_URL", "http://localhost:5000").rstrip("/")
BOT_SECRET = os.environ.get("DISCORD_BOT_SECRET", "change-me-in-settings")

_chan_id   = os.environ.get("DISCORD_TICKET_CHANNEL_ID", "0")
TICKET_CHANNEL_ID = int(_chan_id) if _chan_id.isdigit() else 0

_panel_id  = os.environ.get("DISCORD_PANEL_CHANNEL_ID", "0")
PANEL_CHANNEL_ID  = int(_panel_id) if _panel_id.isdigit() else 0

_internal_port = os.environ.get("DISCORD_BOT_INTERNAL_PORT", "5900")
INTERNAL_PORT  = int(_internal_port) if _internal_port.isdigit() else 5900


# ── Ticket modal (pop-up form) ────────────────────────────────────────────────
class TicketModal(discord.ui.Modal, title="Open a Support Ticket"):
    subject = discord.ui.TextInput(
        label="Subject",
        placeholder="Short description of your issue...",
        max_length=200,
        required=True,
    )
    order_id = discord.ui.TextInput(
        label="Order ID (optional)",
        placeholder="e.g. ORD-A1B2C3  — leave blank if you don't have one",
        required=False,
        max_length=30,
    )
    message = discord.ui.TextInput(
        label="Describe your issue",
        style=discord.TextStyle.paragraph,
        placeholder="Please give as much detail as possible...",
        max_length=1800,
        required=True,
    )

    async def on_submit(self, interaction: discord.Interaction):
        await interaction.response.defer(ephemeral=True)
        try:
            resp = requests.post(
                f"{SITE_URL}/api/internal/discord-ticket",
                json={
                    "customer_name":   str(interaction.user),
                    "discord_user_id": str(interaction.user.id),
                    "subject":         self.subject.value,
                    "message":         self.message.value,
                    "order_id":        self.order_id.value.strip(),
                    "channel_id":      str(TICKET_CHANNEL_ID or interaction.channel_id),
                    "secret":          BOT_SECRET,
                },
                timeout=12,
            )
            data = resp.json() if resp.ok else {}
            if data.get("ok"):
                ticket_id  = data["ticket_id"]
                ticket_url = data["ticket_url"]
                thread_url = data.get("thread_url", "")
                msg = (
                    f"✅ **Ticket #{ticket_id} opened!**\n\n"
                    f"🌐 View on site: {ticket_url}\n"
                )
                if thread_url:
                    msg += f"💬 Discord thread: {thread_url}\n"
                msg += "\n*Replies in the thread and on the site stay in sync automatically.*"
                await interaction.followup.send(msg, ephemeral=True)
            else:
                err = data.get("error", "unknown error")
                await interaction.followup.send(
                    f"❌ Could not open ticket: `{err}`\nPlease try again or visit the site.",
                    ephemeral=True,
                )
        except Exception as exc:
            print(f"[Bot] Modal submit error: {exc}")
            await interaction.followup.send("❌ Something went wrong.", ephemeral=True)


# ── Persistent ticket panel view ──────────────────────────────────────────────
class TicketPanelView(discord.ui.View):
    def __init__(self):
        super().__init__(timeout=None)  # never expires

    @discord.ui.button(
        label="🎫  Open a Ticket",
        style=discord.ButtonStyle.primary,
        custom_id="open_ticket_button",  # must stay stable across restarts
    )
    async def open_ticket(self, interaction: discord.Interaction, button: discord.ui.Button):
        await interaction.response.send_modal(TicketModal())


# ── Bot setup ─────────────────────────────────────────────────────────────────
intents = discord.Intents.default()
intents.message_content = True
intents.members = True  # needed to resolve a plain username to a member for DMs

class TicketBot(discord.Client):
    def __init__(self):
        super().__init__(intents=intents)
        self.tree = app_commands.CommandTree(self)

    async def setup_hook(self):
        self.add_view(TicketPanelView())  # re-register persistent view on restart
        self.tree.add_command(ticket_cmd)
        self.tree.add_command(setup_panel_cmd)
        await self.tree.sync()
        if GUILD_ID:
            # /giveaway is registered only in our server (shows up instantly, never elsewhere).
            guild = discord.Object(GUILD_ID)
            self.tree.add_command(giveaway_cmd, guild=guild)
            await self.tree.sync(guild=guild)
        print("[Bot] Slash commands synced.")
        await start_internal_api()

client = TicketBot()


# ── Internal API (site → bot only, localhost) ─────────────────────────────────
# Lets the site ask the bot to DM someone on the Trello ping list. Never exposed
# through nginx — only reachable from this same machine.
async def find_member_by_username(username: str):
    """Search every guild the bot is in for a member whose username or display
    name matches. Requires the Server Members privileged intent."""
    username = username.strip().lstrip("@").lower()
    if not username:
        return None
    for guild in client.guilds:
        member = discord.utils.find(
            lambda m: m.name.lower() == username or (m.global_name or "").lower() == username,
            guild.members,
        )
        if member:
            return member
        try:
            results = await guild.query_members(query=username, limit=5, cache=True)
        except Exception as exc:
            print(f"[Bot] query_members failed in guild {guild.id}: {exc}")
            continue
        for m in results:
            if m.name.lower() == username or (m.global_name or "").lower() == username:
                return m
    return None


async def handle_internal_dm(request):
    try:
        data = await request.json()
    except Exception:
        return web.json_response({"sent": False, "error": "bad json"}, status=400)
    if data.get("secret") != BOT_SECRET:
        return web.json_response({"sent": False, "error": "unauthorized"}, status=403)
    username = (data.get("username") or "").strip()
    user_id  = (data.get("user_id") or "").strip()
    message  = (data.get("message") or "").strip()
    if (not username and not user_id) or not message:
        return web.json_response({"sent": False, "error": "missing username/user_id or message"}, status=400)

    member = None
    if user_id:
        try:
            uid = int(user_id)
            for guild in client.guilds:
                member = guild.get_member(uid)
                if member:
                    break
            if not member:
                member = await client.fetch_user(uid)  # bare User; .send() still needs a shared guild
        except Exception:
            member = None
    if not member and username:
        member = await find_member_by_username(username)
    if not member:
        return web.json_response(
            {"sent": False, "error": "user not found in any server this bot is in"}, status=404
        )

    embed_data = data.get("embed")
    embed = None
    if embed_data:
        embed = discord.Embed(
            title=embed_data.get("title") or None,
            description=embed_data.get("description") or None,
            color=embed_data.get("color") or 0x9B59B6,
        )
        for field in embed_data.get("fields") or []:
            embed.add_field(
                name=field.get("name", "​"),
                value=field.get("value", "​"),
                inline=field.get("inline", True),
            )
        if embed_data.get("footer"):
            embed.set_footer(text=embed_data["footer"])

    view = None
    unsubscribe_url = data.get("unsubscribe_url")
    if unsubscribe_url:
        view = discord.ui.View()
        view.add_item(discord.ui.Button(
            label=data.get("unsubscribe_label") or "Unsubscribe",
            style=discord.ButtonStyle.link,
            url=unsubscribe_url,
        ))

    try:
        if embed:
            await member.send(content=None, embed=embed, view=view)
        else:
            await member.send(content=message, view=view)
        return web.json_response({"sent": True})
    except discord.Forbidden:
        return web.json_response({"sent": False, "error": "DMs closed for this user"}, status=403)
    except Exception as exc:
        return web.json_response({"sent": False, "error": str(exc)}, status=500)


async def handle_internal_search(request):
    """Diagnostic: fuzzy-search cached members across all guilds by partial username/display name."""
    try:
        data = await request.json()
    except Exception:
        return web.json_response({"error": "bad json"}, status=400)
    if data.get("secret") != BOT_SECRET:
        return web.json_response({"error": "unauthorized"}, status=403)
    query = (data.get("query") or "").strip().lower()
    if not query:
        return web.json_response({"error": "missing query"}, status=400)

    matches = []
    for guild in client.guilds:
        for m in guild.members:
            name = m.name.lower()
            display = (m.global_name or "").lower()
            nick = (m.nick or "").lower() if hasattr(m, "nick") else ""
            if query in name or query in display or (nick and query in nick):
                matches.append({
                    "guild": guild.name,
                    "username": m.name,
                    "global_name": m.global_name,
                    "nick": getattr(m, "nick", None),
                    "id": str(m.id),
                })
    return web.json_response({"matches": matches, "guild_count": len(client.guilds),
                               "total_members_cached": sum(g.member_count for g in client.guilds)})


async def start_internal_api():
    app_web = web.Application()
    app_web.router.add_post("/internal/dm", handle_internal_dm)
    app_web.router.add_post("/internal/search", handle_internal_search)
    runner = web.AppRunner(app_web)
    await runner.setup()
    site = web.TCPSite(runner, "127.0.0.1", INTERNAL_PORT)
    await site.start()
    print(f"[Bot] Internal DM API listening on 127.0.0.1:{INTERNAL_PORT}")


# ── Events ────────────────────────────────────────────────────────────────────
@client.event
async def on_ready():
    print(f"[Bot] Online as {client.user}  (ID: {client.user.id})")
    print(f"[Bot] Ticket thread channel : {TICKET_CHANNEL_ID}")
    print(f"[Bot] Panel channel         : {PANEL_CHANNEL_ID}")
    print(f"[Bot] Site URL              : {SITE_URL}")


@client.event
async def on_message(message: discord.Message):
    """Relay ticket thread replies back to the site."""
    if message.author.bot:
        return
    if not isinstance(message.channel, discord.Thread):
        return
    if TICKET_CHANNEL_ID and message.channel.parent_id != TICKET_CHANNEL_ID:
        return

    content = message.content.strip()
    if not content:
        return

    try:
        resp = requests.post(
            f"{SITE_URL}/api/internal/discord-reply",
            json={
                "thread_id":   str(message.channel.id),
                "message":     content,
                "sender_name": str(message.author),
                "secret":      BOT_SECRET,
            },
            timeout=8,
        )
        data = resp.json() if resp.ok else {}
        if data.get("ok"):
            await message.add_reaction("✅")
        elif data.get("error") == "no_ticket":
            pass
        else:
            await message.add_reaction("❌")
            print(f"[Bot] Relay failed: {data}")
    except Exception as exc:
        print(f"[Bot] on_message error: {exc}")


# ── /ticket slash command ─────────────────────────────────────────────────────
@app_commands.command(name="ticket", description="Open a support ticket")
@app_commands.describe(
    subject="Short description of your issue",
    message="Full details",
    order_id="Your order ID if you have one (e.g. ORD-XXXX)",
)
async def ticket_cmd(
    interaction: discord.Interaction,
    subject: str,
    message: str,
    order_id: str = "",
):
    await interaction.response.defer(ephemeral=True)
    try:
        resp = requests.post(
            f"{SITE_URL}/api/internal/discord-ticket",
            json={
                "customer_name":   str(interaction.user),
                "discord_user_id": str(interaction.user.id),
                "subject":         subject,
                "message":         message,
                "order_id":        order_id.strip(),
                "channel_id":      str(TICKET_CHANNEL_ID or interaction.channel_id),
                "secret":          BOT_SECRET,
            },
            timeout=12,
        )
        data = resp.json() if resp.ok else {}
        if data.get("ok"):
            reply = (
                f"✅ **Ticket #{data['ticket_id']} opened!**\n\n"
                f"🌐 {data['ticket_url']}\n"
            )
            if data.get("thread_url"):
                reply += f"💬 {data['thread_url']}\n"
            reply += "\n*Replies sync automatically.*"
            await interaction.followup.send(reply, ephemeral=True)
        else:
            await interaction.followup.send(
                f"❌ Failed: `{data.get('error', 'unknown')}`", ephemeral=True
            )
    except Exception as exc:
        print(f"[Bot] /ticket error: {exc}")
        await interaction.followup.send("❌ Something went wrong.", ephemeral=True)


# ── /setup-panel slash command ────────────────────────────────────────────────
@app_commands.command(
    name="setup-panel",
    description="Post the ticket button panel in a channel (admin only)"
)
@app_commands.describe(channel="Channel to post the panel in (leave blank = current channel)")
async def setup_panel_cmd(
    interaction: discord.Interaction,
    channel: discord.TextChannel = None,
):
    if not interaction.user.guild_permissions.administrator:
        await interaction.response.send_message(
            "❌ Administrators only.", ephemeral=True
        )
        return

    target = channel or interaction.channel
    embed = discord.Embed(
        title="🎫  Support Tickets",
        description=(
            "Need help with your order? Have a question?\n\n"
            "Click the button below to open a support ticket.\n"
            "You'll be asked for a subject and a description.\n\n"
            "Replies sync automatically between Discord and the website."
        ),
        color=0x6366f1,
    )
    embed.set_footer(text="Replies in your ticket thread sync to the website and vice versa.")

    await target.send(embed=embed, view=TicketPanelView())
    await interaction.response.send_message(
        f"✅ Ticket panel posted in {target.mention}", ephemeral=True
    )


# ── Giveaways ────────────────────────────────────────────────────────────────
# The site owns all giveaway state and posts/edits the announcement message itself.
# The bot relays: 🎉 button clicks (custom_id "gvw_enter:<ID>") and the /giveaway
# manager menus, which call /api/internal/giveaway/*.
#
# Everything is locked to one channel and one role: /giveaway only works in
# #🎊giveaways, and every menu is ephemeral (only the person who opened it sees it)
# and re-checks that they hold the giveaway manager role on every click.
GIVEAWAY_CHANNEL_ID = int(os.environ.get("DISCORD_GIVEAWAY_CHANNEL_ID", "1552876827477938258"))
GIVEAWAY_ROLE_ID    = int(os.environ.get("DISCORD_GIVEAWAY_ROLE_ID", "1490117298944741427"))
_guild_id = os.environ.get("DISCORD_GUILD_ID", "1483276046156562549")
GUILD_ID  = int(_guild_id) if _guild_id.isdigit() else 0

MENU_TIMEOUT = 840  # ephemeral interaction tokens die after 15 min
PURPLE, GOLD, GREY, RED = 0xA855F7, 0xF59E0B, 0x6B7280, 0xEF4444

PRIZE_TYPES = {
    "discount": ("🏷️", "Discount Code", "Each winner gets their own single-use % or $ off code"),
    "free_art": ("🎨", "Free Art Piece", "Each winner gets a 100%-off code for a commission type"),
    "custom":   ("✨", "Something Else", "Anything you like — you sort out delivery yourself"),
}
DURATIONS = [("30 minutes", "30m"), ("1 hour", "1h"), ("6 hours", "6h"), ("12 hours", "12h"),
             ("1 day", "1d"), ("3 days", "3d"), ("1 week", "7d"), ("2 weeks", "14d")]
WINNER_COUNTS = [1, 2, 3, 4, 5, 10, 15, 20, 25]
WIN_MODES = {
    "random":     ("🎲", "Random draw", "Entries stay open; winners are drawn when time runs out"),
    "first_come": ("⚡", "First come, first served", "The first N people to enter win instantly"),
}
PING_MODES = {"": ("🔕", "No ping"), "here": ("📣", "@here"), "everyone": ("📢", "@everyone")}

HELP_TOPICS = {
    "types": ("🎁 Prize types",
              "**🏷️ Discount Code** — you set the amount (`20%` or `$10`). Each winner gets their **own "
              "single-use code** DM'd to them, which works in the discount box on the request form.\n\n"
              "**🎨 Free Art Piece** — pick a commission type from the site. Each winner gets a single-use "
              "**100%-off** code, so they just request that piece like normal.\n\n"
              "**✨ Something Else** — name any prize (emotes, a sketch stream shoutout…). Winners are "
              "pinged and DM'd, and you sort out delivery with them yourself."),
    "modes": ("🏆 Win modes",
              "**🎲 Random draw** — people enter until the timer runs out, then the bot picks the winners at "
              "random. Best for hype and fairness.\n\n"
              "**⚡ First come, first served** — the first N people to press 🎉 win instantly and get their "
              "prize right away. The giveaway closes itself once every prize is claimed (or when time runs out)."),
    "entering": ("🙋 How people enter",
                 "Everyone can press **🎉 Enter** on the post in <#{channel}>, or enter on the website by "
                 "signing in with Discord. It's one entry per Discord account across both. People who enter "
                 "can leave again until the giveaway ends (winners can't)."),
    "delivery": ("📦 Winners & prize codes",
                 "Winners are pinged in <#{channel}> and DM'd. For discount / free art prizes the DM contains "
                 "their personal code (also shown to them on the website and to you in **Manage**). Codes are "
                 "single-use and can expire after the number of days you choose (0 = never)."),
    "manage": ("🛠️ Managing",
               "Open **📋 Manage** to see running and recent giveaways. From there you can:\n"
               "• **End now** — close entries and draw immediately\n"
               "• **Extend** — add more time\n"
               "• **Cancel** — stop without drawing\n"
               "• **Reroll** — replace one or all winners. Their unused codes are switched off and the "
               "new winners get fresh ones.\n\n"
               "Everything here is also on the website under **Admin → Giveaways**."),
}


async def _site_post(path: str, payload: dict, timeout: float = 12):
    """POST to the site off the event loop so a slow site can't stall the gateway."""
    payload = {**payload, "secret": BOT_SECRET}
    def _do():
        resp = requests.post(f"{SITE_URL}{path}", json=payload, timeout=timeout)
        try:
            return resp.json()
        except ValueError:
            return {"ok": False, "error": f"site returned HTTP {resp.status_code}"}
    try:
        return await asyncio.to_thread(_do)
    except Exception as exc:
        print(f"[Bot] site call {path} failed: {exc}")
        return {"ok": False, "error": "could not reach the site"}


def _has_giveaway_role(user) -> bool:
    return isinstance(user, discord.Member) and any(r.id == GIVEAWAY_ROLE_ID for r in user.roles)


def _ts(iso: str) -> int:
    return int(datetime.fromisoformat(iso).timestamp())


# ── Public: the 🎉 Enter button on giveaway posts ──
class GiveawayLeaveView(discord.ui.View):
    """Ephemeral follow-up shown to someone who clicks Enter while already entered."""
    def __init__(self, giveaway_id: str):
        super().__init__(timeout=300)
        self.giveaway_id = giveaway_id

    @discord.ui.button(label="Leave giveaway", style=discord.ButtonStyle.secondary)
    async def leave(self, interaction: discord.Interaction, button: discord.ui.Button):
        data = await _site_post("/api/internal/giveaway/enter", {
            "giveaway_id": self.giveaway_id,
            "discord_user_id": str(interaction.user.id),
            "leave": True,
        })
        result = data.get("result")
        msg = {"left": "👋 You've left the giveaway.",
               "not_entered": "You can't leave this one (winners stay in).",
               "closed": "This giveaway has already ended."}.get(result, f"❌ {data.get('error', 'Something went wrong.')}")
        await interaction.response.edit_message(content=msg, view=None)


@client.event
async def on_interaction(interaction: discord.Interaction):
    if interaction.type != discord.InteractionType.component:
        return
    custom_id = (interaction.data or {}).get("custom_id", "")
    if custom_id == MANAGER_PANEL_CUSTOM_ID:
        await open_manager(interaction)
        return
    if not custom_id.startswith("gvw_enter:"):
        return
    giveaway_id = custom_id.split(":", 1)[1]
    await interaction.response.defer(ephemeral=True, thinking=True)
    data = await _site_post("/api/internal/giveaway/enter", {
        "giveaway_id": giveaway_id,
        "discord_user_id": str(interaction.user.id),
        "username": interaction.user.name,
    })
    result = data.get("result")
    entries = (data.get("giveaway") or {}).get("entries")
    if result == "entered":
        await interaction.followup.send(
            f"🎉 You're entered! Good luck. ({entries} {'entry' if entries == 1 else 'entries'} so far)",
            ephemeral=True)
    elif result == "won":
        msg = "⚡ **You won!** You were fast enough to claim one."
        if data.get("code"):
            msg += f"\nYour single-use code: **`{data['code']}`** — use it on the request form: {SITE_URL}/request"
        else:
            msg += " Cioda will be in touch about your prize."
        await interaction.followup.send(msg + "\n*(Also sent to your DMs.)*", ephemeral=True)
    elif result == "already":
        await interaction.followup.send("You're already entered in this giveaway.",
                                        view=GiveawayLeaveView(giveaway_id), ephemeral=True)
    elif result == "closed":
        await interaction.followup.send("This giveaway has ended — entries are closed.", ephemeral=True)
    else:
        await interaction.followup.send(f"❌ Couldn't enter: `{data.get('error', 'unknown error')}`", ephemeral=True)


# ── Manager menus (role-locked, ephemeral) ──
class ManagerView(discord.ui.View):
    """Base for every manager screen: only the opener, and only while they hold the role."""
    def __init__(self, owner_id: int):
        super().__init__(timeout=MENU_TIMEOUT)
        self.owner_id = owner_id

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        if interaction.user.id != self.owner_id or not _has_giveaway_role(interaction.user):
            await interaction.response.send_message("❌ This menu isn't for you.", ephemeral=True)
            return False
        return True

    def add_button(self, label, callback, style=discord.ButtonStyle.secondary, emoji=None, row=None):
        btn = discord.ui.Button(label=label, style=style, emoji=emoji, row=row)
        btn.callback = callback
        self.add_item(btn)
        return btn

    def add_select(self, placeholder, options, callback, row=None):
        sel = discord.ui.Select(placeholder=placeholder, options=options[:25], row=row)
        async def _cb(interaction):
            await callback(interaction, sel.values[0])
        sel.callback = _cb
        self.add_item(sel)
        return sel


def home_embed() -> discord.Embed:
    e = discord.Embed(
        title="🎁 Giveaway Manager",
        description=(f"Everything posts in <#{GIVEAWAY_CHANNEL_ID}> and syncs with the website "
                     "(**Admin → Giveaways**). Only you can see this menu.\n\n"
                     "**🎁 New Giveaway** — discount codes, free art, or anything else\n"
                     "**📋 Manage** — end, extend, cancel or reroll\n"
                     "**❓ How it works** — quick guides on each option"),
        color=PURPLE,
    )
    return e


class HomeView(ManagerView):
    def __init__(self, owner_id: int):
        super().__init__(owner_id)
        self.add_button("New Giveaway", self.new, discord.ButtonStyle.success, "🎁")
        self.add_button("Manage", self.manage, discord.ButtonStyle.primary, "📋")
        self.add_button("How it works", self.help, emoji="❓")

    async def new(self, interaction):
        await interaction.response.edit_message(embed=type_embed(), view=TypeView(self.owner_id))

    async def manage(self, interaction):
        await show_manage_list(interaction, self.owner_id)

    async def help(self, interaction):
        back = lambda: (home_embed(), HomeView(self.owner_id))
        await interaction.response.edit_message(embed=help_embed(None), view=HelpView(self.owner_id, back))


# Help screens
def help_embed(topic) -> discord.Embed:
    if topic is None:
        return discord.Embed(title="❓ How giveaways work",
                             description="Pick a topic below.\n\n" +
                                         "\n".join(f"• {t}" for t, _ in HELP_TOPICS.values()),
                             color=PURPLE)
    title, body = HELP_TOPICS[topic]
    return discord.Embed(title=title, description=body.format(channel=GIVEAWAY_CHANNEL_ID), color=PURPLE)


class HelpView(ManagerView):
    def __init__(self, owner_id: int, back, topic=None):
        super().__init__(owner_id)
        self.back = back
        self.add_select("Pick a topic…",
                        [discord.SelectOption(label=t, value=k, default=(k == topic)) for k, (t, _) in HELP_TOPICS.items()],
                        self.pick)
        self.add_button("Back", self.go_back, emoji="⬅️")

    async def pick(self, interaction, topic):
        await interaction.response.edit_message(embed=help_embed(topic), view=HelpView(self.owner_id, self.back, topic))

    async def go_back(self, interaction):
        embed, view = self.back()
        await interaction.response.edit_message(embed=embed, view=view)


# Step 1 — prize type
def type_embed() -> discord.Embed:
    return discord.Embed(
        title="🎁 New Giveaway — what are you giving away?",
        description="\n".join(f"{e} **{name}** — {desc}" for e, name, desc in PRIZE_TYPES.values()),
        color=PURPLE,
    )


def new_draft(prize_type: str) -> dict:
    return {"prize_type": prize_type, "discount": "", "commission_type_id": None, "commission_type_name": "",
            "prize": "", "description": "", "code_valid_days": 60, "duration": "1d",
            "winners_count": 1, "win_mode": "random", "ping_mode": ""}


class TypeView(ManagerView):
    def __init__(self, owner_id: int):
        super().__init__(owner_id)
        self.add_select("Choose a prize type…",
                        [discord.SelectOption(label=name, value=k, emoji=e, description=desc)
                         for k, (e, name, desc) in PRIZE_TYPES.items()],
                        self.pick)
        self.add_button("Back", self.back, emoji="⬅️")

    async def pick(self, interaction, prize_type):
        draft = new_draft(prize_type)
        if prize_type == "free_art":
            await interaction.response.defer()
            await show_art_types(interaction, self.owner_id, draft)
        else:
            await interaction.response.send_modal(DetailsModal(self.owner_id, draft))

    async def back(self, interaction):
        await interaction.response.edit_message(embed=home_embed(), view=HomeView(self.owner_id))


# Step 1b — which commission type is the free art piece
async def show_art_types(interaction, owner_id, draft):
    """Expects the interaction to be deferred already."""
    data = await _site_post("/api/internal/giveaway/options", {})
    types = data.get("commission_types") or []
    if not types:
        embed = discord.Embed(title="🎨 Free Art Piece", color=RED,
                              description="No active commission types on the site — add some under "
                                          "**Admin → Commission Types** first.")
        view = TypeView(owner_id)
    else:
        embed = discord.Embed(title="🎨 Free Art Piece — which commission?",
                              description="Winners get a single-use **100% off** code for this piece.",
                              color=PURPLE)
        view = ArtTypeView(owner_id, draft, types)
    await interaction.edit_original_response(embed=embed, view=view)


class ArtTypeView(ManagerView):
    def __init__(self, owner_id, draft, types):
        super().__init__(owner_id)
        self.draft = draft
        self.names = {str(t["id"]): t["name"] for t in types}
        self.add_select("Choose a commission type…",
                        [discord.SelectOption(label=t["name"][:100], value=str(t["id"]),
                                              description=f"{t['category']} · ${t['price']:g}"[:100],
                                              default=(t["id"] == draft.get("commission_type_id")))
                         for t in types],
                        self.pick)
        self.add_button("Back", self.back, emoji="⬅️")

    async def pick(self, interaction, type_id):
        self.draft["commission_type_id"] = int(type_id)
        self.draft["commission_type_name"] = self.names.get(type_id, "")
        await interaction.response.send_modal(DetailsModal(self.owner_id, self.draft))

    async def back(self, interaction):
        await interaction.response.edit_message(embed=type_embed(), view=TypeView(self.owner_id))


# Step 2 — details modal (fields depend on prize type)
class DetailsModal(discord.ui.Modal):
    def __init__(self, owner_id, draft):
        kind = draft["prize_type"]
        super().__init__(title=f"{PRIZE_TYPES[kind][1]} — details", timeout=MENU_TIMEOUT)
        self.owner_id, self.draft = owner_id, draft
        self.discount = self.valid_days = None
        if kind == "discount":
            self.discount = discord.ui.TextInput(label="Discount amount", placeholder='e.g. 20%  or  $10',
                                                 default=draft["discount"] or None, max_length=10)
            self.add_item(self.discount)
        self.prize = discord.ui.TextInput(
            label="Prize name" + (" (optional — auto-named if blank)" if kind != "custom" else ""),
            placeholder="e.g. Custom emote pack" if kind == "custom" else "Leave blank for an automatic name",
            default=draft["prize"] or None, required=(kind == "custom"), max_length=200)
        self.add_item(self.prize)
        self.description = discord.ui.TextInput(label="Description / rules (optional)",
                                                style=discord.TextStyle.paragraph, required=False,
                                                default=draft["description"] or None, max_length=1500)
        self.add_item(self.description)
        if kind in ("discount", "free_art"):
            self.valid_days = discord.ui.TextInput(label="Codes valid for how many days? (0 = forever)",
                                                   default=str(draft["code_valid_days"]), max_length=4)
            self.add_item(self.valid_days)

    async def on_submit(self, interaction: discord.Interaction):
        errors = []
        if self.discount is not None:
            value = self.discount.value.strip().replace(" ", "")
            if not re.fullmatch(r"\$?\d+(\.\d{1,2})?[%$]?", value):
                errors.append('Discount must look like `20%` or `$10`.')
            self.draft["discount"] = value
        if self.valid_days is not None:
            if self.valid_days.value.strip().isdigit():
                self.draft["code_valid_days"] = int(self.valid_days.value.strip())
            else:
                errors.append("Code validity must be a whole number of days.")
        self.draft["prize"] = self.prize.value.strip()
        self.draft["description"] = self.description.value.strip()
        await interaction.response.edit_message(embed=settings_embed(self.draft, errors),
                                                view=SettingsView(self.owner_id, self.draft))


class DurationModal(discord.ui.Modal):
    def __init__(self, on_done, title="Custom length"):
        super().__init__(title=title, timeout=MENU_TIMEOUT)
        self.on_done = on_done
        self.length = discord.ui.TextInput(label="How long? e.g. 45m, 2d, 1d12h, 3w", max_length=20)
        self.add_item(self.length)

    async def on_submit(self, interaction: discord.Interaction):
        await self.on_done(interaction, self.length.value.strip().replace(" ", "").lower())


def _duration_label(value: str) -> str:
    return next((label for label, v in DURATIONS if v == value), value)


def _prize_preview(d: dict) -> str:
    if d["prize"]:
        return d["prize"]
    if d["prize_type"] == "discount":
        return f"{d['discount'] or '?'} off Discount Code"
    if d["prize_type"] == "free_art":
        return f"Free {d['commission_type_name'] or 'Art Piece'}"
    return "(no name yet)"


# Step 3 — how it works (duration / winners / mode / ping) + launch
def settings_embed(d: dict, errors=None) -> discord.Embed:
    e_type = PRIZE_TYPES[d["prize_type"]]
    mode = WIN_MODES[d["win_mode"]]
    e = discord.Embed(title=f"🎁 {_prize_preview(d)}", color=RED if errors else PURPLE,
                      description=(d["description"] or "*No description.*")[:1500])
    e.add_field(name="Prize type", value=f"{e_type[0]} {e_type[1]}")
    if d["prize_type"] == "discount":
        e.add_field(name="Discount", value=d["discount"] or "—")
    if d["prize_type"] == "free_art":
        e.add_field(name="Commission", value=d["commission_type_name"] or "—")
    if d["prize_type"] in ("discount", "free_art"):
        e.add_field(name="Codes valid", value=f"{d['code_valid_days']} days" if d["code_valid_days"] else "Forever")
    e.add_field(name="Length", value=_duration_label(d["duration"]))
    e.add_field(name="Winners", value=str(d["winners_count"]))
    e.add_field(name="Win mode", value=f"{mode[0]} {mode[1]}")
    e.add_field(name="Ping", value=PING_MODES[d["ping_mode"]][1])
    e.add_field(name="Channel", value=f"<#{GIVEAWAY_CHANNEL_ID}>")
    if errors:
        e.add_field(name="⚠ Fix before launching", value="\n".join(f"• {x}" for x in errors)[:1024], inline=False)
    e.set_footer(text="Use the menus below to set how it works, then press 🚀 Launch.")
    return e


class SettingsView(ManagerView):
    def __init__(self, owner_id, draft):
        super().__init__(owner_id)
        self.draft = d = draft
        durations = list(DURATIONS)
        if d["duration"] not in [v for _, v in durations]:
            durations.insert(0, (d["duration"], d["duration"]))
        self.add_select("⏱️ How long should it run?",
                        [discord.SelectOption(label=f"Runs for {label}", value=v, default=(v == d["duration"]))
                         for label, v in durations] +
                        [discord.SelectOption(label="Custom length…", value="__custom", emoji="⌨️")],
                        self.set_duration, row=0)
        counts = sorted(set(WINNER_COUNTS) | {d["winners_count"]})
        self.add_select("🏆 How many winners?",
                        [discord.SelectOption(label=f"{n} winner{'s' if n != 1 else ''}", value=str(n),
                                              default=(n == d["winners_count"])) for n in counts],
                        self.set_winners, row=1)
        self.add_select("🎲 How are winners picked?",
                        [discord.SelectOption(label=name, value=k, emoji=e, description=desc,
                                              default=(k == d["win_mode"]))
                         for k, (e, name, desc) in WIN_MODES.items()],
                        self.set_mode, row=2)
        self.add_select("📣 Ping when it's posted?",
                        [discord.SelectOption(label=name, value=k or "none", emoji=e, default=(k == d["ping_mode"]))
                         for k, (e, name) in PING_MODES.items()],
                        self.set_ping, row=3)
        self.add_button("Launch", self.launch, discord.ButtonStyle.success, "🚀", row=4)
        self.add_button("Edit details", self.edit, emoji="✏️", row=4)
        self.add_button("Help", self.help, emoji="❓", row=4)
        self.add_button("Discard", self.discard, discord.ButtonStyle.danger, "✖️", row=4)

    async def _refresh(self, interaction, errors=None):
        await interaction.response.edit_message(embed=settings_embed(self.draft, errors),
                                                view=SettingsView(self.owner_id, self.draft))

    async def set_duration(self, interaction, value):
        if value == "__custom":
            async def done(modal_interaction, length):
                if not re.fullmatch(r"(\d+[wdhms])+", length):
                    await modal_interaction.response.edit_message(
                        embed=settings_embed(self.draft, ["Length must look like `45m`, `2d` or `1d12h`."]),
                        view=SettingsView(self.owner_id, self.draft))
                    return
                self.draft["duration"] = length
                await self._refresh(modal_interaction)
            await interaction.response.send_modal(DurationModal(done))
            return
        self.draft["duration"] = value
        await self._refresh(interaction)

    async def set_winners(self, interaction, value):
        self.draft["winners_count"] = int(value)
        await self._refresh(interaction)

    async def set_mode(self, interaction, value):
        self.draft["win_mode"] = value
        await self._refresh(interaction)

    async def set_ping(self, interaction, value):
        self.draft["ping_mode"] = "" if value == "none" else value
        await self._refresh(interaction)

    async def edit(self, interaction):
        if self.draft["prize_type"] == "free_art":
            await interaction.response.defer()
            await show_art_types(interaction, self.owner_id, self.draft)
        else:
            await interaction.response.send_modal(DetailsModal(self.owner_id, self.draft))

    async def help(self, interaction):
        back = lambda: (settings_embed(self.draft), SettingsView(self.owner_id, self.draft))
        await interaction.response.edit_message(embed=help_embed("modes"),
                                                view=HelpView(self.owner_id, back, "modes"))

    async def discard(self, interaction):
        await interaction.response.edit_message(embed=home_embed(), view=HomeView(self.owner_id))

    async def launch(self, interaction):
        await interaction.response.defer()
        payload = {k: v for k, v in self.draft.items() if k != "commission_type_name"}
        data = await _site_post("/api/internal/giveaway/create",
                                {**payload, "created_by": interaction.user.name})
        if not data.get("ok"):
            await interaction.edit_original_response(
                embed=settings_embed(self.draft, [data.get("error", "Something went wrong.")]),
                view=SettingsView(self.owner_id, self.draft))
            return
        g = data["giveaway"]
        embed = discord.Embed(title="🚀 Giveaway launched!", color=GOLD,
                              description=f"**{g['prize']}** is live in <#{GIVEAWAY_CHANNEL_ID}>.\n"
                                          f"Ends <t:{_ts(g['ends_at'])}:R> · ID `{g['giveaway_id']}`\n🌐 {g['url']}")
        view = ManagerView(self.owner_id)
        view.add_button("Manage it", lambda i: show_giveaway(i, self.owner_id, g["giveaway_id"]), emoji="🛠️")
        view.add_button("Main menu", lambda i: i.response.edit_message(embed=home_embed(), view=HomeView(self.owner_id)), emoji="🏠")
        await interaction.edit_original_response(embed=embed, view=view)


# Manage — list → one giveaway → actions
async def show_manage_list(interaction, owner_id):
    await interaction.response.defer()
    data = await _site_post("/api/internal/giveaway/list", {})
    rows = data.get("giveaways") or []
    view = ManagerView(owner_id)
    if not data.get("ok"):
        embed = discord.Embed(title="📋 Manage", color=RED, description=f"❌ {data.get('error', 'Something went wrong.')}")
    elif not rows:
        embed = discord.Embed(title="📋 Manage", color=GREY, description="No giveaways yet — start one with 🎁 New Giveaway.")
    else:
        lines = []
        for g in rows[:10]:
            when = f"ends <t:{_ts(g['ends_at'])}:R>" if g["status"] == "active" else "ended"
            lines.append(f"`{g['giveaway_id']}` **{g['prize']}** — {when} · {g['entries']} entries")
        embed = discord.Embed(title="📋 Manage giveaways", color=PURPLE,
                              description="Pick one below.\n\n" + "\n".join(lines))
        async def pick(i, gid):
            await show_giveaway(i, owner_id, gid)
        view.add_select("Choose a giveaway…",
                        [discord.SelectOption(label=f"{g['prize']}"[:100], value=g["giveaway_id"],
                                              emoji="🟢" if g["status"] == "active" else "🏁",
                                              description=f"{g['giveaway_id']} · {g['status']} · {g['entries']} entries")
                         for g in rows],
                        pick)
    view.add_button("Main menu", lambda i: i.response.edit_message(embed=home_embed(), view=HomeView(owner_id)), emoji="🏠")
    await interaction.edit_original_response(embed=embed, view=view)


def giveaway_embed(g: dict, note: str = "") -> discord.Embed:
    color = {"active": PURPLE, "ended": GOLD}.get(g["status"], GREY)
    e = discord.Embed(title=f"🎁 {g['prize']}", color=color,
                      description=((note + "\n\n") if note else "") + (g.get("prize_details") or "").strip())
    e.add_field(name="Status", value=g["status"].title())
    e.add_field(name="Entries", value=str(g["entries"]))
    mode = WIN_MODES.get(g.get("win_mode"), ("", "?"))
    e.add_field(name="Win mode", value=f"{mode[0]} {mode[1]} · {g['winners_count']}")
    label = "Ends" if g["status"] == "active" else "Was due"
    e.add_field(name=label, value=f"<t:{_ts(g['ends_at'])}:R>")
    if g["winners"]:
        e.add_field(name="Winners", inline=False, value="\n".join(
            w["mention"] + (" ✉" if w.get("is_email") else "") + (f" — `{w['code']}`" if w.get("code") else "")
            for w in g["winners"])[:1024])
    e.set_footer(text=f"{g['giveaway_id']} · {g['url']}")
    return e


async def show_giveaway(interaction, owner_id, giveaway_id, note=""):
    if not interaction.response.is_done():
        await interaction.response.defer()
    data = await _site_post("/api/internal/giveaway/action", {"action": "info", "giveaway_id": giveaway_id})
    if not data.get("ok"):
        await interaction.edit_original_response(
            embed=discord.Embed(title="❌", description=data.get("error", "Something went wrong."), color=RED),
            view=HomeView(owner_id))
        return
    await interaction.edit_original_response(embed=giveaway_embed(data["giveaway"], note),
                                             view=GiveawayActionsView(owner_id, data["giveaway"]))


class GiveawayActionsView(ManagerView):
    def __init__(self, owner_id, g):
        super().__init__(owner_id)
        self.g = g
        gid = g["giveaway_id"]
        if g["status"] == "active":
            self.add_button("End now & draw", self.confirm("end", "End now and draw the winners?"),
                            discord.ButtonStyle.success, "🏁", row=0)
            self.add_button("Extend", self.extend, emoji="⏱️", row=0)
            self.add_button("Cancel giveaway", self.confirm("cancel", "Cancel it without drawing anyone?"),
                            discord.ButtonStyle.danger, "🚫", row=0)
        elif g["status"] == "ended" and g["winners"]:
            self.add_button("Reroll all winners", self.confirm("reroll", "Replace ALL winners with new picks?"),
                            discord.ButtonStyle.primary, "🔁", row=0)
            async def reroll_one(i, entry_id):
                await self.run(i, "reroll", winner_entry_id=entry_id)
            self.add_select("🔁 Reroll just one winner…",
                            [discord.SelectOption(label=w["display"][:100], value=str(w["entry_id"]),
                                                  description=f"Code {w['code']}" if w.get("code") else None)
                             for w in g["winners"]],
                            reroll_one, row=1)
        self.add_button("Refresh", lambda i: show_giveaway(i, owner_id, gid), emoji="🔄", row=2)
        self.add_button("Back to list", lambda i: show_manage_list(i, owner_id), emoji="⬅️", row=2)

    def confirm(self, action, question):
        async def _cb(interaction):
            view = ManagerView(self.owner_id)
            view.add_button("Yes, do it", lambda i: self.run(i, action), discord.ButtonStyle.danger, "✅")
            view.add_button("No, go back", lambda i: show_giveaway(i, self.owner_id, self.g["giveaway_id"]), emoji="↩️")
            await interaction.response.edit_message(embed=giveaway_embed(self.g, f"**{question}**"), view=view)
        return _cb

    async def run(self, interaction, action, **extra):
        await interaction.response.defer()
        data = await _site_post("/api/internal/giveaway/action",
                                {"action": action, "giveaway_id": self.g["giveaway_id"], **extra})
        note = {"end": "🏁 Ended — winners drawn and DM'd.", "cancel": "🚫 Cancelled.",
                "reroll": "🔁 Rerolled — new winners pinged and DM'd.", "extend": "⏱️ Extended."}.get(action, "")
        if not data.get("ok"):
            note = f"❌ {data.get('error', 'Something went wrong.')}"
        await show_giveaway(interaction, self.owner_id, self.g["giveaway_id"], note)

    async def extend(self, interaction):
        async def done(modal_interaction, length):
            await self.run(modal_interaction, "extend", duration=length)
        await interaction.response.send_modal(DurationModal(done, title="Extend by how long?"))


# The pinned panel message in #🎊giveaways has one button with this fixed custom_id.
# Everyone in the channel can see the panel, but only the giveaway role gets past the
# role check, and the menu it opens is ephemeral.
MANAGER_PANEL_CUSTOM_ID = "gvw_manager_open"


async def open_manager(interaction: discord.Interaction):
    if not _has_giveaway_role(interaction.user):
        await interaction.response.send_message("❌ You don't have access to the giveaway manager.", ephemeral=True)
        return
    await interaction.response.send_message(embed=home_embed(), view=HomeView(interaction.user.id), ephemeral=True)


@app_commands.command(name="giveaway", description="Open the giveaway manager (staff only)")
@app_commands.guild_only()
@app_commands.default_permissions(administrator=True)
async def giveaway_cmd(interaction: discord.Interaction):
    if not _has_giveaway_role(interaction.user):
        await interaction.response.send_message("❌ You don't have access to the giveaway manager.", ephemeral=True)
        return
    if interaction.channel_id != GIVEAWAY_CHANNEL_ID:
        await interaction.response.send_message(f"Giveaways live in <#{GIVEAWAY_CHANNEL_ID}> — run `/giveaway` there.",
                                                ephemeral=True)
        return
    await interaction.response.send_message(embed=home_embed(), view=HomeView(interaction.user.id), ephemeral=True)


# ── Entry point ───────────────────────────────────────────────────────────────
if __name__ == "__main__":
    if not BOT_TOKEN:
        print("ERROR: DISCORD_BOT_TOKEN is not set.")
    else:
        client.run(BOT_TOKEN)