INBOX_CHANNEL_ID   = 1489621206641541231
COMPOSE_CHANNEL_ID = 1489627254739832892

"""
CioDrawz Email ↔ Discord Bot
═══════════════════════════════════════════════════════════════
INBOX MONITOR  (existing channel)
  • Polls IMAP every 30s, posts rich embeds + Reply/Forward dropdown.

COMPOSE PANEL  (channel 1489627254739832892)
  • Persistent branded "Send Email" panel.
  • Dropdown lists all known contacts.
  • Selecting a contact opens a compose modal pre-filled with the
    CioDrawz template (subject, order ID, body, order link).
  • Management options in the same dropdown:
      ➕ Add Contact    – type name + email
      ✏️ Edit Template  – edit subject & body template
      🗑️ Remove Contact – pick contact to delete

Data is saved to  /root/cbot/cbot_data.json  and survives restarts.

Requirements:
    pip install discord.py

Setup:
    Fill in the CONFIG block below, then:  python email_discord_bot.py
═══════════════════════════════════════════════════════════════
"""

import asyncio, imaplib, email, smtplib, hashlib, html, re, json, logging, os
from email.header import decode_header
from email.utils import parseaddr, parsedate_to_datetime, formataddr
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
from datetime import timezone
from pathlib import Path

import discord
from discord.ext import tasks

# ═══════════════════════════════════════════════════════════════
#  CONFIG
# ═══════════════════════════════════════════════════════════════


BOT_TOKEN   = os.environ.get("BOT_TOKEN", "")  # redacted          # Discord bot token
CHANNEL_ID  = 1489621206641541231            # Right-click channel → Copy ID

IMAP_SERVER = "mail.ciodrawz.space"
IMAP_PORT   = 143          # 143 plain  |  993 SSL
IMAP_SSL    = False

SMTP_SERVER = "mail.ciodrawz.space"
SMTP_PORT   = 587          # 587 STARTTLS  |  465 SSL
SMTP_SSL    = False        # True = use SMTP_SSL wrapper, False = STARTTLS

EMAIL_ADDRESS  = "cioda@ciodrawz.space"
EMAIL_PASSWORD = os.environ.get("EMAIL_PASSWORD", "")  # redacted

MAILBOX        = "INBOX"
POLL_INTERVAL  = 30        # seconds between IMAP checks


DATA_FILE = Path("/root/cbot/cbot_data.json")

ORDER_LINK = "https://order.ciodrawz.space/"

# CioDrawz brand colour
BRAND_COLOR  = 0x9B59B6   # purple
INBOX_COLORS = [0x5865F2, 0xEB459E, 0x57F287, 0xFEE75C, 0xED4245, 0x00B0F4, 0xF57C00]

DEFAULT_TEMPLATE = {
    "subject": "Your CioDrawz Order – #{order_id}",
    "body": (
        "Hello,\n\n"
        "Thank you for choosing CioDrawz! Here are your order details:\n\n"
        "📦  Order ID:  #{order_id}\n\n"
        "You can view and track your order here:\n"
        f"{ORDER_LINK}\n\n"
        "If you have any questions, feel free to reply to this email.\n\n"
        "Kind regards,\n"
        "CioDrawz Team\n"
        f"{EMAIL_ADDRESS}"
    ),
}

# ═══════════════════════════════════════════════════════════════
#  Logging
# ═══════════════════════════════════════════════════════════════

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger(__name__)

# ═══════════════════════════════════════════════════════════════
#  Persistent data  (contacts + template + compose message ID)
# ═══════════════════════════════════════════════════════════════

def load_data() -> dict:
    if DATA_FILE.exists():
        try:
            return json.loads(DATA_FILE.read_text())
        except Exception:
            pass
    return {
        "contacts":          [],          # [{"name": str, "email": str}]
        "template":          DEFAULT_TEMPLATE.copy(),
        "compose_message_id": None,
    }

