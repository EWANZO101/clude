"""
discord_bot.py  –  Bi-directional ticket sync bot for the OpsLabs Commission site.

All config below (bot token, ticket/panel channel IDs, bot secret, site URL, internal
API port) is read from the same `site_settings` table the web app's Settings page
writes to — set it there, then (re)start this process to pick it up. A discord.py
client can't hot-swap its token or reload slash commands mid-run anyway, so config is
only read once, at startup.
"""

import os
import sqlite3
import discord
from discord import app_commands
from aiohttp import web
import requests

# ── Config (read once at startup from the shared SQLite DB) ────────────────────
def _load_settings():
    db_dir = os.path.join(os.path.expanduser('~'), 'opslabs_commission_data')
    db_path = os.path.join(db_dir, 'commissions.db')
    try:
        conn = sqlite3.connect(db_path)
        conn.row_factory = sqlite3.Row
        row = conn.execute("""
            SELECT discord_bot_token, discord_ticket_channel, discord_panel_channel,
                   discord_bot_secret, site_url, discord_bot_internal_url
            FROM site_settings LIMIT 1
        """).fetchone()
        conn.close()
        return dict(row) if row else {}
    except sqlite3.Error as e:
        print(f"[Bot] Couldn't read settings from {db_path} ({e}) — "
              f"make sure the web app has been started at least once first.")
        return {}

_settings = _load_settings()

def _int_or(value, default):
    return int(value) if str(value or '').isdigit() else default

BOT_TOKEN  = _settings.get("discord_bot_token") or ""
SITE_URL   = (_settings.get("site_url") or "http://localhost:5000").rstrip("/")
BOT_SECRET = _settings.get("discord_bot_secret") or "change-me-in-settings"

TICKET_CHANNEL_ID = _int_or(_settings.get("discord_ticket_channel"), 0)
PANEL_CHANNEL_ID   = _int_or(_settings.get("discord_panel_channel"), 0)

# discord_bot_internal_url is e.g. "http://127.0.0.1:5900" — this process binds to
# the port from that same URL so it always matches what the site calls out to.
from urllib.parse import urlparse
_internal_url = _settings.get("discord_bot_internal_url") or "http://127.0.0.1:5900"
INTERNAL_PORT = urlparse(_internal_url).port or 5900


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


# ── Entry point ───────────────────────────────────────────────────────────────
if __name__ == "__main__":
    if not BOT_TOKEN:
        print("ERROR: Bot Token is not set — set it in the site's Admin → Settings page, then restart this process.")
    else:
        client.run(BOT_TOKEN)