def save_data(data: dict) -> None:
    DATA_FILE.parent.mkdir(parents=True, exist_ok=True)
    DATA_FILE.write_text(json.dumps(data, indent=2))

def upsert_contact(data: dict, name: str, email_addr: str) -> bool:
    """Add contact if not already present. Returns True if added."""
    email_addr = email_addr.strip().lower()
    for c in data["contacts"]:
        if c["email"].lower() == email_addr:
            return False
    data["contacts"].append({"name": name.strip() or email_addr, "email": email_addr})
    save_data(data)
    return True

def remove_contact(data: dict, email_addr: str) -> bool:
    before = len(data["contacts"])
    data["contacts"] = [c for c in data["contacts"] if c["email"].lower() != email_addr.lower()]
    if len(data["contacts"]) < before:
        save_data(data)
        return True
    return False

# ═══════════════════════════════════════════════════════════════
#  Text helpers
# ═══════════════════════════════════════════════════════════════

def decode_mime(raw: str) -> str:
    parts = decode_header(raw or "")
    return "".join(
        chunk.decode(cs or "utf-8", errors="replace") if isinstance(chunk, bytes) else chunk
        for chunk, cs in parts
    ).strip()

def strip_html(text: str) -> str:
    for pat in (r"<style[^>]*>.*?</style>", r"<script[^>]*>.*?</script>"):
        text = re.sub(pat, "", text, flags=re.DOTALL | re.IGNORECASE)
    text = re.sub(r"<br\s*/?>",  "\n", text, flags=re.IGNORECASE)
    text = re.sub(r"</?p[^>]*>", "\n", text, flags=re.IGNORECASE)
    text = re.sub(r"<[^>]+>", "", text)
    text = html.unescape(text)
    lines = [re.sub(r"[ \t]+", " ", ln).strip() for ln in text.splitlines()]
    return "\n".join(ln for ln in lines if ln).strip()

def get_body(msg: email.message.Message) -> str:
    plain = html_body = None
    if msg.is_multipart():
        for part in msg.walk():
            ct = part.get_content_type()
            if "attachment" in str(part.get("Content-Disposition", "")):
                continue
            cs  = part.get_content_charset() or "utf-8"
            raw = part.get_payload(decode=True)
            if raw is None:
                continue
            decoded = raw.decode(cs, errors="replace")
            if ct == "text/plain"  and plain     is None: plain     = decoded
            elif ct == "text/html" and html_body is None: html_body = decoded
    else:
        cs  = msg.get_content_charset() or "utf-8"
        raw = msg.get_payload(decode=True)
        if raw:
            decoded = raw.decode(cs, errors="replace")
            if msg.get_content_type() == "text/html": html_body = decoded
            else:                                      plain     = decoded
    body = plain or (strip_html(html_body) if html_body else "")
    return re.sub(r"\n{3,}", "\n\n", body).strip()

def list_attachments(msg: email.message.Message) -> list:
    out = []
    if msg.is_multipart():
        for part in msg.walk():
            if "attachment" in str(part.get("Content-Disposition", "")):
                fn = part.get_filename()
                if fn: out.append(decode_mime(fn))
    return out

def clean_address_list(raw: str) -> str:
    if not raw: return "—"
    out = []
    for part in raw.split(","):
        name, addr = parseaddr(part.strip())
        local = addr.split("@")[0] if "@" in addr else ""
        if re.fullmatch(r"[0-9a-f]{20,}", local): continue
        out.append(name.strip() if name.strip() else addr)
    return ", ".join(out) if out else "—"

def gravatar(addr: str) -> str:
    h = hashlib.md5(addr.strip().lower().encode()).hexdigest()
    return f"https://www.gravatar.com/avatar/{h}?d=identicon&s=128"

def discord_ts(date_str: str) -> str:
    try:
        dt = parsedate_to_datetime(date_str).astimezone(timezone.utc)
        return f"<t:{int(dt.timestamp())}:F>"
    except Exception:
        return date_str or "Unknown"

def trunc(s: str, n: int) -> str:
    return s if len(s) <= n else s[:n - 1] + "…"

def color_for(addr: str) -> int:
    domain = addr.split("@")[-1] if "@" in addr else addr
    return INBOX_COLORS[int(hashlib.md5(domain.encode()).hexdigest(), 16) % len(INBOX_COLORS)]

FILE_ICONS = {
    ".jpg":"🖼️",".jpeg":"🖼️",".png":"🖼️",".gif":"🖼️",".webp":"🖼️",
    ".pdf":"📄",".doc":"📝",".docx":"📝",".xls":"📊",".xlsx":"📊",
    ".ppt":"📋",".pptx":"📋",".txt":"📃",".zip":"🗜️",".rar":"🗜️",
    ".py":"🐍",".js":"📜",".html":"🌐",".css":"🎨",
}
def file_icon(name: str) -> str:
    ext = "." + name.rsplit(".", 1)[-1].lower() if "." in name else ""
    return FILE_ICONS.get(ext, "📎")

# ═══════════════════════════════════════════════════════════════
#  SMTP
# ═══════════════════════════════════════════════════════════════

def send_email(to: str, subject: str, body: str, in_reply_to: str = "") -> None:
    mime = MIMEMultipart("alternative")
    mime["From"]    = formataddr(("CioDrawz", EMAIL_ADDRESS))
    mime["To"]      = to
    mime["Subject"] = subject
    if in_reply_to:
        mime["In-Reply-To"] = in_reply_to
        mime["References"]  = in_reply_to
    mime.attach(MIMEText(body, "plain", "utf-8"))
    if SMTP_SSL:
        server = smtplib.SMTP_SSL(SMTP_SERVER, SMTP_PORT)
    else:
        server = smtplib.SMTP(SMTP_SERVER, SMTP_PORT)
        server.ehlo(); server.starttls(); server.ehlo()
    server.login(EMAIL_ADDRESS, EMAIL_PASSWORD)
    server.sendmail(EMAIL_ADDRESS, [to], mime.as_string())
    server.quit()
    log.info("Sent email to %s  subject=%s", to, subject)

# ═══════════════════════════════════════════════════════════════
#  Inbox embed builder
# ═══════════════════════════════════════════════════════════════

def build_inbox_embed(msg: email.message.Message) -> discord.Embed:
    subject     = decode_mime(msg.get("Subject", "(no subject)"))
    raw_from    = decode_mime(msg.get("From", ""))
    raw_to      = decode_mime(msg.get("To",   ""))
    raw_cc      = decode_mime(msg.get("Cc",   ""))
    date_str    = msg.get("Date", "")
    body        = get_body(msg)
    attachments = list_attachments(msg)

    sender_name, sender_addr = parseaddr(raw_from)
    sender_name = sender_name.strip() or sender_addr

    embed = discord.Embed(
        title       = f"✉️  {trunc(subject, 250)}",
        description = f">>> {trunc(body, 900)}" if body else "*— no body —*",
        color       = color_for(sender_addr),
    )
    embed.set_author(name=trunc(sender_name, 256), icon_url=gravatar(sender_addr))

    from_val = f"**{sender_name}**\n{sender_addr}" if sender_name != sender_addr else sender_addr
    embed.add_field(name="📨  From",     value=trunc(from_val, 256),                    inline=True)
    embed.add_field(name="📬  To",       value=trunc(clean_address_list(raw_to), 256),  inline=True)
    embed.add_field(name="\u200b",       value="\u200b",                                inline=True)
    embed.add_field(name="📅  Received", value=discord_ts(date_str),                    inline=False)

    if raw_cc:
        embed.add_field(name="📋  CC", value=trunc(clean_address_list(raw_cc), 256), inline=False)
    if len(body) > 900:
        embed.add_field(name="📖  Message truncated",
                        value="*Open your mailbox to read the full email.*", inline=False)
    if attachments:
        lines = [f"{file_icon(a)}  {a}" for a in attachments]
        embed.add_field(name=f"📎  Attachments ({len(attachments)})",
                        value=trunc("\n".join(lines), 1024), inline=False)
    embed.set_footer(text=f"📮  {EMAIL_ADDRESS}",
                     icon_url="https://cdn-icons-png.flaticon.com/512/732/732200.png")
    return embed

# ═══════════════════════════════════════════════════════════════
#  Compose panel embed  (branded)
# ═══════════════════════════════════════════════════════════════

def build_compose_embed(template: dict) -> discord.Embed:
    embed = discord.Embed(
        title       = "✉️  Send an Email",
        description = (
            "Select a contact from the dropdown below to compose an email.\n"
            "Your message will be sent from **CioDrawz** using the template below.\n\u200b"
        ),
        color = BRAND_COLOR,
    )
    embed.add_field(
        name  = "📋  Current Template — Subject",
        value = f"`{trunc(template['subject'], 200)}`",
        inline= False,
    )
    embed.add_field(
        name  = "📝  Current Template — Body Preview",
        value = f"```\n{trunc(template['body'], 500)}\n```",
        inline= False,
    )
    embed.add_field(
        name  = "🔗  Order Portal",
        value = f"[order.ciodrawz.space]({ORDER_LINK})",
        inline= True,
    )
    embed.add_field(
        name  = "📮  Sending From",
        value = EMAIL_ADDRESS,
        inline= True,
    )
    embed.set_footer(
        text     = "CioDrawz  •  Use the dropdown to compose, manage contacts, or edit the template.",
        icon_url = "https://cdn-icons-png.flaticon.com/512/732/732200.png",
    )
    return embed

# ═══════════════════════════════════════════════════════════════
#  Modals
# ═══════════════════════════════════════════════════════════════

# ── Inbox reply/forward ────────────────────────────────────────

class InboxReplyModal(discord.ui.Modal):
    def __init__(self, action, to, subject, cc, message_id, original_body):
        titles = {"reply": "↩️ Reply", "reply_all": "↩️ Reply All", "forward": "➡️ Forward"}
        super().__init__(title=titles.get(action, "Compose"))
        self.action = action; self.to_addr = to; self.subject = subject
        self.cc = cc; self.message_id = message_id

        quoted = "\n".join(f"> {ln}" for ln in original_body.splitlines()[:15])

        if action == "forward":
            self.to_input = discord.ui.TextInput(
                label="Forward to (email address)", placeholder="recipient@example.com",
                required=True, max_length=256)
            self.add_item(self.to_input)
        else:
            self.to_input = None

        self.body_input = discord.ui.TextInput(
            label="Message", style=discord.TextStyle.paragraph,
            placeholder="Write your message here…",
            default=quoted if action != "forward" else trunc(original_body, 1800),
            required=True, max_length=2000)
        self.add_item(self.body_input)

    async def on_submit(self, interaction: discord.Interaction):
        await interaction.response.defer(ephemeral=True)
        body    = self.body_input.value
        subject = self.subject
        cc      = self.cc if self.action == "reply_all" else ""
        to      = self.to_input.value.strip() if self.action == "forward" else self.to_addr
        if self.action == "forward": subject = f"Fwd: {subject}"
        recipients = [r.strip() for r in (to + ("," + cc if cc else "")).split(",") if r.strip()]
        try:
            for r in recipients:
                await asyncio.to_thread(send_email, to=r, subject=subject,
                                        body=body, in_reply_to=self.message_id)
            label = {"reply":"replied to","reply_all":"replied all to","forward":"forwarded to"}.get(self.action,"sent to")
            ok = discord.Embed(title=f"✅  Email {label} `{to}`",
                               description=f"**Subject:** {subject}\n\n{trunc(body, 400)}",
                               color=0x57F287)
            ok.set_footer(text=f"Sent from {EMAIL_ADDRESS}")
            await interaction.followup.send(embed=ok, ephemeral=True)
        except Exception as exc:
            err = discord.Embed(title="❌  Send failed",
                                description=f"```\n{exc}\n```", color=0xED4245)
            await interaction.followup.send(embed=err, ephemeral=True)
            log.exception("SMTP error: %s", exc)

    async def on_error(self, interaction, error):
        log.exception("Modal error: %s", error)
        try:    await interaction.response.send_message(f"❌ {error}", ephemeral=True)
        except: await interaction.followup.send(f"❌ {error}", ephemeral=True)


# ── Compose (new email with template) ─────────────────────────

class ComposeNewModal(discord.ui.Modal):
    def __init__(self, contact: dict, template: dict):
        super().__init__(title=f"✉️  Email {trunc(contact['name'], 30)}")
        self.contact = contact

        self.order_id_input = discord.ui.TextInput(
            label       = "Order ID",
            placeholder = "e.g. ORD-20240403-001",
            required    = False,
            max_length  = 64,
        )
        self.add_item(self.order_id_input)

        self.subject_input = discord.ui.TextInput(
            label   = "Subject",
            default = template["subject"],
            required= True,
            max_length = 200,
        )
        self.add_item(self.subject_input)

        self.body_input = discord.ui.TextInput(
            label   = "Message Body",
            style   = discord.TextStyle.paragraph,
            default = template["body"],
            required= True,
            max_length = 2000,
        )
        self.add_item(self.body_input)

    async def on_submit(self, interaction: discord.Interaction):
        await interaction.response.defer(ephemeral=True)
        order_id = self.order_id_input.value.strip() or "N/A"
        subject  = self.subject_input.value.replace("#{order_id}", order_id)
        body     = self.body_input.value.replace("#{order_id}", order_id)
        to       = self.contact["email"]
        try:
            await asyncio.to_thread(send_email, to=to, subject=subject, body=body)
            ok = discord.Embed(
                title       = f"✅  Email sent to {self.contact['name']}",
                description = f"**To:** {to}\n**Subject:** {subject}\n\n{trunc(body, 400)}",
                color       = 0x57F287,
            )
            ok.add_field(name="📦  Order ID", value=order_id)
            ok.set_footer(text=f"Sent from {EMAIL_ADDRESS}")
            await interaction.followup.send(embed=ok, ephemeral=True)
        except Exception as exc:
            err = discord.Embed(title="❌  Send failed",
                                description=f"```\n{exc}\n```", color=0xED4245)
            await interaction.followup.send(embed=err, ephemeral=True)
            log.exception("SMTP error: %s", exc)

    async def on_error(self, interaction, error):
        log.exception("ComposeNewModal error: %s", error)
        try:    await interaction.response.send_message(f"❌ {error}", ephemeral=True)
        except: await interaction.followup.send(f"❌ {error}", ephemeral=True)


# ── Add contact ────────────────────────────────────────────────

class AddContactModal(discord.ui.Modal):
    def __init__(self, bot_ref):
        super().__init__(title="➕  Add Contact")
        self.bot_ref = bot_ref

        self.name_input = discord.ui.TextInput(
            label="Display Name", placeholder="John Smith",
            required=False, max_length=100)
        self.add_item(self.name_input)

        self.email_input = discord.ui.TextInput(
            label="Email Address", placeholder="john@example.com",
            required=True, max_length=200)
        self.add_item(self.email_input)

    async def on_submit(self, interaction: discord.Interaction):
        await interaction.response.defer(ephemeral=True)
        data  = load_data()
        name  = self.name_input.value.strip()
        email_addr = self.email_input.value.strip()

        if not re.match(r"[^@]+@[^@]+\.[^@]+", email_addr):
            await interaction.followup.send("❌  That doesn't look like a valid email address.", ephemeral=True)
            return

        added = upsert_contact(data, name, email_addr)
        if added:
            await self.bot_ref.refresh_compose_panel(data)
            await interaction.followup.send(
                f"✅  **{name or email_addr}** added to contacts.", ephemeral=True)
        else:
            await interaction.followup.send(
                f"ℹ️  `{email_addr}` is already in the contact list.", ephemeral=True)

    async def on_error(self, interaction, error):
        log.exception("AddContactModal error: %s", error)
        try:    await interaction.response.send_message(f"❌ {error}", ephemeral=True)
        except: await interaction.followup.send(f"❌ {error}", ephemeral=True)


# ── Edit template ──────────────────────────────────────────────

class EditTemplateModal(discord.ui.Modal):
    def __init__(self, bot_ref, template: dict):
        super().__init__(title="✏️  Edit Email Template")
        self.bot_ref = bot_ref

        self.subject_input = discord.ui.TextInput(
            label="Subject  (use #{order_id} as placeholder)",
            default=template["subject"], required=True, max_length=200)
        self.add_item(self.subject_input)

        self.body_input = discord.ui.TextInput(
            label="Body  (use #{order_id} as placeholder)",
            style=discord.TextStyle.paragraph,
            default=trunc(template["body"], 1800),
            required=True, max_length=2000)
        self.add_item(self.body_input)

    async def on_submit(self, interaction: discord.Interaction):
        await interaction.response.defer(ephemeral=True)
        data = load_data()
        data["template"]["subject"] = self.subject_input.value
        data["template"]["body"]    = self.body_input.value
        save_data(data)
        await self.bot_ref.refresh_compose_panel(data)
        await interaction.followup.send("✅  Template updated!", ephemeral=True)

    async def on_error(self, interaction, error):
        log.exception("EditTemplateModal error: %s", error)
        try:    await interaction.response.send_message(f"❌ {error}", ephemeral=True)
        except: await interaction.followup.send(f"❌ {error}", ephemeral=True)


# ── Remove contact (second select) ────────────────────────────

class RemoveContactSelect(discord.ui.Select):
    def __init__(self, contacts: list, bot_ref):
        self.bot_ref = bot_ref
        options = [
            discord.SelectOption(
                label=trunc(c["name"] or c["email"], 25),
                value=c["email"],
                description=trunc(c["email"], 50),
                emoji="🗑️",
            )
            for c in contacts[:25]
        ]
        super().__init__(placeholder="Select contact to remove…",
                         min_values=1, max_values=1, options=options)

    async def callback(self, interaction: discord.Interaction):
        await interaction.response.defer(ephemeral=True)
        data    = load_data()
        removed = remove_contact(data, self.values[0])
        if removed:
            await self.bot_ref.refresh_compose_panel(data)
            await interaction.followup.send(f"✅  `{self.values[0]}` removed.", ephemeral=True)
        else:
            await interaction.followup.send("ℹ️  Contact not found.", ephemeral=True)


class RemoveContactView(discord.ui.View):
    def __init__(self, contacts, bot_ref):
        super().__init__(timeout=60)
        self.add_item(RemoveContactSelect(contacts, bot_ref))


# ═══════════════════════════════════════════════════════════════
#  Inbox dropdown
# ═══════════════════════════════════════════════════════════════

class InboxActionSelect(discord.ui.Select):
    def __init__(self, meta: dict):
        self.meta = meta
        super().__init__(
            placeholder="⚡  Choose an action…",
            min_values=1, max_values=1,
            options=[
                discord.SelectOption(label="Reply", value="reply",
                    description=trunc(f"Reply to {meta['from_addr']}", 50), emoji="↩️"),
                discord.SelectOption(label="Reply All", value="reply_all",
                    description="Reply to sender + all recipients", emoji="↩️"),
                discord.SelectOption(label="Forward", value="forward",
                    description="Forward to someone else", emoji="➡️"),
            ],
        )

    async def callback(self, interaction: discord.Interaction):
        action  = self.values[0]
        subject = self.meta["subject"]
        if action in ("reply", "reply_all") and not subject.lower().startswith("re:"):
            subject = "Re: " + subject
        modal = InboxReplyModal(
            action=action, to=self.meta["from_addr"], subject=subject,
            cc=self.meta["cc"], message_id=self.meta["message_id"],
            original_body=self.meta["body"])
        await interaction.response.send_modal(modal)


class InboxView(discord.ui.View):
    def __init__(self, meta: dict):
        super().__init__(timeout=None)
        self.add_item(InboxActionSelect(meta))


# ═══════════════════════════════════════════════════════════════
#  Compose panel dropdown  (contacts + management options)
# ═══════════════════════════════════════════════════════════════

MGMT_ADD     = "__add__"
MGMT_EDIT    = "__edit__"
MGMT_REMOVE  = "__remove__"

class ComposeSelect(discord.ui.Select):
    def __init__(self, contacts: list, template: dict, bot_ref):
        self.template = template
        self.bot_ref  = bot_ref

        # Reserve 3 slots for management options → max 22 contacts
        contact_opts = [
            discord.SelectOption(
                label       = trunc(c["name"] or c["email"], 25),
                value       = c["email"],
                description = trunc(c["email"], 50),
                emoji       = "📧",
            )
            for c in contacts[:22]
        ]

        mgmt_opts = [
            discord.SelectOption(label="Add Contact",   value=MGMT_ADD,
                                 description="Add a new contact to the list",   emoji="➕"),
            discord.SelectOption(label="Edit Template", value=MGMT_EDIT,
                                 description="Edit the default email template", emoji="✏️"),
            discord.SelectOption(label="Remove Contact",value=MGMT_REMOVE,
                                 description="Remove a contact from the list",  emoji="🗑️"),
        ]

        placeholder = "✉️  Select a contact to email…" if contacts else "📋  No contacts yet — use ➕ Add Contact"

        super().__init__(
            placeholder=placeholder,
            min_values=1, max_values=1,
            options=contact_opts + mgmt_opts,
        )

    async def callback(self, interaction: discord.Interaction):
        choice = self.values[0]
        data   = load_data()

        if choice == MGMT_ADD:
            await interaction.response.send_modal(AddContactModal(self.bot_ref))

        elif choice == MGMT_EDIT:
            await interaction.response.send_modal(
                EditTemplateModal(self.bot_ref, data["template"]))

        elif choice == MGMT_REMOVE:
            if not data["contacts"]:
                await interaction.response.send_message(
                    "ℹ️  No contacts to remove.", ephemeral=True)
                return
            view = RemoveContactView(data["contacts"], self.bot_ref)
            await interaction.response.send_message(
                "Select a contact to remove:", view=view, ephemeral=True)

        else:
            # A real contact was selected — open compose modal
            contact = next((c for c in data["contacts"] if c["email"].lower() == choice.lower()),
                           {"name": choice, "email": choice})
            await interaction.response.send_modal(
                ComposeNewModal(contact, data["template"]))


class ComposeView(discord.ui.View):
    def __init__(self, contacts: list, template: dict, bot_ref):
        super().__init__(timeout=None)
        self.add_item(ComposeSelect(contacts, template, bot_ref))


# ═══════════════════════════════════════════════════════════════
#  Bot
# ═══════════════════════════════════════════════════════════════

class EmailBot(discord.Client):
    def __init__(self):
        intents = discord.Intents.default()
        super().__init__(intents=intents)
        self.inbox_channel   = None
        self.compose_channel = None
        self._seen_ids: set  = set()

    async def setup_hook(self):
        self.poll_emails.start()

    async def on_ready(self):
        self.inbox_channel   = self.get_channel(INBOX_CHANNEL_ID)
        self.compose_channel = self.get_channel(COMPOSE_CHANNEL_ID)

        if self.inbox_channel is None:
            log.error("Inbox channel %d not found.", INBOX_CHANNEL_ID)
        if self.compose_channel is None:
            log.error("Compose channel %d not found.", COMPOSE_CHANNEL_ID)
        else:
            log.info("Logged in as %s", self.user)
            await self._init_compose_panel()

    # ── Compose panel ──────────────────────────────────────────

    async def _init_compose_panel(self):
        """Post the compose panel on startup, or edit the existing one."""
        data = load_data()
        msg_id = data.get("compose_message_id")

        if msg_id:
            try:
                msg = await self.compose_channel.fetch_message(msg_id)
                await self._update_compose_message(msg, data)
                log.info("Compose panel refreshed (existing message).")
                return
            except discord.NotFound:
                pass

        # Post a fresh panel
        embed = build_compose_embed(data["template"])
        view  = ComposeView(data["contacts"], data["template"], self)
        msg   = await self.compose_channel.send(embed=embed, view=view)
        data["compose_message_id"] = msg.id
        save_data(data)
        log.info("Compose panel posted (new message id=%d).", msg.id)

    async def refresh_compose_panel(self, data: dict):
        """Called after contacts or template change to update the panel."""
        if self.compose_channel is None:
            return
        msg_id = data.get("compose_message_id")
        if not msg_id:
            return
        try:
            msg = await self.compose_channel.fetch_message(msg_id)
            await self._update_compose_message(msg, data)
        except Exception as exc:
            log.exception("Failed to refresh compose panel: %s", exc)

    async def _update_compose_message(self, msg: discord.Message, data: dict):
        embed = build_compose_embed(data["template"])
        view  = ComposeView(data["contacts"], data["template"], self)
        await msg.edit(embed=embed, view=view)

    # ── IMAP polling ───────────────────────────────────────────

    @tasks.loop(seconds=POLL_INTERVAL)
    async def poll_emails(self):
        if self.inbox_channel is None:
            return
        try:
            raws = await asyncio.to_thread(self._fetch_unseen)
            for raw in raws:
                msg = email.message_from_bytes(raw)
                await self._post_inbox_email(msg)
        except Exception as exc:
            log.exception("Polling error: %s", exc)

    @poll_emails.before_loop
    async def before_poll(self):
        await self.wait_until_ready()

    def _fetch_unseen(self) -> list:
        conn = (imaplib.IMAP4_SSL if IMAP_SSL else imaplib.IMAP4)(IMAP_SERVER, IMAP_PORT)
        conn.login(EMAIL_ADDRESS, EMAIL_PASSWORD)
        conn.select(MAILBOX)
        status, data = conn.search(None, "UNSEEN")
        if status != "OK" or not data[0]:
            conn.logout(); return []
        raws = []
        for uid in data[0].split():
            st, md = conn.fetch(uid, "(RFC822)")
            if st == "OK" and md and md[0]:
                raw = md[0][1]
                if isinstance(raw, bytes): raws.append(raw)
            conn.store(uid, "+FLAGS", "\\Seen")
        conn.logout()
        return raws

    async def _post_inbox_email(self, msg: email.message.Message):
        message_id = msg.get("Message-ID", "").strip()
        if message_id and message_id in self._seen_ids: return
        if message_id: self._seen_ids.add(message_id)

        raw_from = decode_mime(msg.get("From", ""))
        raw_to   = decode_mime(msg.get("To",   ""))
        raw_cc   = decode_mime(msg.get("Cc",   ""))
        subject  = decode_mime(msg.get("Subject", "(no subject)"))
        body     = get_body(msg)
        _, sender_addr = parseaddr(raw_from)
        sender_name, _ = parseaddr(raw_from)
        sender_name = sender_name.strip() or sender_addr

        # Auto-add sender to contact list
        data  = load_data()
        added = upsert_contact(data, sender_name, sender_addr)
        if added:
            await self.refresh_compose_panel(data)

        meta = {
            "from_addr":  sender_addr,
            "to":         raw_to,
            "cc":         raw_cc,
            "subject":    subject,
            "message_id": message_id,
            "body":       body,
        }
        embed = build_inbox_embed(msg)
        view  = InboxView(meta)
        await self.inbox_channel.send(embed=embed, view=view)
        log.info("Posted inbox email: %s", subject)


# ═══════════════════════════════════════════════════════════════
#  Entry point
# ═══════════════════════════════════════════════════════════════

if __name__ == "__main__":
    bot = EmailBot()
    bot.run(BOT_TOKEN)