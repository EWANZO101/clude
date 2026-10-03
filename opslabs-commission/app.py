from flask import Flask, render_template, request, redirect, url_for, session, flash, jsonify, abort, make_response, send_from_directory
from flask_sqlalchemy import SQLAlchemy
from werkzeug.middleware.proxy_fix import ProxyFix
from werkzeug.security import check_password_hash
from datetime import datetime, timedelta
import uuid, json, os, hashlib, requests, io, base64, re, hmac, time, threading

from dotenv import load_dotenv
load_dotenv()

import platform_client

app = Flask(__name__)
app.secret_key = os.environ['FLASK_SECRET_KEY']
# nginx terminates TLS and sits in front of gunicorn — without this, url_for(_external=True)
# (used for the Trello OAuth callback URL) would generate http:// instead of https://.
app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1, x_host=1)

# Cookies only ever travel over the nginx HTTPS front door, are never needed by JS, and
# shouldn't be sent on cross-site requests (the admin/security sessions have no reason to).
app.config['SESSION_COOKIE_SECURE']   = True
app.config['SESSION_COOKIE_HTTPONLY'] = True
app.config['SESSION_COOKIE_SAMESITE'] = 'Lax'

# Recorded at startup — used to invalidate captcha lockouts issued before a restart
SERVER_START_TIME = datetime.utcnow()
CAPTCHA_LOCKOUT_SECS = 300  # 5 minutes

# ─── DATABASE PATH ────────────────────────────────────────────────────────────
# Stored OUTSIDE the app folder so redeployments never wipe your data.
# Change DB_DIR if you want the database somewhere else on your server.
DB_DIR = os.path.join(os.path.expanduser('~'), 'opslabs_commission_data')
os.makedirs(DB_DIR, exist_ok=True)
DB_PATH = os.path.join(DB_DIR, 'commissions.db')
app.config['SQLALCHEMY_DATABASE_URI'] = f'sqlite:///{DB_PATH}'

# ─── JINJA FILTERS ────────────────────────────────────────────────────────────
import json as _json
@app.template_filter('from_json')
def from_json_filter(value):
    try:
        return _json.loads(value)
    except Exception:
        return []
app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False
app.config['PERMANENT_SESSION_LIFETIME'] = timedelta(days=30)

db = SQLAlchemy(app)

# ─── MODELS ───────────────────────────────────────────────────────────────────

class SiteSettings(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    commissions_open = db.Column(db.Boolean, default=True)
    discord_webhook = db.Column(db.String(500), default='')
    discord_webhook_status = db.Column(db.String(500), default='')  # separate webhook for order status updates
    discord_webhook_tickets = db.Column(db.String(500), default='')  # separate webhook for ticket activity
    discord_bot_token       = db.Column(db.String(200), default='')   # Bot token from Discord Dev Portal
    discord_ticket_channel  = db.Column(db.String(100), default='')   # Channel ID for ticket threads
    discord_bot_secret      = db.Column(db.String(100), default='')   # Shared secret (bot ↔ site)
    cashapp_api_key = db.Column(db.String(200), default='')
    closed_message = db.Column(db.String(500), default='Commissions are currently closed. Please check back later.')
    reopen_date = db.Column(db.String(100), default='')   # US format: MM/DD/YYYY HH:MM AM/PM
    close_date         = db.Column(db.String(100), default='')   # US format: MM/DD/YYYY HH:MM AM/PM
    max_ref_images_default = db.Column(db.Integer, default=3)  # global default for ref image uploads
    banner_enabled  = db.Column(db.Boolean, default=False)
    banner_text     = db.Column(db.String(500), default='')
    banner_style    = db.Column(db.String(20),  default='info')  # info | success | warning | danger
    banner_link     = db.Column(db.String(300), default='')
    banner_link_text= db.Column(db.String(100), default='')

    # ── Integrations, editable from /admin/settings so no .env edit is ever needed
    # after initial setup (only the bootstrap auth secrets in .env require that,
    # since you need them to reach this settings page in the first place). ──
    site_url = db.Column(db.String(300), default='')  # e.g. https://your-domain.example

    trello_api_key    = db.Column(db.String(200), default='')
    trello_api_secret = db.Column(db.String(200), default='')
    # Encrypts Trello OAuth tokens at rest — generated automatically the first time
    # it's needed (see trello_encryption_key()), never entered by hand.
    trello_encryption_key = db.Column(db.String(200), default='')

    discord_panel_channel    = db.Column(db.String(100), default='')  # channel with the "Open a Ticket" button
    discord_bot_internal_url = db.Column(db.String(300), default='http://127.0.0.1:5900')  # site → bot HTTP API

    discord_client_id     = db.Column(db.String(100), default='')  # Discord OAuth2 (guilds.join for "Join Discord")
    discord_client_secret = db.Column(db.String(200), default='')
    discord_guild_id      = db.Column(db.String(100), default='')

    smtp_host     = db.Column(db.String(200), default='')
    smtp_port     = db.Column(db.Integer, default=465)
    smtp_username = db.Column(db.String(200), default='')
    smtp_password = db.Column(db.String(200), default='')
    smtp_from     = db.Column(db.String(200), default='')



class DiscountCode(db.Model):
    id          = db.Column(db.Integer, primary_key=True)
    code        = db.Column(db.String(50),  unique=True, nullable=False)
    type        = db.Column(db.String(10),  default='percent')  # percent | fixed
    value       = db.Column(db.Float,       nullable=False, default=0.0)
    max_uses    = db.Column(db.Integer,     default=0)  # 0 = unlimited
    uses        = db.Column(db.Integer,     default=0)
    active      = db.Column(db.Boolean,     default=True)
    expires     = db.Column(db.String(50),  default='')  # MM/DD/YYYY or blank
    created_at  = db.Column(db.DateTime,    default=datetime.utcnow)

class Order(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    order_id = db.Column(db.String(20), unique=True, nullable=False)
    unique_link = db.Column(db.String(64), unique=True, nullable=False)
    customer_name = db.Column(db.String(200), nullable=False)
    customer_email = db.Column(db.String(200))
    customer_discord = db.Column(db.String(100))
    customer_instagram = db.Column(db.String(100))
    payment_method = db.Column(db.String(50), default='')   # 'PayPal' or 'CashApp'
    payment_username = db.Column(db.String(200), default='')  # their PayPal email or CashApp $tag
    description = db.Column(db.Text)
    commission_type = db.Column(db.String(500))
    price = db.Column(db.Float, default=0.0)
    custom_quote = db.Column(db.Boolean, default=False)
    status = db.Column(db.String(50), default='Awaiting Confirmation')
    payment_status = db.Column(db.String(50), default='Unpaid')
    eta = db.Column(db.String(100))
    notes = db.Column(db.Text)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    updated_at = db.Column(db.DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)
    form_responses = db.Column(db.Text, default='{}')  # JSON
    pin_hash = db.Column(db.String(64), nullable=True)  # SHA-256 of user-set PIN

class OrderLog(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    order_id = db.Column(db.String(20), nullable=False)
    event = db.Column(db.String(200), nullable=False)
    details = db.Column(db.Text)
    image_filename = db.Column(db.String(300), default='')     # optional WIP preview image
    customer_visible = db.Column(db.Boolean, default=True)     # False = internal note, hidden from customer
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

class CommissionRequest(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    request_id = db.Column(db.String(20), unique=True, nullable=False)
    customer_name = db.Column(db.String(200), nullable=False)
    customer_email = db.Column(db.String(200))
    customer_discord = db.Column(db.String(100))
    customer_instagram = db.Column(db.String(100))
    payment_method = db.Column(db.String(50), default='')
    payment_username = db.Column(db.String(200), default='')
    commission_type = db.Column(db.String(500))
    description = db.Column(db.Text)
    form_responses = db.Column(db.Text, default='{}')
    status = db.Column(db.String(50), default='Pending')  # Pending, Accepted, Declined
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

class Ticket(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    ticket_id = db.Column(db.String(20), unique=True, nullable=False)
    order_link = db.Column(db.String(64))
    order_id = db.Column(db.String(20))
    customer_name = db.Column(db.String(200), nullable=False)
    subject = db.Column(db.String(300))
    status = db.Column(db.String(50), default='Open')
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    expires_at = db.Column(db.DateTime)
    discord_thread_id = db.Column(db.String(100))   # Discord thread linked to this ticket

class TicketMessage(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    ticket_id = db.Column(db.String(20), nullable=False)
    sender = db.Column(db.String(50))  # 'customer' or 'admin'
    message = db.Column(db.Text, nullable=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

class LoginLog(db.Model):
    id         = db.Column(db.Integer, primary_key=True)
    ip_address = db.Column(db.String(64), nullable=False)
    user_agent = db.Column(db.String(500))
    success    = db.Column(db.Boolean, default=True)
    note       = db.Column(db.String(200))
    logged_at  = db.Column(db.DateTime, default=datetime.utcnow)

class Invoice(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    invoice_id = db.Column(db.String(20), unique=True, nullable=False)
    order_id = db.Column(db.String(20), nullable=False)
    customer_name = db.Column(db.String(200))
    amount = db.Column(db.Float, nullable=False)
    items = db.Column(db.Text, default='[]')  # JSON
    paid = db.Column(db.Boolean, default=False)
    paid_at = db.Column(db.DateTime)
    due_date = db.Column(db.String(50))
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    notes = db.Column(db.Text)

class FormField(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    field_key = db.Column(db.String(100), unique=True, nullable=False)
    label = db.Column(db.String(200), nullable=False)
    field_type = db.Column(db.String(50), default='text')  # text, textarea, select, checkbox
    required = db.Column(db.Boolean, default=False)
    options = db.Column(db.Text, default='[]')  # JSON for select options
    order_index = db.Column(db.Integer, default=0)
    active = db.Column(db.Boolean, default=True)

class CommissionType(db.Model):
    """Editable commission types stored in DB instead of hardcoded list."""
    id          = db.Column(db.Integer, primary_key=True)
    category    = db.Column(db.String(100), nullable=False)
    type_name   = db.Column(db.String(200), nullable=False)
    price       = db.Column(db.Float, nullable=False, default=0.0)
    active           = db.Column(db.Boolean, default=True)
    order_index      = db.Column(db.Integer, default=0)
    allow_ref_images = db.Column(db.Boolean, default=False)  # allow customer to upload ref images
    max_ref_images   = db.Column(db.Integer, default=3)      # max uploads for this type (0 = use global default)

class GalleryImage(db.Model):
    id          = db.Column(db.Integer, primary_key=True)
    filename    = db.Column(db.String(300), nullable=False)
    caption     = db.Column(db.String(300), default='')
    order_index = db.Column(db.Integer, default=0)
    active      = db.Column(db.Boolean, default=True)
    created_at  = db.Column(db.DateTime, default=datetime.utcnow)

class PaymentRecord(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    order_id = db.Column(db.String(20))
    invoice_id = db.Column(db.String(20))
    amount = db.Column(db.Float, nullable=False)
    method = db.Column(db.String(50), default='CashApp')
    transaction_id = db.Column(db.String(200))
    recorded_at = db.Column(db.DateTime, default=datetime.utcnow)
    notes = db.Column(db.Text)

class TrelloConnection(db.Model):
    """Single-row: the admin's connected Trello account (this site has one admin)."""
    id = db.Column(db.Integer, primary_key=True)
    status = db.Column(db.String(20), default='disconnected')  # disconnected | connected | error
    member_id = db.Column(db.String(64), default='')
    username = db.Column(db.String(200), default='')
    full_name = db.Column(db.String(200), default='')
    avatar_url = db.Column(db.String(500), default='')
    access_token = db.Column(db.Text, default='')          # encrypted at rest
    access_token_secret = db.Column(db.Text, default='')   # encrypted at rest
    workspace_id = db.Column(db.String(64), default='')
    workspace_name = db.Column(db.String(200), default='')
    board_id = db.Column(db.String(64), default='')
    board_name = db.Column(db.String(200), default='')
    list_id = db.Column(db.String(64), default='')
    list_name = db.Column(db.String(200), default='')
    ping_list_id = db.Column(db.String(64), default='')    # separate Trello list used as a "notify me" queue
    ping_list_name = db.Column(db.String(200), default='')
    ping_board_id = db.Column(db.String(64), default='')   # so the picker can restore its board dropdown
    webhook_id = db.Column(db.String(64), default='')      # Trello webhook id, for live card-move -> status sync
    webhook_callback_url = db.Column(db.String(500), default='')  # exact URL used at registration; needed to verify signatures
    connected_at = db.Column(db.DateTime)
    last_synced_at = db.Column(db.DateTime)

class PingListSubscriber(db.Model):
    """A Discord handle pulled from a card in the Trello 'ping list' (e.g. 'smmer (discord)')."""
    id = db.Column(db.Integer, primary_key=True)
    discord_username = db.Column(db.String(100), nullable=False)
    trello_card_id = db.Column(db.String(64), unique=True)
    trello_card_name = db.Column(db.String(300), default='')
    active = db.Column(db.Boolean, default=True)
    added_at = db.Column(db.DateTime, default=datetime.utcnow)
    last_notified_at = db.Column(db.DateTime)
    unsubscribe_token = db.Column(db.String(64), default='')
    welcomed = db.Column(db.Boolean, default=False)  # has the "you're on the list" DM been sent?

class TrelloCardMapping(db.Model):
    """Links one of our orders to a Trello card, so we don't re-fetch/re-ask every time."""
    id = db.Column(db.Integer, primary_key=True)
    order_id = db.Column(db.String(20), nullable=False, index=True)
    trello_card_id = db.Column(db.String(64), nullable=False)
    trello_board_id = db.Column(db.String(64), default='')
    trello_list_id = db.Column(db.String(64), default='')
    trello_card_name = db.Column(db.String(300), default='')
    trello_card_url = db.Column(db.String(500), default='')
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    last_synced_at = db.Column(db.DateTime, default=datetime.utcnow)

class OrderFinalImage(db.Model):
    """A finished-artwork file for an order. Only shown to the customer once the order is Done."""
    id = db.Column(db.Integer, primary_key=True)
    order_id = db.Column(db.String(20), nullable=False, index=True)
    filename = db.Column(db.String(300), nullable=False)
    uploaded_at = db.Column(db.DateTime, default=datetime.utcnow)

class TrelloListStatusMap(db.Model):
    """Admin-configured mapping: moving a card into this Trello list sets the order's status."""
    id = db.Column(db.Integer, primary_key=True)
    trello_list_id = db.Column(db.String(64), unique=True, nullable=False)
    trello_list_name = db.Column(db.String(200), default='')
    order_status = db.Column(db.String(50), default='')  # '' = unmapped, don't touch status

class CommissionNotifySubscriber(db.Model):
    """A visitor who asked to be told when commissions reopen, via Discord DM or email."""
    id = db.Column(db.Integer, primary_key=True)
    method = db.Column(db.String(20), nullable=False)   # 'discord' or 'email'
    contact = db.Column(db.String(200), nullable=False)
    discord_user_id = db.Column(db.String(32), default='')  # set when joined via the OAuth join-link
    confirmed = db.Column(db.Boolean, default=False)    # emails need to confirm; discord doesn't
    confirm_token = db.Column(db.String(64), default='')
    unsubscribe_token = db.Column(db.String(64), default='')
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    notified_at = db.Column(db.DateTime)

# ─── HELPERS ──────────────────────────────────────────────────────────────────

ORDER_STATUSES = ['Awaiting Confirmation', 'Accepted', 'Declined', 'Pending', 'In Progress', 'Done']
PAYMENT_STATUSES = ['Unpaid', 'Pending', 'Paid']

# Linear progress-bar sequences shown to customers. 'Declined' is a dead-end,
# not a step, so it's excluded here and given its own display instead.
ORDER_PROGRESS_STEPS   = ['Awaiting Confirmation', 'Accepted', 'Pending', 'In Progress', 'Done']
PAYMENT_PROGRESS_STEPS = ['Unpaid', 'Pending', 'Paid']

PRESET_COMMISSIONS = [
    {'category': 'Sketch', 'type': 'Sketch - Headshot', 'price': 5},
    {'category': 'Sketch', 'type': 'Sketch - Halfbody', 'price': 10},
    {'category': 'Sketch', 'type': 'Sketch - Fullbody', 'price': 15},
    {'category': 'Flat Color', 'type': 'Flat Color - Headshot', 'price': 15},
    {'category': 'Flat Color', 'type': 'Flat Color - Halfbody', 'price': 20},
    {'category': 'Flat Color', 'type': 'Flat Color - Fullbody', 'price': 35},
    {'category': 'Full Color', 'type': 'Full Color - Headshot', 'price': 20},
    {'category': 'Full Color', 'type': 'Full Color - Halfbody', 'price': 30},
    {'category': 'Full Color', 'type': 'Full Color - Fullbody', 'price': 40},
    {'category': 'Doodle Page', 'type': 'Sketchy Doodle Page', 'price': 35},
    {'category': 'Doodle Page', 'type': 'Clean Doodle Page', 'price': 40},
    {'category': 'Reference Sheet', 'type': 'Detailed Reference Sheet', 'price': 60},
    {'category': 'Reference Sheet', 'type': 'Simple Reference Sheet', 'price': 45},
    {'category': 'Reference Sheet Extras', 'type': 'Character Outfits', 'price': 10},
    {'category': 'Reference Sheet Extras', 'type': 'Personal Items', 'price': 6},
]

def gen_id(prefix='ORD', length=6):
    return f"{prefix}-{uuid.uuid4().hex[:length].upper()}"

def gen_link():
    return uuid.uuid4().hex

def get_presets():
    """Return active commission types from DB as list of dicts."""
    types = CommissionType.query.filter_by(active=True).order_by(
        CommissionType.category, CommissionType.order_index, CommissionType.id
    ).all()
    return [{'category': t.category, 'type': t.type_name, 'price': t.price, 'id': t.id} for t in types]

def is_admin():
    return session.get('admin_logged_in') is True

def add_log(order_id, event, details=None):
    log = OrderLog(order_id=order_id, event=event, details=details)
    db.session.add(log)
    db.session.commit()

def send_webhook(content, embeds=None, webhook_type='general'):
    """Send a Discord webhook.
    webhook_type='general'  → uses discord_webhook (new orders, payments, etc.)
    webhook_type='status'   → uses discord_webhook_status (order status updates)
    webhook_type='ticket'   → uses discord_webhook_tickets (all ticket activity)
    Falls back to discord_webhook if the specific URL is not set.
    """
    settings = SiteSettings.query.first()
    if not settings:
        return
    if webhook_type == 'status' and settings.discord_webhook_status:
        url = settings.discord_webhook_status
    elif webhook_type == 'ticket' and settings.discord_webhook_tickets:
        url = settings.discord_webhook_tickets
    else:
        url = settings.discord_webhook
    if not url:
        return
    payload = {'content': content}
    if embeds:
        payload['embeds'] = embeds
    try:
        requests.post(url, json=payload, timeout=5)
    except Exception:
        pass

def _discord_rest(method, path, bot_token, **kwargs):
    """Low-level Discord REST API v10 helper."""
    url = f"https://discord.com/api/v10{path}"
    headers = {
        "Authorization": f"Bot {bot_token}",
        "Content-Type":  "application/json",
    }
    try:
        resp = requests.request(method, url, headers=headers, timeout=8, **kwargs)
        resp.raise_for_status()
        return resp.json()
    except Exception as exc:
        print(f"[Discord REST] {method} {path} failed: {exc}")
        return None

def _create_discord_thread(channel_id, ticket, first_message, bot_token):
    """Create a public thread in channel_id for this ticket. Returns thread ID or None."""
    if not channel_id or not bot_token:
        return None
    name = f"🎫 {ticket.ticket_id} — {(ticket.subject or 'Support')[:80]}"
    thread = _discord_rest(
        "POST", f"/channels/{channel_id}/threads", bot_token,
        json={"name": name, "type": 11, "auto_archive_duration": 10080},
    )
    if not thread:
        return None
    thread_id = thread.get("id")
    if not thread_id:
        return None
    intro = (
        f"**🎫 Ticket — #{ticket.ticket_id}**\n"
        f"**Customer:** {ticket.customer_name}\n"
        f"**Subject:** {ticket.subject or '(none)'}\n"
        f"**Order ID:** {ticket.order_id or 'N/A'}\n"
        f"{'─'*36}\n"
        f"{first_message[:1800]}\n"
        f"{'─'*36}\n"
        f"*Reply here to respond. Replies sync automatically to the website.*"
    )
    _discord_rest("POST", f"/channels/{thread_id}/messages", bot_token, json={"content": intro})
    return thread_id

def _send_to_discord_thread(thread_id, content, bot_token):
    """Post a message to an existing Discord thread."""
    if not thread_id or not bot_token:
        return
    _discord_rest("POST", f"/channels/{thread_id}/messages", bot_token,
                  json={"content": content[:2000]})

def notify_contact_bot(req, order):
    """
    POST the commission request data to the contact_bot HTTP server
    so it can display it in Discord channel 1489625649067855972
    with a reply/accept/decline dropdown.
    Runs in a background thread so it never blocks the form response.
    """
    try:
        form_data = json.loads(req.form_responses or '{}')
    except Exception:
        form_data = {}

    payload = {
        'request_id':         req.request_id,
        'order_id':           order.order_id if order else '',
        'order_link':         order.unique_link if order else '',
        'customer_name':      req.customer_name or '',
        'customer_email':     req.customer_email or '',
        'customer_discord':   req.customer_discord or '',
        'customer_instagram': req.customer_instagram or '',
        'commission_type':    req.commission_type or '',
        'description':        req.description or '',
        'payment_method':     req.payment_method or '',
        'form_responses':     form_data,
    }

    import threading
    def _post():
        try:
            requests.post('http://127.0.0.1:5011/notify', json=payload, timeout=3)
        except Exception:
            pass   # never crash the form submission if bot is down
    threading.Thread(target=_post, daemon=True).start()

def auto_create_invoice(order):
    """Auto-create a draft invoice when an order is created.
    If an unpaid invoice already exists for this order, update its amount instead.
    """
    # Check if an unpaid invoice already exists
    existing = Invoice.query.filter_by(order_id=order.order_id, paid=False).first()
    amount = order.price or 0.0
    desc = order.commission_type or 'Commission'
    items = [{'desc': desc, 'amount': amount}]

    if existing:
        # Update the existing draft with the latest price/type
        existing.amount = amount
        existing.items = json.dumps(items)
        existing.customer_name = order.customer_name
        db.session.commit()
        return existing

    inv = Invoice(
        invoice_id=gen_id('INV'),
        order_id=order.order_id,
        customer_name=order.customer_name,
        amount=amount,
        items=json.dumps(items),
        paid=False,
        notes=f'Auto-generated invoice for order {order.order_id}'
    )
    db.session.add(inv)
    db.session.commit()
    add_log(order.order_id, 'Invoice Created', f'Auto-generated invoice {inv.invoice_id} for ${amount:.2f}')
    return inv

def parse_us_datetime(s):
    """Parse a US-format datetime string like '03/25/2026 09:00 PM' into a UTC datetime."""
    if not s:
        return None
    for fmt in ('%m/%d/%Y %I:%M %p', '%m/%d/%Y %H:%M', '%m/%d/%Y'):
        try:
            return datetime.strptime(s.strip(), fmt)
        except ValueError:
            continue
    return None

def check_commission_schedule():
    """Auto-open or auto-close commissions based on scheduled dates."""
    s = SiteSettings.query.first()
    if not s:
        return
    now = datetime.utcnow()
    changed = False
    # Auto-close
    if s.close_date and not s.commissions_open is False:
        close_dt = parse_us_datetime(s.close_date)
        if close_dt and now >= close_dt and s.commissions_open:
            s.commissions_open = False
            changed = True
    # Auto-open
    if s.reopen_date:
        reopen_dt = parse_us_datetime(s.reopen_date)
        if reopen_dt and now >= reopen_dt and not s.commissions_open:
            s.commissions_open = True
            s.reopen_date = ''  # Clear once triggered
            db.session.commit()
            notify_ping_list_commissions_open()
            return
    if changed:
        db.session.commit()

def get_settings():
    s = SiteSettings.query.first()
    if not s:
        s = SiteSettings()
        db.session.add(s)
        db.session.commit()
    check_commission_schedule()
    return s

# ─── TRELLO INTEGRATION ─────────────────────────────────────────────────────
# OAuth1.0a "three-legged" flow: the API key/secret never touch the browser,
# only the backend signs the request-token/access-token exchange. The resulting
# access token is then used the simple way (key+token query params) for every
# other Trello API call, per Trello's own REST API auth model.
def trello_api_key():
    return get_settings().trello_api_key.strip()

def trello_api_secret():
    return get_settings().trello_api_secret.strip()

TRELLO_REQUEST_TOKEN_URL = 'https://trello.com/1/OAuthGetRequestToken'
TRELLO_AUTHORIZE_URL     = 'https://trello.com/1/OAuthAuthorizeToken'
TRELLO_ACCESS_TOKEN_URL  = 'https://trello.com/1/OAuthGetAccessToken'
TRELLO_API_BASE          = 'https://api.trello.com/1'

def trello_configured():
    return bool(trello_api_key() and trello_api_secret())

def _trello_fernet():
    from cryptography.fernet import Fernet
    s = get_settings()
    if not s.trello_encryption_key:
        # Generated once, on first use, and persisted — never entered by hand.
        s.trello_encryption_key = Fernet.generate_key().decode()
        db.session.commit()
    return Fernet(s.trello_encryption_key.encode())

def trello_encrypt(raw):
    if not raw:
        return ''
    return _trello_fernet().encrypt(raw.encode()).decode()

def trello_decrypt(enc):
    if not enc:
        return ''
    try:
        return _trello_fernet().decrypt(enc.encode()).decode()
    except Exception:
        return ''

def get_trello_connection():
    c = TrelloConnection.query.first()
    if not c:
        c = TrelloConnection()
        db.session.add(c)
        db.session.commit()
    return c

def trello_api_get(path, params=None):
    """Read-only Trello call using the admin's stored token. None on any failure."""
    conn = get_trello_connection()
    token = trello_decrypt(conn.access_token)
    if not trello_configured() or not token:
        return None
    p = {'key': trello_api_key(), 'token': token}
    if params:
        p.update(params)
    try:
        r = requests.get(f'{TRELLO_API_BASE}/{path}', params=p, timeout=10)
        if r.status_code == 401:
            conn.status = 'error'
            db.session.commit()
            return None
        r.raise_for_status()
        return r.json()
    except Exception:
        return None

def trello_api_write(method, path, params=None):
    """POST/PUT/DELETE Trello call using the admin's stored token. None on any failure."""
    conn = get_trello_connection()
    token = trello_decrypt(conn.access_token)
    if not trello_configured() or not token:
        return None
    p = {'key': trello_api_key(), 'token': token}
    if params:
        p.update(params)
    try:
        r = requests.request(method, f'{TRELLO_API_BASE}/{path}', params=p, timeout=10)
        if r.status_code == 401:
            conn.status = 'error'
            db.session.commit()
            return None
        r.raise_for_status()
        return r.json() if r.text else {}
    except Exception:
        return None

# ─── PING LIST (Trello "notify me" list → Discord DM) ──────────────────────
# Cards named e.g. "smmer (discord)" or "smmer - discord" become subscribers.
_DISCORD_HANDLE_PATTERNS = [
    re.compile(r'^(.*?)\s*\(\s*discord\s*\)\s*$', re.IGNORECASE),
    re.compile(r'^(.*?)\s*[-–—]\s*discord\s*$', re.IGNORECASE),
]

def parse_discord_username(card_name):
    name = (card_name or '').strip()
    for pat in _DISCORD_HANDLE_PATTERNS:
        m = pat.match(name)
        if m:
            handle = m.group(1).strip().lstrip('@')
            if handle:
                return handle
    return None

def DISCORD_BOT_INTERNAL_URL():
    return (get_settings().discord_bot_internal_url or 'http://127.0.0.1:5900').rstrip('/')

# ─── DISCORD OAUTH2 (join-link) ─────────────────────────────────────────────
def DISCORD_CLIENT_ID():
    return get_settings().discord_client_id

def DISCORD_CLIENT_SECRET():
    return get_settings().discord_client_secret

def DISCORD_GUILD_ID():
    return get_settings().discord_guild_id

def discord_join_configured():
    return bool(DISCORD_CLIENT_ID() and DISCORD_CLIENT_SECRET() and DISCORD_GUILD_ID())

# ─── OUTGOING EMAIL (SMTP) ──────────────────────────────────────────────────
import smtplib
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart

def SMTP_HOST():
    return get_settings().smtp_host

def SMTP_PORT():
    return get_settings().smtp_port or 465

def SMTP_USERNAME():
    return get_settings().smtp_username

def SMTP_PASSWORD():
    return get_settings().smtp_password

def SMTP_FROM():
    s = get_settings()
    return s.smtp_from or s.smtp_username

def email_configured():
    return bool(SMTP_HOST() and SMTP_USERNAME() and SMTP_PASSWORD())

def send_email(to_addr, subject, text_body, html_body=None):
    if not email_configured():
        print(f'[Email] SMTP not configured — skipped send to {to_addr}')
        return False
    if html_body:
        msg = MIMEMultipart('alternative')
        msg.attach(MIMEText(text_body, 'plain'))
        msg.attach(MIMEText(html_body, 'html'))
    else:
        msg = MIMEText(text_body)
    msg['Subject'] = subject
    msg['From'] = SMTP_FROM()
    msg['To'] = to_addr
    try:
        with smtplib.SMTP_SSL(SMTP_HOST(), SMTP_PORT(), timeout=15) as server:
            server.login(SMTP_USERNAME(), SMTP_PASSWORD())
            server.sendmail(SMTP_FROM(), [to_addr], msg.as_string())
        return True
    except Exception as exc:
        print(f'[Email] send to {to_addr} failed: {exc}')
        return False

def branded_email_html(heading, body_html, cta_url=None, cta_label=None, unsubscribe_url=None):
    cta_block = ''
    if cta_url and cta_label:
        cta_block = f'''
        <tr><td style="padding:8px 28px 28px;text-align:center;">
          <a href="{cta_url}" style="background:#a855f7;color:#ffffff;text-decoration:none;
             padding:12px 30px;border-radius:8px;font-weight:600;display:inline-block;
             font-family:Georgia,serif;">{cta_label}</a>
        </td></tr>'''
    unsub_block = ''
    if unsubscribe_url:
        unsub_block = (
            f'<p style="font-size:12px;color:#9694a8;margin:20px 0 0;">'
            f'Don\'t want these emails? <a href="{unsubscribe_url}" style="color:#9694a8;">Unsubscribe</a></p>'
        )
    return f'''<!DOCTYPE html>
<html><body style="margin:0;padding:0;background:#f4f2f7;">
<table width="100%" cellpadding="0" cellspacing="0" style="background:#f4f2f7;padding:32px 16px;">
<tr><td align="center">
<table width="480" cellpadding="0" cellspacing="0" style="background:#ffffff;border-radius:12px;
       overflow:hidden;border:1px solid #e5e2ec;max-width:480px;">
<tr><td style="background:linear-gradient(135deg,#a855f7,#f59e0b);padding:28px;text-align:center;">
  <div style="font-size:22px;letter-spacing:0.3em;margin-bottom:8px;">&#10022; &#10022; &#10022;</div>
  <div style="color:#ffffff;font-size:21px;font-weight:700;font-family:Georgia,serif;letter-spacing:0.03em;">
    Cioda's Commissions
  </div>
</td></tr>
<tr><td style="padding:32px 28px 8px;font-family:Georgia,serif;">
  <h1 style="font-size:19px;color:#17171b;margin:0 0 14px;">{heading}</h1>
  <div style="font-size:15px;color:#3d3d4d;line-height:1.65;">{body_html}</div>
</td></tr>
{cta_block}
<tr><td style="padding:0 28px 26px;font-family:Georgia,serif;">
  {unsub_block}
</td></tr>
</table>
</td></tr>
</table>
</body></html>'''

def _send_discord_dm(settings, username, message, user_id=None):
    try:
        r = requests.post(f'{DISCORD_BOT_INTERNAL_URL()}/internal/dm', json={
            'secret': settings.discord_bot_secret,
            'username': username,
            'user_id': user_id or '',
            'message': message,
        }, timeout=10)
        data = r.json() if r.ok else {}
        return bool(data.get('sent'))
    except Exception:
        return False

def send_discord_welcome_dm(settings, username, unsubscribe_url, user_id=None):
    """Sends the branded 'you're on the list' embed + a link-style Unsubscribe button.
    Pass user_id when known (e.g. from the OAuth join-link) — it's far more reliable
    than a username search, which can fail if their name changed since being recorded."""
    try:
        r = requests.post(f'{DISCORD_BOT_INTERNAL_URL()}/internal/dm', json={
            'secret': settings.discord_bot_secret,
            'username': username,
            'user_id': user_id or '',
            'message': "Thanks for stopping by Cioda's Commissions! You're on the list for reopening alerts.",
            'embed': {
                'title': "🎨 You're on the list!",
                'description': (
                    "Thanks for stopping by **Cioda's Commissions**!\n\n"
                    "You'll get a message right here the moment commissions open again."
                ),
                'color': 0xA855F7,
                'footer': "Cioda's Commissions",
            },
            'unsubscribe_url': unsubscribe_url,
            'unsubscribe_label': '🔕 Unsubscribe',
        }, timeout=10)
        data = r.json() if r.ok else {}
        return bool(data.get('sent'))
    except Exception:
        return False

def send_order_link_to_customer(order):
    """DMs/emails the customer their order tracking link right after it's created —
    a transactional message, not a subscription, so no unsubscribe link on it."""
    site_url = get_settings().site_url or 'http://localhost:5000'
    order_url = f"{site_url}/order/{order.unique_link}"
    result = {'sent_discord': False, 'sent_email': False}

    if order.customer_discord:
        handle = order.customer_discord.lstrip('@')
        settings = get_settings()
        try:
            r = requests.post(f'{DISCORD_BOT_INTERNAL_URL()}/internal/dm', json={
                'secret': settings.discord_bot_secret,
                'username': handle,
                'message': f"Your commission order {order.order_id} is set up! Track it here: {order_url}",
                'embed': {
                    'title': '🎨 Your Order Is Ready to Track',
                    'description': (
                        f"Thanks for commissioning **Cioda's Commissions**!\n\n"
                        f"**Order ID:** {order.order_id}\n\n"
                        f"[Click here to track your order]({order_url})\n\n"
                        f"Bookmark this link — you can check your status, updates, and "
                        f"finished artwork here anytime."
                    ),
                    'color': 0xF59E0B,
                    'footer': "Cioda's Commissions",
                },
            }, timeout=10)
            data = r.json() if r.ok else {}
            result['sent_discord'] = bool(data.get('sent'))
        except Exception:
            result['sent_discord'] = False

    if order.customer_email and email_configured():
        html = branded_email_html(
            heading="Your commission order is set up!",
            body_html=(
                f"<p>Thanks for commissioning <strong>Cioda's Commissions</strong>!</p>"
                f"<p><strong>Order ID:</strong> {order.order_id}</p>"
                f"<p>Use the link below anytime to check your order's status, see updates, "
                f"and download your finished artwork once it's ready.</p>"
            ),
            cta_url=order_url, cta_label="Track My Order",
        )
        result['sent_email'] = send_email(
            order.customer_email, f"Your order {order.order_id} — Cioda's Commissions",
            f"Thanks for commissioning Cioda's Commissions!\n\n"
            f"Order ID: {order.order_id}\n\nTrack your order: {order_url}",
            html_body=html,
        )

    return result

def notify_ping_list_commissions_open():
    """Notifies everyone who asked to hear about reopening: Trello ping-list Discord
    handles, direct Discord signups, and confirmed email signups.
    Uses SiteSettings.query directly (not get_settings()) since this can be called
    from inside check_commission_schedule(), which get_settings() itself calls."""
    settings = SiteSettings.query.first()
    site_url = get_settings().site_url or 'http://localhost:5000'
    dm_message = f"🎉 Commissions are now open! Head over to {site_url} to submit your request."

    discord_targets = PingListSubscriber.query.filter_by(active=True).all()
    direct_discord   = CommissionNotifySubscriber.query.filter_by(method='discord').all()
    email_subs       = CommissionNotifySubscriber.query.filter_by(method='email', confirmed=True).all()

    sent = failed = 0
    for sub in discord_targets:
        if _send_discord_dm(settings, sub.discord_username, dm_message):
            sub.last_notified_at = datetime.utcnow()
            sent += 1
        else:
            failed += 1
    for sub in direct_discord:
        if _send_discord_dm(settings, sub.contact, dm_message, user_id=sub.discord_user_id):
            sub.notified_at = datetime.utcnow()
            sent += 1
        else:
            failed += 1

    email_sent = email_failed = 0
    email_body = (
        f"Hey!\n\nJust letting you know commissions are now open.\n\n"
        f"Head over to {site_url} to submit your request.\n\n— Cioda"
    )
    for sub in email_subs:
        if send_email(sub.contact, "Commissions are open! 🎉", email_body):
            sub.notified_at = datetime.utcnow()
            email_sent += 1
        else:
            email_failed += 1

    db.session.commit()
    return {
        'sent': sent, 'failed': failed, 'total': len(discord_targets) + len(direct_discord),
        'email_sent': email_sent, 'email_failed': email_failed, 'email_total': len(email_subs),
    }

# ─── SPAM DETECTION & QUEUE SYSTEM ───────────────────────────────────────────
import threading, time, collections

# ── Rate limiting (in-memory, resets on restart) ──
_rate_lock       = threading.Lock()
_ip_submissions  = collections.defaultdict(list)  # ip → [timestamps]
_ip_blocks       = {}                              # ip → unblock_datetime

RATE_LIMIT_WINDOW  = 60    # seconds
RATE_LIMIT_MAX     = 3     # max submissions per window
BLOCK_DURATION     = 600   # 10 min block after too many attempts

def get_client_ip():
    """Get real IP behind proxies.

    ProxyFix (configured above with x_for=1) already rewrites request.remote_addr using
    nginx's X-Forwarded-For. Re-reading the raw header here and taking the leftmost entry
    was a bug: nginx *appends* the real client IP rather than replacing the header, so the
    leftmost entry is whatever the client itself sent and is fully attacker-controlled —
    it let anyone spoof the IP recorded in LoginLog, the rate limiter, and the /security
    whitelist check just by sending their own X-Forwarded-For header.
    """
    return request.remote_addr or '0.0.0.0'

def is_ip_blocked(ip):
    with _rate_lock:
        if ip in _ip_blocks:
            if datetime.utcnow() < _ip_blocks[ip]:
                return True
            else:
                del _ip_blocks[ip]
    return False

def record_submission(ip):
    """Record a submission. Returns True if allowed, False if rate-limited."""
    now = datetime.utcnow()
    with _rate_lock:
        # Purge old timestamps
        cutoff = now - timedelta(seconds=RATE_LIMIT_WINDOW)
        _ip_submissions[ip] = [t for t in _ip_submissions[ip] if t > cutoff]
        if len(_ip_submissions[ip]) >= RATE_LIMIT_MAX:
            _ip_blocks[ip] = now + timedelta(seconds=BLOCK_DURATION)
            return False
        _ip_submissions[ip].append(now)
    return True

# ── Login brute-force lockout (separate from the general submission limiter above —
# admin/security logins need a much stricter cap than a 3-per-minute contact form) ──
_login_lock    = threading.Lock()
_login_fails   = collections.defaultdict(list)  # ip → [timestamps of failed attempts]
_login_blocks  = {}                              # ip → unblock_datetime

LOGIN_FAIL_WINDOW = 900   # 15 min
LOGIN_FAIL_MAX    = 5     # max failed attempts per window before lockout
LOGIN_BLOCK_SECS  = 900   # 15 min lockout

def is_login_blocked(ip):
    with _login_lock:
        unblock_at = _login_blocks.get(ip)
        if unblock_at and datetime.utcnow() < unblock_at:
            return True
        if unblock_at:
            del _login_blocks[ip]
    return False

def record_login_failure(ip):
    """Record a failed login attempt; locks the IP out once it exceeds the threshold."""
    now = datetime.utcnow()
    with _login_lock:
        cutoff = now - timedelta(seconds=LOGIN_FAIL_WINDOW)
        _login_fails[ip] = [t for t in _login_fails[ip] if t > cutoff]
        _login_fails[ip].append(now)
        if len(_login_fails[ip]) >= LOGIN_FAIL_MAX:
            _login_blocks[ip] = now + timedelta(seconds=LOGIN_BLOCK_SECS)

def clear_login_failures(ip):
    with _login_lock:
        _login_fails.pop(ip, None)
        _login_blocks.pop(ip, None)

# ── Queue system ──
# Everyone passes through /queue/waiting first.
# Up to MAX_ON_FORM=5 users are let through simultaneously.
# The page polls every POLL_INTERVAL=10 seconds to live-check active users.
# Each user must wait MIN_WAIT_SECS=7 seconds minimum before proceeding.

_queue_lock     = threading.Lock()
_queue          = []  # list of dicts: token, ip, joined_at, last_seen, on_form_since

MAX_ON_FORM     = 5    # max simultaneous users on the form
MAX_QUEUE_SIZE  = 10   # if more than this many waiting, redirect to overflow
GALLERY_DIR = os.path.join(app.static_folder, 'gallery')
os.makedirs(GALLERY_DIR, exist_ok=True)
ORDER_LOG_IMAGES_DIR = os.path.join(app.static_folder, 'order_log_images')
os.makedirs(ORDER_LOG_IMAGES_DIR, exist_ok=True)
FINAL_IMAGES_DIR = os.path.join(app.static_folder, 'final_images')
os.makedirs(FINAL_IMAGES_DIR, exist_ok=True)
ALLOWED_EXTENSIONS = {'png', 'jpg', 'jpeg', 'gif', 'webp'}

def allowed_file(filename):
    return '.' in filename and filename.rsplit('.', 1)[1].lower() in ALLOWED_EXTENSIONS

OVERFLOW_URL       = 'https://overflow.ciodrawz.space/'
OVERFLOW_BLOCK_SECS = 300   # 5 minutes — block IP from queue after overflow

# In-memory overflow IP block list: ip -> unblock_at datetime
_overflow_blocked = {}
_overflow_lock    = threading.Lock()

def mark_overflow_blocked(ip):
    """Block an IP for OVERFLOW_BLOCK_SECS after being sent to overflow."""
    with _overflow_lock:
        _overflow_blocked[ip] = datetime.utcnow() + timedelta(seconds=OVERFLOW_BLOCK_SECS)

def is_overflow_blocked(ip):
    """Returns (blocked, seconds_remaining)."""
    with _overflow_lock:
        unblock_at = _overflow_blocked.get(ip)
        if not unblock_at:
            return False, 0
        remaining = (unblock_at - datetime.utcnow()).total_seconds()
        if remaining <= 0:
            del _overflow_blocked[ip]
            return False, 0
        return True, round(remaining)

def clear_overflow_block(ip):
    """Clear block when user has been away 5 mins (called on fresh visit)."""
    with _overflow_lock:
        _overflow_blocked.pop(ip, None)

MIN_WAIT_SECS   = 7    # minimum seconds in queue before allowed through
SESSION_TIMEOUT = 30   # seconds of no heartbeat = treat as gone (10s poll + buffer)
ON_FORM_TIMEOUT = 300  # seconds a form slot lasts before auto-expiry

def _purge_expired():
    """Drop idle queue entries and expired form slots. Must hold _queue_lock or call externally."""
    now = datetime.utcnow()
    idle_cutoff = now - timedelta(seconds=SESSION_TIMEOUT)
    form_cutoff = now - timedelta(seconds=ON_FORM_TIMEOUT)
    global _queue
    _queue = [
        e for e in _queue
        if e['last_seen'] > idle_cutoff                         # still active
        or (e['on_form_since'] and e['on_form_since'] > form_cutoff)  # on form and not expired
    ]

def get_queue_token():
    token = session.get('queue_token')
    if not token:
        token = uuid.uuid4().hex
        session['queue_token'] = token
    return token

def _get_or_join(token):
    """Find or create entry. Must be called inside _queue_lock."""
    for e in _queue:
        if e['token'] == token:
            return e
    entry = {
        'token':        token,
        'ip':           request.headers.get('X-Forwarded-For','').split(',')[0].strip()
                        or request.remote_addr or '0.0.0.0',
        'joined_at':    datetime.utcnow(),
        'last_seen':    datetime.utcnow(),
        'on_form_since': None,
    }
    _queue.append(entry)
    return entry

def get_queue_info(token):
    """
    Heartbeat + state check. Called every 10s by the client.
    Returns: position, total, on_form, wait_remaining, can_proceed, active_users
    """
    now = datetime.utcnow()
    with _queue_lock:
        _purge_expired()
        entry = _get_or_join(token)
        entry['last_seen'] = now  # heartbeat

        # Count slots currently on the form
        form_cutoff = now - timedelta(seconds=ON_FORM_TIMEOUT)
        on_form_entries = [
            e for e in _queue
            if e['on_form_since'] and e['on_form_since'] > form_cutoff
        ]
        on_form = len(on_form_entries)

        # All entries not yet on the form, ordered by joined_at
        waiting = [e for e in _queue if not e['on_form_since']]
        waiting.sort(key=lambda e: e['joined_at'])
        total   = len(_queue)

        # This token's position in the waiting line (1 = next up)
        waiting_tokens = [e['token'] for e in waiting]
        try:
            pos = waiting_tokens.index(token) + 1
        except ValueError:
            # Already on form
            pos = 0

        # How long they've waited
        waited         = (now - entry['joined_at']).total_seconds()
        wait_remaining = max(0.0, MIN_WAIT_SECS - waited)

        # Can proceed if: waited MIN_WAIT AND there's a free slot AND they're next
        free_slots  = max(0, MAX_ON_FORM - on_form)
        can_proceed = (
            wait_remaining == 0
            and free_slots > 0
            and (pos == 1 or entry['on_form_since'] is not None)
        )

        # Count waiting-only (not on form)
        waiting_count = len(waiting)
        overflow = waiting_count > MAX_QUEUE_SIZE

        return {
            'position':       pos,
            'total':          total,
            'on_form':        on_form,
            'free_slots':     free_slots,
            'wait_remaining': round(wait_remaining, 1),
            'can_proceed':    can_proceed,
            'active_users':   total,
            'overflow':       overflow,
            'waiting_count':  waiting_count,
        }

def mark_on_form(token):
    """Called when a user is admitted to the form."""
    now = datetime.utcnow()
    with _queue_lock:
        for e in _queue:
            if e['token'] == token:
                e['on_form_since'] = now
                break

def release_queue_token(token):
    """Called on successful form submission — frees the slot."""
    with _queue_lock:
        global _queue
        _queue = [e for e in _queue if e['token'] != token]

# ─── SECRET IP-LOCKED SECURITY PAGE ─────────────────────────────────────────
SECURITY_PAGE_USER      = os.environ['SECURITY_PAGE_USER']
SECURITY_PAGE_PASS_HASH = os.environ['SECURITY_PAGE_PASS_HASH']
# TODO: replace with your own IP address(es) — until you do, this page 404s for everyone,
# including you. Find yours with `curl -4 ifconfig.me` from the machine you'll browse from.
SECURITY_WHITELIST = {'0.0.0.0'}

@app.route('/security', methods=['GET', 'POST'])
def security_page():
    ip = get_client_ip()
    if ip not in SECURITY_WHITELIST:
        abort(404)  # Look like a missing page to anyone else
    if request.method == 'POST':
        if is_login_blocked('sec:' + ip):
            flash('Too many failed attempts. Try again in a few minutes.', 'error')
            return render_template('security/login.html'), 429
        u = request.form.get('username', '')
        p = request.form.get('password', '')
        valid_user = hmac.compare_digest(u, SECURITY_PAGE_USER)
        valid_pass = check_password_hash(SECURITY_PAGE_PASS_HASH, p)
        if valid_user and valid_pass:
            clear_login_failures('sec:' + ip)
            session['security_authed'] = True
            return redirect(url_for('security_dashboard'))
        record_login_failure('sec:' + ip)
        flash('Invalid credentials.', 'error')
    return render_template('security/login.html')

@app.route('/security/dashboard')
def security_dashboard():
    ip = get_client_ip()
    if ip not in SECURITY_WHITELIST:
        abort(404)
    if not session.get('security_authed'):
        return redirect(url_for('security_page'))
    logs = LoginLog.query.order_by(LoginLog.logged_at.desc()).limit(200).all()
    # Stats
    total       = LoginLog.query.count()
    successful  = LoginLog.query.filter_by(success=True).count()
    failed      = LoginLog.query.filter_by(success=False).count()
    unique_ips  = db.session.query(db.func.count(db.func.distinct(LoginLog.ip_address))).scalar()
    return render_template('security/dashboard.html',
        logs=logs, total=total, successful=successful,
        failed=failed, unique_ips=unique_ips
    )

@app.route('/security/logout')
def security_logout():
    session.pop('security_authed', None)
    return redirect(url_for('security_page'))

# ─── AUTH ─────────────────────────────────────────────────────────────────────

ADMIN_USERNAME      = os.environ['ADMIN_USERNAME']
ADMIN_PASSWORD_HASH = os.environ['ADMIN_PASSWORD_HASH']

@app.route('/admin/login', methods=['GET', 'POST'])
def admin_login():
    if request.method == 'POST':
        ip = get_client_ip()
        if is_login_blocked(ip):
            flash('Too many failed attempts. Try again in a few minutes.', 'error')
            return render_template('auth/login.html'), 429
        username = request.form.get('username', '')
        password = request.form.get('password', '')
        valid_user = hmac.compare_digest(username, ADMIN_USERNAME)
        valid_pass = check_password_hash(ADMIN_PASSWORD_HASH, password)
        if valid_user and valid_pass:
            clear_login_failures(ip)
            session['admin_logged_in'] = True
            session.permanent = True
            # Record previous login time before updating
            session['prev_login'] = session.get('last_login')
            session['last_login'] = datetime.utcnow().isoformat()
            session['show_new_orders_popup'] = True
            # Log successful login
            log = LoginLog(
                ip_address=ip,
                user_agent=request.headers.get('User-Agent', '')[:500],
                success=True,
                note='Admin login successful'
            )
            db.session.add(log)
            db.session.commit()
            return redirect(url_for('admin_dashboard'))
        # Log failed attempt
        record_login_failure(ip)
        fail_log = LoginLog(
            ip_address=ip,
            user_agent=request.headers.get('User-Agent', '')[:500],
            success=False,
            note=f'Failed attempt — username: {username[:50]}'
        )
        db.session.add(fail_log)
        db.session.commit()
        flash('Invalid credentials.', 'error')
    return render_template('auth/login.html')

@app.route('/admin/logout')
def admin_logout():
    session.pop('admin_logged_in', None)
    return redirect(url_for('admin_login'))

@app.route('/')
def index():
    gallery = GalleryImage.query.filter_by(active=True).order_by(GalleryImage.order_index, GalleryImage.created_at).all()
    return render_template('index.html', settings=get_settings(), presets=get_presets(), gallery=gallery)

# ─── COMMISSION REQUEST FORM ──────────────────────────────────────────────────



@app.route('/api/slots', methods=['GET','OPTIONS'])
def api_slots():
    if request.method == 'OPTIONS':
        resp = app.make_default_options_response()
        resp.headers['Access-Control-Allow-Origin']  = '*'
        resp.headers['Access-Control-Allow-Methods'] = 'GET, OPTIONS'
        resp.headers['Access-Control-Allow-Headers'] = 'Content-Type'
        return resp
    """Public API — used by overflow.html to live-check available slots.
    CORS headers added so overflow.ciodrawz.space can call this cross-origin.
    """
    now = datetime.utcnow()
    with _queue_lock:
        form_cutoff = now - timedelta(seconds=ON_FORM_TIMEOUT)
        on_form = sum(
            1 for e in _queue
            if e.get('on_form_since') and e['on_form_since'] > form_cutoff
        )
        waiting = sum(
            1 for e in _queue if not e.get('on_form_since')
        )
    free_slots   = max(0, MAX_ON_FORM - on_form)
    queue_full   = waiting >= MAX_QUEUE_SIZE
    settings     = get_settings()
    resp = jsonify({
        'free_slots':       free_slots,
        'on_form':          on_form,
        'waiting':          waiting,
        'max_slots':        MAX_ON_FORM,
        'queue_full':       queue_full,
        'queue_url':        'https://order.ciodrawz.space/queue/waiting',
        'commissions_open': settings.commissions_open,
    })
    # Allow overflow.ciodrawz.space to fetch this cross-origin
    resp.headers['Access-Control-Allow-Origin']  = '*'  # Public slots API — no sensitive data
    resp.headers['Access-Control-Allow-Methods'] = 'GET'
    resp.headers['Access-Control-Allow-Headers'] = 'Content-Type'
    resp.headers['Cache-Control']                = 'no-store, no-cache, must-revalidate'
    return resp

@app.route('/queue/preview')
def queue_preview():
    """Admin preview — shows waiting room with fake data."""
    return render_template('queue_waiting.html', preview=True,
        position=3, total=8, on_form=2, wait_remaining=4.0, can_proceed=False)

@app.route('/queue/status')
def queue_status():
    """JSON endpoint polled by the waiting room page."""
    token = get_queue_token()
    info  = get_queue_info(token)
    # Tell the client to redirect to overflow if queue is too long
    if info.get('overflow'):
        info['redirect'] = OVERFLOW_URL
    return jsonify(info)

@app.route('/queue/waiting')
def queue_waiting():
    """Everyone goes here first before /request."""
    settings = get_settings()
    if not settings.commissions_open:
        return render_template('closed.html', message=settings.closed_message, settings=settings)
    # Check if this IP is overflow-blocked
    ip = get_client_ip()
    blocked, secs_left = is_overflow_blocked(ip)
    if blocked:
        return render_template('overflow_blocked.html', secs_left=secs_left)
    token = get_queue_token()
    info  = get_queue_info(token)
    # Hard redirect to overflow if queue > MAX_QUEUE_SIZE
    if info.get('overflow'):
        # Block this IP for 5 minutes and remove from queue
        mark_overflow_blocked(ip)
        release_queue_token(token)
        return redirect(OVERFLOW_URL)
    if info['can_proceed']:
        mark_on_form(token)
        return redirect(url_for('commission_request'))
    return render_template('queue_waiting.html', preview=False, **info)

@app.route('/request', methods=['GET', 'POST'])
def commission_request():
    settings = get_settings()
    if not settings.commissions_open:
        return render_template('closed.html', message=settings.closed_message, settings=settings)

    # ── Queue gate — everyone must pass through /queue/waiting first ──
    ip = get_client_ip()
    blocked, secs_left = is_overflow_blocked(ip)
    if blocked:
        return render_template('overflow_blocked.html', secs_left=secs_left)
    token = get_queue_token()
    if request.method == 'GET':
        info = get_queue_info(token)
        if not info['can_proceed']:
            return redirect(url_for('queue_waiting'))
        mark_on_form(token)

    fields = FormField.query.filter_by(active=True).order_by(FormField.order_index).all()

    # Build ref-image config for the JS — maps type_name → {allow, max}
    all_types = CommissionType.query.filter_by(active=True).all()
    global_max = settings.max_ref_images_default or 3
    ref_config = {
        t.type_name: {
            'allow': bool(t.allow_ref_images),
            'max':   t.max_ref_images if t.max_ref_images > 0 else global_max,
        }
        for t in all_types
    }
    ref_config_json = json.dumps(ref_config)

    if request.method == 'POST':
        # ── Honeypot check (bots fill hidden fields, humans don't) ──
        if request.form.get('website_url', '') or request.form.get('phone_number', ''):
            return render_template('spam_blocked.html')

        # ── IP rate limit check ──
        ip = get_client_ip()
        if is_ip_blocked(ip):
            return render_template('spam_blocked.html')
        if not record_submission(ip):
            return render_template('spam_blocked.html')

        name = request.form.get('customer_name', '').strip()
        email = request.form.get('customer_email', '').strip()
        discord = request.form.get('customer_discord', '').strip()
        instagram = request.form.get('customer_instagram', '').strip()
        payment_method = request.form.get('payment_method', '').strip()
        payment_username = request.form.get('payment_username', '').strip()
        comm_types = request.form.getlist('commission_type')
        comm_type = ', '.join(filter(None, comm_types))
        description  = request.form.get('description', '').strip()
        discount_code_str = request.form.get('discount_code', '').strip().upper()
        discount_amount   = 0.0
        discount_label    = ''
        if discount_code_str:
            dc, dc_err = is_code_valid(discount_code_str)
            if dc:
                dc.uses += 1
                db.session.add(dc)
                if dc.type == 'percent':
                    discount_label  = f'{dc.value:.0f}% discount ({discount_code_str})'
                else:
                    discount_label  = f'${dc.value:.2f} discount ({discount_code_str})'
            elif dc_err:
                flash(dc_err, 'error')
                return redirect(url_for('queue_waiting'))
        form_responses = {}
        for field in fields:
            form_responses[field.field_key] = request.form.get(field.field_key, '')

        # Handle reference image uploads
        settings_obj  = get_settings()
        global_max    = settings_obj.max_ref_images_default or 3
        ref_filenames = []
        # Look up selected commission types to know if any allow ref images
        selected_types = CommissionType.query.filter(
            CommissionType.type_name.in_(comm_types),
            CommissionType.allow_ref_images == True
        ).all()
        if selected_types:
            max_allowed = max((t.max_ref_images if t.max_ref_images > 0 else global_max) for t in selected_types)
            ref_files   = request.files.getlist('ref_images')
            ref_dir     = os.path.join(app.static_folder, 'ref_uploads')
            os.makedirs(ref_dir, exist_ok=True)
            for rf in ref_files[:max_allowed]:
                if rf and allowed_file(rf.filename):
                    ext  = rf.filename.rsplit('.', 1)[1].lower()
                    fname = f'ref_{uuid.uuid4().hex[:12]}.{ext}'
                    rf.save(os.path.join(ref_dir, fname))
                    ref_filenames.append(fname)
        if ref_filenames:
            form_responses['_ref_images'] = ','.join(ref_filenames)
        if discount_label:
            form_responses['_discount'] = discount_label

        # Save request record for admin to review
        req = CommissionRequest(
            request_id=gen_id('REQ'),
            customer_name=name,
            customer_email=email,
            customer_discord=discord,
            customer_instagram=instagram,
            payment_method=payment_method,
            payment_username=payment_username,
            commission_type=comm_type,
            description=description,
            form_responses=json.dumps(form_responses),
            status='Pending'
        )
        db.session.add(req)

        # Also auto-create the order immediately so customer gets their link right away
        order = Order(
            order_id=gen_id('ORD'),
            unique_link=gen_link(),
            customer_name=name,
            customer_email=email,
            customer_discord=discord,
            customer_instagram=instagram,
            payment_method=payment_method,
            payment_username=payment_username,
            commission_type=comm_type,
            description=description,
            form_responses=json.dumps(form_responses),
            status='Awaiting Confirmation',
            payment_status='Unpaid',
        )
        db.session.add(order)
        db.session.commit()

        # Link the request to the order
        req.status = 'Accepted'
        db.session.commit()

        add_log(order.order_id, 'Order Created', f'Submitted via commission request form (Request #{req.request_id})')
        auto_create_invoice(order)  # Auto-generate draft invoice

        send_webhook(
            f"🎨 **New Commission Request** from **{name}**",
            embeds=[{
                'title': f'Order #{order.order_id} — {comm_type or "Commission"}',
                'color': 0xf59e0b,
                'fields': [
                    {'name': 'Commission Type', 'value': comm_type or 'Not specified', 'inline': True},
                    {'name': 'Discord', 'value': discord or 'N/A', 'inline': True},
                    {'name': 'Order ID', 'value': order.order_id, 'inline': True},
                    {'name': 'Tracking Link', 'value': f'/order/{order.unique_link}'},
                    {'name': 'Description', 'value': (description or 'N/A')[:500]},
                ],
                'timestamp': datetime.utcnow().isoformat()
            }]
        )
        notify_contact_bot(req, order)   # → posts to Discord #contact channel with reply dropdown
        release_queue_token(token)
        return redirect(url_for('request_submitted', link=order.unique_link, order_id=order.order_id))
    return render_template('request_form.html', fields=fields, presets=get_presets(), settings=settings, ref_config_json=ref_config_json)

@app.route('/request/submitted')
def request_submitted():
    link = request.args.get('link', '')
    order_id = request.args.get('order_id', '')
    order = Order.query.filter_by(unique_link=link).first() if link else None
    return render_template('request_submitted.html', link=link, order_id=order_id, order=order)


# ─── INVOICE PDF DOWNLOAD ─────────────────────────────────────────────────────

@app.route('/order/<link>/invoice/<invoice_id>/download')
def download_invoice_pdf(link, invoice_id):
    """Generate and stream a PDF invoice for the customer."""
    order   = Order.query.filter_by(unique_link=link).first_or_404()
    invoice = Invoice.query.filter_by(invoice_id=invoice_id, order_id=order.order_id).first_or_404()

    from reportlab.lib.pagesizes import A4
    from reportlab.lib import colors
    from reportlab.lib.units import mm
    from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle, HRFlowable
    from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
    from reportlab.lib.enums import TA_LEFT, TA_RIGHT, TA_CENTER

    buf = io.BytesIO()

    # ── Dark page background drawn on every page ──
    PAGE_BG = colors.HexColor('#17171b')

    def draw_bg(canvas, doc):
        canvas.saveState()
        canvas.setFillColor(PAGE_BG)
        canvas.rect(0, 0, A4[0], A4[1], fill=1, stroke=0)
        canvas.restoreState()

    doc = SimpleDocTemplate(buf, pagesize=A4,
        leftMargin=18*mm, rightMargin=18*mm,
        topMargin=18*mm, bottomMargin=18*mm)

    W = A4[0] - 36*mm  # usable width

    # ── Colour palette ──
    COL_BG     = colors.HexColor('#1e1e24')  # card surface colour
    COL_CARD   = colors.HexColor('#1e1e24')
    COL_ACCENT = colors.HexColor('#a855f7')
    COL_GOLD   = colors.HexColor('#f59e0b')
    COL_MUTED  = colors.HexColor('#9694a8')
    COL_TEXT   = colors.HexColor('#e8e6f0')
    COL_GREEN  = colors.HexColor('#22c55e')
    COL_RED    = colors.HexColor('#ef4444')
    COL_BORDER = colors.HexColor('#2e2e38')

    styles = getSampleStyleSheet()

    def sty(name='Normal', **kw):
        base = styles[name] if name in styles else styles['Normal']
        s = ParagraphStyle(name + str(id(kw)), parent=base)
        for k,v in kw.items():
            setattr(s, k, v)
        return s

    story = []

    # ── Header band ──
    header_data = [[
        Paragraph('<font color="#a855f7"><b>CIODA COMMISSIONS</b></font>',
                  sty(fontSize=18, textColor=COL_ACCENT, fontName='Helvetica-Bold')),
        Paragraph(f'<font color="#9694a8">INVOICE</font>',
                  sty(fontSize=18, textColor=COL_MUTED, fontName='Helvetica-Bold', alignment=TA_RIGHT)),
    ]]
    ht = Table(header_data, colWidths=[W*0.6, W*0.4])
    ht.setStyle(TableStyle([
        ('BACKGROUND', (0,0), (-1,-1), COL_BG),
        ('ROWBACKGROUNDS', (0,0), (-1,-1), [COL_BG]),
        ('TOPPADDING',    (0,0), (-1,-1), 10),
        ('BOTTOMPADDING', (0,0), (-1,-1), 10),
        ('LEFTPADDING',   (0,0), (-1,-1), 12),
        ('RIGHTPADDING',  (0,0), (-1,-1), 12),
        ('ROUNDEDCORNERS', [6]),
    ]))
    story.append(ht)
    story.append(Spacer(1, 6*mm))

    # ── Invoice meta ──
    status_col = COL_GREEN if invoice.paid else COL_RED
    status_txt = 'PAID' if invoice.paid else 'UNPAID'

    meta_data = [
        [Paragraph('<b>Invoice ID</b>', sty(textColor=COL_MUTED, fontSize=8, fontName='Helvetica-Bold')),
         Paragraph(invoice.invoice_id, sty(textColor=COL_TEXT, fontSize=10, fontName='Helvetica'))],
        [Paragraph('<b>Order ID</b>', sty(textColor=COL_MUTED, fontSize=8, fontName='Helvetica-Bold')),
         Paragraph(order.order_id, sty(textColor=COL_TEXT, fontSize=10, fontName='Helvetica'))],
        [Paragraph('<b>Customer</b>', sty(textColor=COL_MUTED, fontSize=8, fontName='Helvetica-Bold')),
         Paragraph(order.customer_name, sty(textColor=COL_TEXT, fontSize=10, fontName='Helvetica'))],
        [Paragraph('<b>Date</b>', sty(textColor=COL_MUTED, fontSize=8, fontName='Helvetica-Bold')),
         Paragraph(invoice.created_at.strftime('%B %d, %Y'), sty(textColor=COL_TEXT, fontSize=10, fontName='Helvetica'))],
        [Paragraph('<b>Due</b>', sty(textColor=COL_MUTED, fontSize=8, fontName='Helvetica-Bold')),
         Paragraph(invoice.due_date or 'On Completion', sty(textColor=COL_TEXT, fontSize=10, fontName='Helvetica'))],
        [Paragraph('<b>Status</b>', sty(textColor=COL_MUTED, fontSize=8, fontName='Helvetica-Bold')),
         Paragraph(f'<font color="#{("22c55e" if invoice.paid else "ef4444")}"><b>{status_txt}</b></font>',
                   sty(textColor=status_col, fontSize=10, fontName='Helvetica-Bold'))],
    ]
    mt = Table(meta_data, colWidths=[30*mm, W - 30*mm])
    mt.setStyle(TableStyle([
        ('BACKGROUND',    (0,0), (-1,-1), COL_CARD),
        ('TOPPADDING',    (0,0), (-1,-1), 5),
        ('BOTTOMPADDING', (0,0), (-1,-1), 5),
        ('LEFTPADDING',   (0,0), (0,-1), 12),
        ('RIGHTPADDING',  (0,0), (-1,-1), 12),
        ('LINEBELOW', (0,0), (-1,-2), 0.3, COL_BORDER),
        ('ROUNDEDCORNERS', [6]),
    ]))
    story.append(mt)
    story.append(Spacer(1, 6*mm))

    # ── Line items ──
    items = json.loads(invoice.items or '[]')
    items_header = [
        Paragraph('<b>Description</b>', sty(textColor=COL_MUTED, fontSize=8, fontName='Helvetica-Bold')),
        Paragraph('<b>Amount</b>',      sty(textColor=COL_MUTED, fontSize=8, fontName='Helvetica-Bold', alignment=TA_RIGHT)),
    ]
    items_rows = [items_header]
    for item in items:
        items_rows.append([
            Paragraph(str(item.get('desc','Commission')), sty(textColor=COL_TEXT, fontSize=10, fontName='Helvetica')),
            Paragraph(f'${float(item.get("amount",0)):.2f}',
                      sty(textColor=COL_GOLD, fontSize=10, fontName='Helvetica-Bold', alignment=TA_RIGHT)),
        ])
    # Total row
    items_rows.append([
        Paragraph('<b>TOTAL</b>', sty(textColor=COL_TEXT, fontSize=11, fontName='Helvetica-Bold')),
        Paragraph(f'<b>${invoice.amount:.2f}</b>',
                  sty(textColor=COL_GOLD, fontSize=13, fontName='Helvetica-Bold', alignment=TA_RIGHT)),
    ])

    it = Table(items_rows, colWidths=[W*0.65, W*0.35])
    style_cmds = [
        ('BACKGROUND',    (0,0), (-1,-1),  COL_CARD),
        ('BACKGROUND',    (0,0), (-1,0),   colors.HexColor('#17171b')),
        ('BACKGROUND',    (0,-1),(-1,-1),  colors.HexColor('#17171b')),
        ('TOPPADDING',    (0,0), (-1,-1), 7),
        ('BOTTOMPADDING', (0,0), (-1,-1), 7),
        ('LEFTPADDING',   (0,0), (-1,-1), 12),
        ('RIGHTPADDING',  (0,0), (-1,-1), 12),
        ('LINEBELOW', (0,0),  (-1,0),   0.4, COL_BORDER),
        ('LINEABOVE', (0,-1), (-1,-1),  0.8, COL_ACCENT),
        ('ROUNDEDCORNERS', [6]),
    ]
    it.setStyle(TableStyle(style_cmds))
    story.append(it)
    story.append(Spacer(1, 6*mm))

    # ── Payment method ──
    if order.payment_method and order.payment_username:
        pm_label = '$Cashtag' if order.payment_method == 'CashApp' else 'PayPal Email'
        pm_icon  = 'Cash App' if order.payment_method == 'CashApp' else 'PayPal'
        pay_data = [[
            Paragraph(f'<b>Payment Method:</b>  {pm_icon}', sty(textColor=COL_MUTED, fontSize=9, fontName='Helvetica')),
            Paragraph(f'<b>{pm_label}:</b>  {order.payment_username}', sty(textColor=COL_TEXT, fontSize=9, fontName='Helvetica', alignment=TA_RIGHT)),
        ]]
        pt = Table(pay_data, colWidths=[W*0.5, W*0.5])
        pt.setStyle(TableStyle([
            ('BACKGROUND',    (0,0), (-1,-1), colors.HexColor('#17171b')),
            ('TOPPADDING',    (0,0), (-1,-1), 8),
            ('BOTTOMPADDING', (0,0), (-1,-1), 8),
            ('LEFTPADDING',   (0,0), (-1,-1), 12),
            ('RIGHTPADDING',  (0,0), (-1,-1), 12),
            ('ROUNDEDCORNERS', [6]),
        ]))
        story.append(pt)
        story.append(Spacer(1, 4*mm))

    # ── Cash App payment CTA (shown when unpaid) ──
    if not invoice.paid:
        cashapp_data = [[
            Paragraph(
                '<b><font color="#22c55e">Send Payment via Cash App</font></b>',
                sty(textColor=colors.HexColor('#22c55e'), fontSize=10, fontName='Helvetica-Bold')
            ),
            Paragraph(
                '<b><font color="#22c55e">cash.app/$Cioda</font></b>',
                sty(textColor=colors.HexColor('#22c55e'), fontSize=11, fontName='Helvetica-Bold', alignment=TA_RIGHT)
            ),
        ]]
        ct = Table(cashapp_data, colWidths=[W*0.5, W*0.5])
        ct.setStyle(TableStyle([
            ('BACKGROUND',    (0,0), (-1,-1), colors.HexColor('#0f2a1f')),
            ('LINEABOVE',     (0,0), (-1,0),  0.8, colors.HexColor('#22c55e')),
            ('LINEBELOW',     (0,0), (-1,-1), 0.8, colors.HexColor('#22c55e')),
            ('LINEBEFORE',    (0,0), (0,-1),  0.8, colors.HexColor('#22c55e')),
            ('LINEAFTER',     (-1,0),(-1,-1), 0.8, colors.HexColor('#22c55e')),
            ('TOPPADDING',    (0,0), (-1,-1), 10),
            ('BOTTOMPADDING', (0,0), (-1,-1), 10),
            ('LEFTPADDING',   (0,0), (-1,-1), 12),
            ('RIGHTPADDING',  (0,0), (-1,-1), 12),
            ('ROUNDEDCORNERS', [6]),
        ]))
        story.append(ct)
        story.append(Spacer(1, 4*mm))

    # ── Notes ──
    if invoice.notes:
        story.append(Paragraph(f'<i>{invoice.notes}</i>',
            sty(textColor=COL_MUTED, fontSize=8, fontName='Helvetica-Oblique')))
        story.append(Spacer(1, 4*mm))

    # ── Footer ──
    story.append(Spacer(1, 6*mm))
    footer_data = [[
        Paragraph('cioda@ciodrawz.space  ·  discord: totallynotcioda  ·  order.ciodrawz.space  ·  cash.app/$Cioda',
                  sty(textColor=COL_MUTED, fontSize=7, fontName='Helvetica', alignment=TA_CENTER)),
    ]]
    ft = Table(footer_data, colWidths=[W])
    ft.setStyle(TableStyle([
        ('BACKGROUND',    (0,0), (-1,-1), colors.HexColor('#17171b')),
        ('LINEABOVE',     (0,0), (-1,0), 0.3, COL_BORDER),
        ('TOPPADDING',    (0,0), (-1,-1), 8),
        ('BOTTOMPADDING', (0,0), (-1,-1), 4),
        ('LEFTPADDING',   (0,0), (-1,-1), 0),
        ('RIGHTPADDING',  (0,0), (-1,-1), 0),
    ]))
    story.append(ft)

    doc.build(story, onFirstPage=draw_bg, onLaterPages=draw_bg)
    buf.seek(0)

    resp = make_response(buf.read())
    resp.headers['Content-Type']        = 'application/pdf'
    resp.headers['Content-Disposition'] = f'attachment; filename="invoice-{invoice_id}.pdf"'
    return resp

# ─── CUSTOMER ORDER TRACKING ──────────────────────────────────────────────────

@app.route('/order/<link>')
def customer_order(link):
    order = Order.query.filter_by(unique_link=link).first_or_404()

    # ── PIN gate ──────────────────────────────────────────────────────────────
    pin_session_key = f'order_pin_ok_{link}'
    if not order.pin_hash:
        # No PIN set yet — show set-PIN page
        return render_template('customer/order.html',
            order=order, logs=[], invoice=None,
            tickets=[], all_tickets=[],
            form_responses=json.loads(order.form_responses or '{}'),
            settings=get_settings(),
            pin_mode='setup'
        )
    if not session.get(pin_session_key):
        # PIN exists but not verified this session
        return render_template('customer/order.html',
            order=order, logs=[], invoice=None,
            tickets=[], all_tickets=[],
            form_responses=json.loads(order.form_responses or '{}'),
            settings=get_settings(),
            pin_mode='verify'
        )
    # ── PIN cleared — show full order ─────────────────────────────────────────
    logs = OrderLog.query.filter_by(order_id=order.order_id, customer_visible=True).order_by(OrderLog.created_at.desc()).all()
    invoice = Invoice.query.filter_by(order_id=order.order_id).order_by(Invoice.created_at.desc()).first()
    tickets = Ticket.query.filter_by(order_link=link).order_by(Ticket.created_at.desc()).all()
    now = datetime.utcnow()
    active_tickets = [t for t in tickets if t.expires_at and t.expires_at > now and t.status == 'Open']
    order_progress_index = (
        ORDER_PROGRESS_STEPS.index(order.status) if order.status in ORDER_PROGRESS_STEPS else -1
    )
    payment_progress_index = (
        PAYMENT_PROGRESS_STEPS.index(order.payment_status) if order.payment_status in PAYMENT_PROGRESS_STEPS else -1
    )
    final_images = (
        OrderFinalImage.query.filter_by(order_id=order.order_id).order_by(OrderFinalImage.uploaded_at).all()
        if order.status == 'Done' else []
    )
    return render_template('customer/order.html',
        order=order,
        logs=logs,
        invoice=invoice,
        tickets=active_tickets,
        all_tickets=tickets,
        form_responses=json.loads(order.form_responses or '{}'),
        settings=get_settings(),
        pin_mode='open',
        order_progress_steps=ORDER_PROGRESS_STEPS,
        order_progress_index=order_progress_index,
        payment_progress_steps=PAYMENT_PROGRESS_STEPS,
        payment_progress_index=payment_progress_index,
        final_images=final_images,
    )


@app.route('/order/<link>/pin/setup', methods=['POST'])
def order_pin_setup(link):
    order = Order.query.filter_by(unique_link=link).first_or_404()
    if order.pin_hash:
        flash('A PIN is already set. Enter your PIN to access the order.', 'warning')
        return redirect(url_for('customer_order', link=link))
    pin = request.form.get('pin', '').strip()
    pin_confirm = request.form.get('pin_confirm', '').strip()
    if not pin.isdigit() or not (4 <= len(pin) <= 8):
        flash('PIN must be 4–8 digits.', 'error')
        return redirect(url_for('customer_order', link=link))
    if pin != pin_confirm:
        flash('PINs do not match. Please try again.', 'error')
        return redirect(url_for('customer_order', link=link))
    order.pin_hash = hashlib.sha256(pin.encode()).hexdigest()
    db.session.commit()
    session[f'order_pin_ok_{link}'] = True
    add_log(order.order_id, 'PIN Set', 'Customer set a PIN to protect their order link')
    flash('PIN set successfully! Your order is now protected.', 'success')
    return redirect(url_for('customer_order', link=link))


@app.route('/order/<link>/pin/verify', methods=['POST'])
def order_pin_verify(link):
    order = Order.query.filter_by(unique_link=link).first_or_404()
    pin = request.form.get('pin', '').strip()
    if order.pin_hash and hashlib.sha256(pin.encode()).hexdigest() == order.pin_hash:
        session[f'order_pin_ok_{link}'] = True
        return redirect(url_for('customer_order', link=link))
    flash('Incorrect PIN. Please try again.', 'error')
    return redirect(url_for('customer_order', link=link))

# ─── TICKET SYSTEM ───────────────────────────────────────────────────────────

@app.route('/order/<link>/ticket/new', methods=['GET', 'POST'])
def new_ticket(link):
    order = Order.query.filter_by(unique_link=link).first_or_404()
    if request.method == 'POST':
        name = request.form.get('name', order.customer_name).strip()
        subject = request.form.get('subject', '').strip()
        message = request.form.get('message', '').strip()
        ticket = Ticket(
            ticket_id=gen_id('TKT'),
            order_link=link,
            order_id=order.order_id,
            customer_name=name,
            subject=subject,
            expires_at=datetime.utcnow() + timedelta(hours=24)
        )
        db.session.add(ticket)
        db.session.flush()
        msg = TicketMessage(ticket_id=ticket.ticket_id, sender='customer', message=message)
        db.session.add(msg)
        db.session.commit()
        send_webhook(
            content="",
            embeds=[{
                'title': f"🎫  NEW TICKET — #{ticket.ticket_id}",
                'description': (
                    f"**{name}** has opened a new support ticket.\n"
                    f"\u200b"
                ),
                'color': 0x6366f1,
                'fields': [
                    {'name': '📦  Order ID',   'value': f"`{order.order_id}`",       'inline': True},
                    {'name': '👤  Customer',   'value': name,                         'inline': True},
                    {'name': '\u200b',         'value': '\u200b',                   'inline': False},
                    {'name': '📌  Subject',    'value': subject or '(no subject)',    'inline': False},
                    {'name': '💬  Message',    'value': message[:1000] or '(empty)', 'inline': False},
                    {'name': '⏰  Expires',    'value': ticket.expires_at.strftime('%b %d %Y at %H:%M UTC'), 'inline': True},
                    {'name': '🔗  Admin Link',  'value': f"{request.host_url}admin/tickets/{ticket.ticket_id}", 'inline': True},
                    {'name': '💬  Ticket Link', 'value': f"{request.host_url}order/{link}/ticket/{ticket.ticket_id}", 'inline': True},
                ],
                'footer': {'text': f'Ticket {ticket.ticket_id}  •  {order.order_id}'},
                'timestamp': datetime.utcnow().isoformat()
            }],
            webhook_type='ticket'
        )
        # ── Create Discord thread for this ticket ──
        _settings = SiteSettings.query.first()
        thread_id = _create_discord_thread(
            _settings.discord_ticket_channel,
            ticket,
            message,
            _settings.discord_bot_token,
        )
        if thread_id:
            ticket.discord_thread_id = thread_id
            db.session.commit()
        return redirect(url_for('view_ticket', link=link, ticket_id=ticket.ticket_id))
    return render_template('customer/new_ticket.html', order=order)

@app.route('/order/<link>/ticket/<ticket_id>', methods=['GET', 'POST'])
def view_ticket(link, ticket_id):
    ticket = Ticket.query.filter_by(ticket_id=ticket_id, order_link=link).first_or_404()
    if ticket.expires_at and datetime.utcnow() > ticket.expires_at:
        flash('This ticket has expired.', 'warning')
    messages = TicketMessage.query.filter_by(ticket_id=ticket_id).order_by(TicketMessage.created_at).all()
    if request.method == 'POST':
        if ticket.expires_at and datetime.utcnow() > ticket.expires_at:
            flash('Cannot reply to an expired ticket.', 'error')
            return redirect(url_for('view_ticket', link=link, ticket_id=ticket_id))
        message = request.form.get('message', '').strip()
        if message:
            msg = TicketMessage(ticket_id=ticket_id, sender='customer', message=message)
            db.session.add(msg)
            db.session.commit()
            send_webhook(
                content="",
                embeds=[{
                    'title': f"💬  CUSTOMER REPLY — #{ticket_id}",
                    'description': f"**{ticket.customer_name}** has replied to their ticket.\n\u200b",
                    'color': 0x818cf8,
                    'fields': [
                        {'name': '📦  Order ID',   'value': f"`{ticket.order_id or 'N/A'}`", 'inline': True},
                        {'name': '👤  Customer',   'value': ticket.customer_name,              'inline': True},
                        {'name': '\u200b',         'value': '\u200b',                       'inline': False},
                        {'name': '📌  Subject',    'value': ticket.subject or '(no subject)', 'inline': False},
                        {'name': '💬  Message',    'value': message[:1000],                   'inline': False},
                        {'name': '🔗  Admin Link', 'value': f"{request.host_url}admin/tickets/{ticket_id}", 'inline': True},
                        {'name': '💬  Ticket Link', 'value': f"{request.host_url}order/{link}/ticket/{ticket_id}", 'inline': True},
                    ],
                    'footer': {'text': f'Ticket {ticket_id}'},
                    'timestamp': datetime.utcnow().isoformat()
                }],
                webhook_type='ticket'
            )
            # ── Mirror customer reply to Discord thread ──
            _settings = SiteSettings.query.first()
            if ticket.discord_thread_id and _settings.discord_bot_token:
                _send_to_discord_thread(
                    ticket.discord_thread_id,
                    f"**💬 Customer reply — {ticket.customer_name}**\n{message[:1800]}",
                    _settings.discord_bot_token,
                )
            return redirect(url_for('view_ticket', link=link, ticket_id=ticket_id))
    return render_template('customer/ticket.html', ticket=ticket, messages=messages, now=datetime.utcnow())

# ─── ADMIN DASHBOARD ──────────────────────────────────────────────────────────

@app.route('/admin')
def admin_dashboard():
    if not is_admin():
        return redirect(url_for('admin_login'))
    orders = Order.query.order_by(Order.created_at.desc()).limit(10).all()
    requests_count = CommissionRequest.query.filter_by(status='Pending').count()
    open_tickets = Ticket.query.filter_by(status='Open').count()
    total_orders = Order.query.count()
    unpaid = Order.query.filter_by(payment_status='Unpaid').count()
    settings = get_settings()
    platform_entitlement = platform_client.get_entitlement()
    # New orders since last login for popup notification
    new_orders = []
    show_popup = session.pop('show_new_orders_popup', False)
    if show_popup:
        prev_login = session.get('prev_login')
        if prev_login:
            try:
                prev_dt = datetime.fromisoformat(prev_login)
                new_orders = Order.query.filter(
                    Order.created_at > prev_dt
                ).order_by(Order.created_at.desc()).all()
            except Exception:
                new_orders = []
        else:
            # First ever login — show orders from last 24h
            new_orders = Order.query.filter(
                Order.created_at > datetime.utcnow() - timedelta(hours=24)
            ).order_by(Order.created_at.desc()).all()
    return render_template('admin/dashboard.html',
        orders=orders, requests_count=requests_count,
        open_tickets=open_tickets, total_orders=total_orders,
        unpaid=unpaid, settings=settings,
        new_orders=new_orders, show_popup=show_popup,
        platform_entitlement=platform_entitlement,
    )

# ─── ADMIN ORDERS ─────────────────────────────────────────────────────────────

@app.route('/admin/orders')
def admin_orders():
    if not is_admin(): return redirect(url_for('admin_login'))
    q = request.args.get('q', '').strip()
    if q:
        like = f'%{q}%'
        orders = Order.query.filter(
            db.or_(
                Order.order_id.ilike(like),
                Order.customer_name.ilike(like),
                Order.customer_email.ilike(like),
                Order.customer_discord.ilike(like),
                Order.customer_instagram.ilike(like),
            )
        ).order_by(Order.created_at.desc()).all()
    else:
        orders = Order.query.order_by(Order.created_at.desc()).all()
    return render_template('admin/orders.html', orders=orders, q=q)

@app.route('/admin/orders/new', methods=['GET', 'POST'])
def admin_new_order():
    if not is_admin(): return redirect(url_for('admin_login'))
    if request.method == 'POST':
        name = request.form.get('customer_name', '').strip()
        email = request.form.get('customer_email', '').strip()
        discord = request.form.get('customer_discord', '').strip()
        instagram = request.form.get('customer_instagram', '').strip()
        payment_method = request.form.get('payment_method', '').strip()
        payment_username = request.form.get('payment_username', '').strip()
        comm_type = request.form.get('commission_type', '').strip()
        price = float(request.form.get('price', 0) or 0)
        description = request.form.get('description', '').strip()
        eta = request.form.get('eta', '').strip()
        notes = request.form.get('notes', '').strip()
        is_test = request.form.get('is_test') == 'on'
        order = Order(
            order_id=gen_id('ORD'),
            unique_link=gen_link(),
            customer_name=name,
            customer_email=email,
            customer_discord=discord,
            customer_instagram=instagram,
            payment_method=payment_method,
            payment_username=payment_username,
            commission_type=comm_type,
            price=price,
            description=description,
            eta=eta,
            notes=notes,
        )
        db.session.add(order)
        db.session.commit()
        add_log(order.order_id, 'Order Created', 'Manual creation by admin' + (' (test order)' if is_test else ''))
        if not is_test:
            platform_client.spend_credit('order_created', reason=f'Order {order.order_id}')
        auto_create_invoice(order)  # Auto-generate draft invoice
        if not is_test:
            send_webhook(f"📋 **New Order Created** — #{order.order_id} for **{name}**")
            delivery = send_order_link_to_customer(order)
            if delivery['sent_discord']:
                add_log(order.order_id, 'Order Link Sent', 'Sent to customer via Discord DM')
            if delivery['sent_email']:
                add_log(order.order_id, 'Order Link Sent', 'Sent to customer via email')
        flash(f'Order {order.order_id} created!' + (' (test — no Discord notification sent)' if is_test else '') + f' Link: /order/{order.unique_link}', 'success')
        return redirect(url_for('admin_order_detail', order_id=order.order_id))
    return render_template('admin/new_order.html', presets=get_presets())

@app.route('/admin/orders/<order_id>')
def admin_order_detail(order_id):
    if not is_admin(): return redirect(url_for('admin_login'))
    order = Order.query.filter_by(order_id=order_id).first_or_404()
    logs = OrderLog.query.filter_by(order_id=order_id).order_by(OrderLog.created_at.desc()).all()
    invoices = Invoice.query.filter_by(order_id=order_id).all()
    tickets = Ticket.query.filter_by(order_id=order_id).all()
    payments = PaymentRecord.query.filter_by(order_id=order_id).all()
    trello_conn = get_trello_connection()
    trello_mapping = TrelloCardMapping.query.filter_by(order_id=order_id).first()
    final_images = OrderFinalImage.query.filter_by(order_id=order_id).order_by(OrderFinalImage.uploaded_at).all()
    return render_template('admin/order_detail.html',
        order=order, logs=logs, invoices=invoices,
        tickets=tickets, payments=payments,
        statuses=ORDER_STATUSES, payment_statuses=PAYMENT_STATUSES,
        form_responses=json.loads(order.form_responses or '{}'),
        presets=get_presets(),
        trello_conn=trello_conn, trello_mapping=trello_mapping,
        final_images=final_images
    )

@app.route('/admin/orders/<order_id>/update', methods=['POST'])
def admin_update_order(order_id):
    if not is_admin(): return redirect(url_for('admin_login'))
    order = Order.query.filter_by(order_id=order_id).first_or_404()
    old_status = order.status
    old_payment = order.payment_status
    order.status = request.form.get('status', order.status)
    order.payment_status = request.form.get('payment_status', order.payment_status)
    order.eta = request.form.get('eta', order.eta)
    order.notes = request.form.get('notes', order.notes)
    order.price = float(request.form.get('price', order.price) or order.price)
    order.updated_at = datetime.utcnow()
    db.session.commit()
    # Keep the draft invoice in sync with the order price
    auto_create_invoice(order)
    if old_status != order.status:
        add_log(order_id, 'Status Updated', f'{old_status} → {order.status}')
        send_webhook(
            f"🔄 **Order Status Updated** — #{order_id}",
            embeds=[{
                'color': 0x22c55e,
                'fields': [
                    {'name': 'Customer', 'value': order.customer_name, 'inline': True},
                    {'name': 'New Status', 'value': order.status, 'inline': True},
                    {'name': 'Payment', 'value': order.payment_status, 'inline': True},
                ],
                'timestamp': datetime.utcnow().isoformat()
            }],
            webhook_type='status'
        )
    if old_payment != order.payment_status:
        add_log(order_id, 'Payment Status Updated', f'{old_payment} → {order.payment_status}')
    flash('Order updated.', 'success')
    return redirect(url_for('admin_order_detail', order_id=order_id))

@app.route('/admin/orders/<order_id>/log', methods=['POST'])
def admin_add_log(order_id):
    if not is_admin(): return redirect(url_for('admin_login'))
    event = request.form.get('event', '').strip()
    details = request.form.get('details', '').strip()
    customer_visible = request.form.get('customer_visible') == 'on'
    image_filename = ''
    image_file = request.files.get('image')
    if image_file and image_file.filename and allowed_file(image_file.filename):
        ext = image_file.filename.rsplit('.', 1)[1].lower()
        image_filename = f"{uuid.uuid4().hex}.{ext}"
        image_file.save(os.path.join(ORDER_LOG_IMAGES_DIR, image_filename))
    if event:
        log = OrderLog(
            order_id=order_id, event=event, details=details or None,
            image_filename=image_filename, customer_visible=customer_visible
        )
        db.session.add(log)
        db.session.commit()
    return redirect(url_for('admin_order_detail', order_id=order_id))

@app.route('/admin/orders/<order_id>/final-image/upload', methods=['POST'])
def admin_upload_final_image(order_id):
    if not is_admin(): return redirect(url_for('admin_login'))
    Order.query.filter_by(order_id=order_id).first_or_404()
    files = request.files.getlist('images')
    count = 0
    for f in files:
        if f and f.filename and allowed_file(f.filename):
            ext = f.filename.rsplit('.', 1)[1].lower()
            filename = f"{uuid.uuid4().hex}.{ext}"
            f.save(os.path.join(FINAL_IMAGES_DIR, filename))
            db.session.add(OrderFinalImage(order_id=order_id, filename=filename))
            count += 1
    if count:
        db.session.commit()
        add_log(order_id, 'Finished Artwork Uploaded', f'{count} file(s) added')
        flash(f'{count} finished image{"s" if count != 1 else ""} uploaded.', 'success')
    return redirect(url_for('admin_order_detail', order_id=order_id))

@app.route('/admin/orders/<order_id>/final-image/<int:img_id>/delete', methods=['POST'])
def admin_delete_final_image(order_id, img_id):
    if not is_admin(): return redirect(url_for('admin_login'))
    img = OrderFinalImage.query.filter_by(id=img_id, order_id=order_id).first_or_404()
    filepath = os.path.join(FINAL_IMAGES_DIR, img.filename)
    if os.path.exists(filepath):
        os.remove(filepath)
    db.session.delete(img)
    db.session.commit()
    flash('Finished image removed.', 'success')
    return redirect(url_for('admin_order_detail', order_id=order_id))

@app.route('/admin/orders/<order_id>/edit', methods=['POST'])
def admin_edit_order(order_id):
    if not is_admin(): return redirect(url_for('admin_login'))
    order = Order.query.filter_by(order_id=order_id).first_or_404()

    # Customer details
    order.customer_name     = request.form.get('customer_name', order.customer_name).strip()
    order.customer_email    = request.form.get('customer_email', '').strip()
    order.customer_discord  = request.form.get('customer_discord', '').strip()
    order.customer_instagram= request.form.get('customer_instagram', '').strip()
    order.payment_method    = request.form.get('payment_method', '').strip()
    order.payment_username  = request.form.get('payment_username', '').strip()

    # Commission & order details
    comm_types = request.form.getlist('commission_type')
    if comm_types:
        order.commission_type = ', '.join(filter(None, comm_types))
    order.description = request.form.get('description', '').strip()
    order.price       = float(request.form.get('price', order.price) or order.price)
    order.eta         = request.form.get('eta', '').strip()
    order.notes       = request.form.get('notes', '').strip()
    order.updated_at  = datetime.utcnow()

    db.session.commit()
    auto_create_invoice(order)
    add_log(order_id, 'Order Edited', 'Customer and order details updated by admin')
    flash('Order details updated.', 'success')
    return redirect(url_for('admin_order_detail', order_id=order_id))

@app.route('/admin/orders/<order_id>/reset-pin', methods=['POST'])
def admin_reset_pin(order_id):
    if not is_admin(): return redirect(url_for('admin_login'))
    order = Order.query.filter_by(order_id=order_id).first_or_404()
    order.pin_hash = None
    db.session.commit()
    add_log(order_id, 'PIN Reset', 'Admin cleared the order PIN — customer must set a new one on next visit')
    flash('Order PIN has been reset. The customer will be asked to set a new PIN on their next visit.', 'success')
    return redirect(url_for('admin_order_detail', order_id=order_id))


@app.route('/admin/orders/<order_id>/delete', methods=['POST'])
def admin_delete_order(order_id):
    if not is_admin(): return redirect(url_for('admin_login'))
    order = Order.query.filter_by(order_id=order_id).first_or_404()
    # Delete all related records
    OrderLog.query.filter_by(order_id=order_id).delete()
    Invoice.query.filter_by(order_id=order_id).delete()
    PaymentRecord.query.filter_by(order_id=order_id).delete()
    Ticket.query.filter_by(order_id=order_id).delete()
    db.session.delete(order)
    db.session.commit()
    flash(f'Order {order_id} and all related data have been deleted.', 'success')
    return redirect(url_for('admin_orders'))

# ─── ADMIN REQUESTS ───────────────────────────────────────────────────────────

@app.route('/admin/requests')
def admin_requests():
    if not is_admin(): return redirect(url_for('admin_login'))
    reqs = CommissionRequest.query.order_by(CommissionRequest.created_at.desc()).all()
    return render_template('admin/requests.html', requests=reqs)

@app.route('/admin/requests/<req_id>/action', methods=['POST'])
def admin_request_action(req_id):
    if not is_admin(): return redirect(url_for('admin_login'))
    req = CommissionRequest.query.filter_by(request_id=req_id).first_or_404()
    action = request.form.get('action')
    if action == 'accept':
        req.status = 'Accepted'
        db.session.commit()
        flash('Request accepted.', 'success')
    elif action == 'decline':
        req.status = 'Declined'
        db.session.commit()
        flash('Request declined.', 'success')
    elif action == 'convert':
        price = float(request.form.get('price', 0) or 0)
        order = Order(
            order_id=gen_id('ORD'),
            unique_link=gen_link(),
            customer_name=req.customer_name,
            customer_email=req.customer_email,
            customer_discord=req.customer_discord,
            customer_instagram=req.customer_instagram,
            payment_method=req.payment_method,
            payment_username=req.payment_username,
            commission_type=req.commission_type,
            description=req.description,
            price=price,
            form_responses=req.form_responses,
        )
        req.status = 'Accepted'
        db.session.add(order)
        db.session.commit()
        add_log(order.order_id, 'Order Created', f'Converted from request #{req_id}')
        auto_create_invoice(order)  # Auto-generate draft invoice
        send_webhook(f"📋 **Order Created from Request** — #{order.order_id} for **{req.customer_name}**")
        delivery = send_order_link_to_customer(order)
        if delivery['sent_discord']:
            add_log(order.order_id, 'Order Link Sent', 'Sent to customer via Discord DM')
        if delivery['sent_email']:
            add_log(order.order_id, 'Order Link Sent', 'Sent to customer via email')
        flash(f'Converted to order {order.order_id}. Share link: /order/{order.unique_link}', 'success')
        return redirect(url_for('admin_order_detail', order_id=order.order_id))
    return redirect(url_for('admin_requests'))

# ─── ADMIN INVOICES ───────────────────────────────────────────────────────────

@app.route('/admin/invoices')
def admin_invoices():
    if not is_admin(): return redirect(url_for('admin_login'))
    invoices = Invoice.query.order_by(Invoice.created_at.desc()).all()
    return render_template('admin/invoices.html', invoices=invoices)

@app.route('/admin/invoices/new', methods=['GET', 'POST'])
def admin_new_invoice():
    if not is_admin(): return redirect(url_for('admin_login'))
    orders = Order.query.order_by(Order.created_at.desc()).all()
    if request.method == 'POST':
        order_id = request.form.get('order_id', '').strip()
        order = Order.query.filter_by(order_id=order_id).first()
        items_raw = request.form.getlist('item_desc[]')
        amounts_raw = request.form.getlist('item_amount[]')
        items = []
        total = 0
        for desc, amt in zip(items_raw, amounts_raw):
            try:
                a = float(amt)
                items.append({'desc': desc, 'amount': a})
                total += a
            except ValueError:
                pass
        inv = Invoice(
            invoice_id=gen_id('INV'),
            order_id=order_id,
            customer_name=order.customer_name if order else request.form.get('customer_name', ''),
            amount=total,
            items=json.dumps(items),
            due_date=request.form.get('due_date', ''),
            notes=request.form.get('notes', '')
        )
        db.session.add(inv)
        db.session.commit()
        flash(f'Invoice {inv.invoice_id} created.', 'success')
        return redirect(url_for('admin_invoices'))
    return render_template('admin/new_invoice.html', orders=orders)

@app.route('/admin/invoices/<invoice_id>/mark-paid', methods=['POST'])
def admin_mark_paid(invoice_id):
    if not is_admin(): return redirect(url_for('admin_login'))
    inv = Invoice.query.filter_by(invoice_id=invoice_id).first_or_404()
    inv.paid = True
    inv.paid_at = datetime.utcnow()
    order = Order.query.filter_by(order_id=inv.order_id).first()
    if order:
        order.payment_status = 'Paid'
        add_log(inv.order_id, 'Payment Received', f'Invoice {invoice_id} marked paid')
    amount = request.form.get('amount', inv.amount)
    pay = PaymentRecord(order_id=inv.order_id, invoice_id=invoice_id,
                        amount=float(amount), notes=request.form.get('notes', ''))
    db.session.add(pay)
    db.session.commit()
    send_webhook(
        f"💸 **Payment Received** — Invoice #{invoice_id}",
        embeds=[{
            'color': 0x22c55e,
            'fields': [
                {'name': 'Order', 'value': inv.order_id, 'inline': True},
                {'name': 'Amount', 'value': f'${inv.amount:.2f}', 'inline': True},
                {'name': 'Customer', 'value': inv.customer_name or 'N/A', 'inline': True},
            ],
            'timestamp': datetime.utcnow().isoformat()
        }]
    )
    flash('Invoice marked as paid.', 'success')
    return redirect(url_for('admin_invoices'))

# ─── ADMIN TICKETS ────────────────────────────────────────────────────────────

@app.route('/admin/tickets')
def admin_tickets():
    if not is_admin(): return redirect(url_for('admin_login'))
    tickets = Ticket.query.order_by(Ticket.created_at.desc()).all()
    now = datetime.utcnow()
    return render_template('admin/tickets.html', tickets=tickets, now=now)

@app.route('/admin/tickets/<ticket_id>', methods=['GET', 'POST'])
def admin_ticket_detail(ticket_id):
    if not is_admin(): return redirect(url_for('admin_login'))
    ticket = Ticket.query.filter_by(ticket_id=ticket_id).first_or_404()
    messages = TicketMessage.query.filter_by(ticket_id=ticket_id).order_by(TicketMessage.created_at).all()
    if request.method == 'POST':
        action = request.form.get('action')
        if action == 'reply':
            message = request.form.get('message', '').strip()
            if message:
                msg = TicketMessage(ticket_id=ticket_id, sender='admin', message=message)
                db.session.add(msg)
                db.session.commit()
                send_webhook(
                    content="",
                    embeds=[{
                        'title': f"🎨  ADMIN REPLY — #{ticket_id}",
                        'description': f"Cioda has replied to ticket **#{ticket_id}**.\n\u200b",
                        'color': 0xc084fc,
                        'fields': [
                            {'name': '📦  Order ID', 'value': f"`{ticket.order_id or 'N/A'}`",  'inline': True},
                            {'name': '👤  Customer', 'value': ticket.customer_name,               'inline': True},
                            {'name': '\u200b',       'value': '\u200b',                        'inline': False},
                            {'name': '📌  Subject',  'value': ticket.subject or '(no subject)',  'inline': False},
                            {'name': '💬  Reply',    'value': message[:1000],                    'inline': False},
                            {'name': '🔗  Admin Link',  'value': f"{request.host_url}admin/tickets/{ticket_id}", 'inline': True},
                            {'name': '💬  Ticket Link', 'value': f"{request.host_url}order/{ticket.order_link}/ticket/{ticket_id}" if ticket.order_link else 'N/A', 'inline': True},
                        ],
                        'footer': {'text': f'Ticket {ticket_id}'},
                        'timestamp': datetime.utcnow().isoformat()
                    }],
                    webhook_type='ticket'
                )
                # ── Mirror admin reply to Discord thread ──
                _settings = SiteSettings.query.first()
                if ticket.discord_thread_id and _settings.discord_bot_token:
                    _send_to_discord_thread(
                        ticket.discord_thread_id,
                        f"**🎨 Admin reply**\n{message[:1800]}",
                        _settings.discord_bot_token,
                    )
        elif action == 'close':
            ticket.status = 'Closed'
            db.session.commit()
            send_webhook(
                content="",
                embeds=[{
                    'title': f"🔒  TICKET CLOSED — #{ticket_id}",
                    'description': f"Ticket **#{ticket_id}** has been closed by admin.\n\u200b",
                    'color': 0x374151,
                    'fields': [
                        {'name': '📦  Order ID', 'value': f"`{ticket.order_id or 'N/A'}`", 'inline': True},
                        {'name': '👤  Customer', 'value': ticket.customer_name,              'inline': True},
                        {'name': '📌  Subject',  'value': ticket.subject or '(no subject)', 'inline': False},
                    ],
                    'footer': {'text': f'Ticket {ticket_id}'},
                    'timestamp': datetime.utcnow().isoformat()
                }],
                webhook_type='ticket'
            )
            flash('Ticket closed.', 'success')
        return redirect(url_for('admin_ticket_detail', ticket_id=ticket_id))
    return render_template('admin/ticket_detail.html', ticket=ticket, messages=messages, now=datetime.utcnow())

# ─── ADMIN SETTINGS ───────────────────────────────────────────────────────────

@app.route('/admin/settings', methods=['GET', 'POST'])
def admin_settings():
    if not is_admin(): return redirect(url_for('admin_login'))
    settings = get_settings()
    if request.method == 'POST':
        settings.discord_webhook = request.form.get('discord_webhook', '').strip()
        settings.discord_webhook_status = request.form.get('discord_webhook_status', '').strip()
        settings.discord_webhook_tickets = request.form.get('discord_webhook_tickets', '').strip()
        settings.discord_bot_token      = request.form.get('discord_bot_token', '').strip()
        settings.discord_ticket_channel = request.form.get('discord_ticket_channel', '').strip()
        settings.discord_bot_secret     = request.form.get('discord_bot_secret', '').strip()
        settings.cashapp_api_key = request.form.get('cashapp_api_key', '').strip()
        settings.closed_message = request.form.get('closed_message', '').strip()
        settings.reopen_date    = request.form.get('reopen_date', '').strip()
        settings.close_date          = request.form.get('close_date', '').strip()
        try:
            settings.max_ref_images_default = int(request.form.get('max_ref_images_default', 3))
        except (ValueError, TypeError):
            settings.max_ref_images_default = 3
        settings.banner_enabled   = request.form.get('banner_enabled') == 'on'
        settings.banner_text      = request.form.get('banner_text', '').strip()
        settings.banner_style     = request.form.get('banner_style', 'info')
        settings.banner_link      = request.form.get('banner_link', '').strip()
        settings.banner_link_text = request.form.get('banner_link_text', '').strip()

        settings.site_url = request.form.get('site_url', '').strip().rstrip('/')
        settings.trello_api_key = request.form.get('trello_api_key', '').strip()
        settings.discord_panel_channel    = request.form.get('discord_panel_channel', '').strip()
        settings.discord_bot_internal_url = request.form.get('discord_bot_internal_url', '').strip().rstrip('/')
        settings.discord_client_id = request.form.get('discord_client_id', '').strip()
        settings.discord_guild_id  = request.form.get('discord_guild_id', '').strip()
        settings.smtp_host     = request.form.get('smtp_host', '').strip()
        settings.smtp_username = request.form.get('smtp_username', '').strip()
        settings.smtp_from     = request.form.get('smtp_from', '').strip()
        try:
            settings.smtp_port = int(request.form.get('smtp_port', 465))
        except (ValueError, TypeError):
            settings.smtp_port = 465
        # Secret fields: an empty submission keeps whatever's already stored, so the
        # settings page never has to re-display (or force re-entering) a live secret.
        trello_secret = request.form.get('trello_api_secret', '').strip()
        if trello_secret:
            settings.trello_api_secret = trello_secret
        discord_secret = request.form.get('discord_client_secret', '').strip()
        if discord_secret:
            settings.discord_client_secret = discord_secret
        smtp_pw = request.form.get('smtp_password', '').strip()
        if smtp_pw:
            settings.smtp_password = smtp_pw

        db.session.commit()
        flash('Settings saved.', 'success')
    return render_template('admin/settings.html', settings=settings)

@app.route('/admin/toggle-commissions', methods=['POST'])
def admin_toggle_commissions():
    if not is_admin(): return redirect(url_for('admin_login'))
    settings = get_settings()
    was_closed = not settings.commissions_open
    settings.commissions_open = not settings.commissions_open
    db.session.commit()
    state = 'OPEN' if settings.commissions_open else 'CLOSED'
    flash(f'Commissions are now {state}.', 'success')
    if was_closed and settings.commissions_open:
        if request.form.get('notify_ping_list') == '1':
            result = notify_ping_list_commissions_open()
            if result['total']:
                flash(f"Pinged {result['sent']}/{result['total']} subscribers on Discord.", 'info')
            if result['email_total']:
                flash(f"Emailed {result['email_sent']}/{result['email_total']} subscribers.", 'info')
        else:
            flash('Notifications skipped (test open).', 'info')
    return redirect(request.referrer or url_for('admin_dashboard'))

# ─── ADMIN TRELLO INTEGRATION ─────────────────────────────────────────────────

@app.route('/admin/trello')
def admin_trello():
    if not is_admin(): return redirect(url_for('admin_login'))
    conn = get_trello_connection()
    cards = []
    board_lists = []
    if conn.status == 'connected' and conn.list_id:
        cards = trello_api_get(f'lists/{conn.list_id}/cards',
                                {'fields': 'name,due,shortUrl,labels'}) or []
    if conn.status == 'connected' and conn.board_id:
        board_lists = trello_api_get(f'boards/{conn.board_id}/lists', {'fields': 'name', 'filter': 'open'}) or []
    subscribers = PingListSubscriber.query.filter_by(active=True).order_by(PingListSubscriber.added_at.desc()).all()
    status_map = {m.trello_list_id: m.order_status for m in TrelloListStatusMap.query.all()}
    return render_template('admin/trello.html', conn=conn, cards=cards,
                            configured=trello_configured(), subscribers=subscribers,
                            board_lists=board_lists, status_map=status_map,
                            order_statuses=ORDER_STATUSES)

@app.route('/admin/trello/connect')
def trello_connect():
    if not is_admin(): return redirect(url_for('admin_login'))
    if not trello_configured():
        flash('Trello isn\'t configured yet — add your Trello API key and secret in Settings first.', 'error')
        return redirect(url_for('admin_trello'))
    from requests_oauthlib import OAuth1Session
    callback_url = url_for('trello_callback', _external=True)
    oauth = OAuth1Session(trello_api_key(), client_secret=trello_api_secret(), callback_uri=callback_url)
    try:
        fetch_response = oauth.fetch_request_token(TRELLO_REQUEST_TOKEN_URL)
    except Exception as e:
        flash(f'Could not start the Trello connection: {e}', 'error')
        return redirect(url_for('admin_trello'))
    # Stashed server-side only, keyed to this admin session — this is our CSRF guard;
    # the callback is rejected unless oauth_token matches what we stored here.
    session['trello_req_token']        = fetch_response.get('oauth_token')
    session['trello_req_token_secret'] = fetch_response.get('oauth_token_secret')
    auth_url = (f"{TRELLO_AUTHORIZE_URL}?oauth_token={fetch_response.get('oauth_token')}"
                f"&name=Cioda%20Commissions&scope=read,write&expiration=never")
    return redirect(auth_url)

@app.route('/admin/trello/callback')
def trello_callback():
    if not is_admin(): return redirect(url_for('admin_login'))
    req_token        = session.pop('trello_req_token', None)
    req_token_secret = session.pop('trello_req_token_secret', None)
    oauth_token    = request.args.get('oauth_token')
    oauth_verifier = request.args.get('oauth_verifier')
    if not oauth_verifier or not req_token or oauth_token != req_token:
        flash('Trello authorization failed or was cancelled.', 'error')
        return redirect(url_for('admin_trello'))
    from requests_oauthlib import OAuth1Session
    oauth = OAuth1Session(trello_api_key(), client_secret=trello_api_secret(),
                           resource_owner_key=req_token, resource_owner_secret=req_token_secret,
                           verifier=oauth_verifier)
    try:
        tokens = oauth.fetch_access_token(TRELLO_ACCESS_TOKEN_URL)
    except Exception as e:
        flash(f'Trello authorization failed: {e}', 'error')
        return redirect(url_for('admin_trello'))
    access_token        = tokens.get('oauth_token')
    access_token_secret = tokens.get('oauth_token_secret')
    try:
        me = requests.get(f'{TRELLO_API_BASE}/members/me',
                           params={'key': trello_api_key(), 'token': access_token,
                                   'fields': 'username,fullName,avatarUrl'}, timeout=10).json()
    except Exception:
        me = {}
    conn = get_trello_connection()
    conn.member_id            = me.get('id', '')
    conn.username             = me.get('username', '')
    conn.full_name            = me.get('fullName', '')
    conn.avatar_url           = (me.get('avatarUrl') + '/50.png') if me.get('avatarUrl') else ''
    conn.access_token         = trello_encrypt(access_token)
    conn.access_token_secret  = trello_encrypt(access_token_secret)
    conn.status               = 'connected'
    conn.connected_at         = datetime.utcnow()
    conn.last_synced_at       = datetime.utcnow()
    db.session.commit()
    flash('Trello connected.', 'success')
    return redirect(url_for('admin_trello'))

@app.route('/admin/trello/disconnect', methods=['POST'])
def trello_disconnect():
    if not is_admin(): return redirect(url_for('admin_login'))
    conn = get_trello_connection()
    token = trello_decrypt(conn.access_token)
    if token and trello_api_key():
        if conn.webhook_id:
            try:
                requests.delete(f'{TRELLO_API_BASE}/webhooks/{conn.webhook_id}',
                                 params={'key': trello_api_key(), 'token': token}, timeout=10)
            except Exception:
                pass
        try:
            requests.delete(f'{TRELLO_API_BASE}/tokens/{token}',
                             params={'key': trello_api_key(), 'token': token}, timeout=10)
        except Exception:
            pass  # Best-effort revoke — we clear our own copy regardless.
    conn.status = 'disconnected'
    conn.member_id = conn.username = conn.full_name = conn.avatar_url = ''
    conn.access_token = conn.access_token_secret = ''
    conn.workspace_id = conn.workspace_name = ''
    conn.board_id = conn.board_name = ''
    conn.list_id = conn.list_name = ''
    conn.webhook_id = conn.webhook_callback_url = ''
    db.session.commit()
    flash('Trello disconnected.', 'success')
    return redirect(url_for('admin_trello'))

@app.route('/admin/trello/sync-orders', methods=['POST'])
def trello_sync_orders_route():
    if not is_admin(): return redirect(url_for('admin_login'))
    result = sync_trello_orders(force=True)
    if not result['ran']:
        flash('Connect Trello and pick a list first.', 'error')
    else:
        flash(f"Synced from Trello — {result['created']} new order(s) created, "
              f"{result['marked_paid']} marked Paid, {result['skipped']} already up to date.", 'success')
    return redirect(url_for('admin_trello'))

@app.route('/admin/trello/status-map', methods=['POST'])
def trello_save_status_map():
    if not is_admin(): return redirect(url_for('admin_login'))
    for key, value in request.form.items():
        if not key.startswith('list_'):
            continue
        list_id = key[len('list_'):]
        entry = TrelloListStatusMap.query.filter_by(trello_list_id=list_id).first()
        if not entry:
            if not value:
                continue
            entry = TrelloListStatusMap(trello_list_id=list_id)
            db.session.add(entry)
        entry.trello_list_name = request.form.get(f'listname_{list_id}', '')
        entry.order_status = value
    db.session.commit()
    flash('List → status mapping saved.', 'success')
    return redirect(url_for('admin_trello'))

@app.route('/admin/trello/webhook/enable', methods=['POST'])
def trello_webhook_enable():
    if not is_admin(): return redirect(url_for('admin_login'))
    conn = get_trello_connection()
    if conn.status != 'connected' or not conn.board_id:
        flash('Connect Trello and pick a board first.', 'error')
        return redirect(url_for('admin_trello'))
    token = trello_decrypt(conn.access_token)
    callback_url = url_for('trello_webhook_receive', _external=True)
    try:
        r = requests.post(f'{TRELLO_API_BASE}/webhooks/', params={
            'key': trello_api_key(), 'token': token,
            'callbackURL': callback_url,
            'idModel': conn.board_id,
            'description': 'Cioda Commissions live sync',
        }, timeout=15)
        r.raise_for_status()
        data = r.json()
    except Exception as e:
        flash(f'Could not enable live sync — Trello said: {e}', 'error')
        return redirect(url_for('admin_trello'))
    conn.webhook_id = data.get('id', '')
    conn.webhook_callback_url = callback_url
    db.session.commit()
    flash('Live sync enabled — moving a card will now update its order status automatically.', 'success')
    return redirect(url_for('admin_trello'))

@app.route('/admin/trello/webhook/disable', methods=['POST'])
def trello_webhook_disable():
    if not is_admin(): return redirect(url_for('admin_login'))
    conn = get_trello_connection()
    if conn.webhook_id:
        token = trello_decrypt(conn.access_token)
        try:
            requests.delete(f'{TRELLO_API_BASE}/webhooks/{conn.webhook_id}',
                             params={'key': trello_api_key(), 'token': token}, timeout=10)
        except Exception:
            pass
    conn.webhook_id = ''
    conn.webhook_callback_url = ''
    db.session.commit()
    flash('Live sync disabled.', 'success')
    return redirect(url_for('admin_trello'))

def _verify_trello_webhook_signature(request_obj, callback_url, secret):
    header_sig = request_obj.headers.get('X-Trello-Webhook')
    if not header_sig or not secret:
        return False
    computed = base64.b64encode(
        hmac.new(secret.encode(), request_obj.get_data() + callback_url.encode(), hashlib.sha1).digest()
    ).decode()
    return hmac.compare_digest(header_sig, computed)

@app.route('/api/trello/webhook', methods=['HEAD', 'POST'])
def trello_webhook_receive():
    # Trello sends a HEAD request to verify the URL before creating the webhook.
    if request.method == 'HEAD':
        return '', 200

    conn = get_trello_connection()
    if not conn.webhook_callback_url or not _verify_trello_webhook_signature(
        request, conn.webhook_callback_url, trello_api_secret()
    ):
        abort(403)

    payload = request.get_json(silent=True) or {}
    action = payload.get('action', {})
    data = action.get('data', {})
    list_after = data.get('listAfter')
    card = data.get('card')

    if action.get('type') == 'updateCard' and list_after and card:
        mapping = TrelloCardMapping.query.filter_by(trello_card_id=card.get('id')).first()
        if mapping:
            order = Order.query.filter_by(order_id=mapping.order_id).first()
            if order:
                status_entry = TrelloListStatusMap.query.filter_by(trello_list_id=list_after.get('id')).first()
                if status_entry and status_entry.order_status and order.status != status_entry.order_status:
                    old_status = order.status
                    order.status = status_entry.order_status
                    db.session.commit()
                    add_log(order.order_id, 'Status Updated (Trello)',
                            f'{old_status} → {order.status} (card moved to "{list_after.get("name", "")}")')
                # Cards landing in the configured 'in progress' list have already been paid for.
                if list_after.get('id') == conn.list_id and order.payment_status != 'Paid':
                    old_payment = order.payment_status
                    order.payment_status = 'Paid'
                    db.session.commit()
                    add_log(order.order_id, 'Payment Status Updated (Trello)',
                            f'{old_payment} → Paid (card moved to "{list_after.get("name", "")}")')
            mapping.trello_list_id = list_after.get('id', mapping.trello_list_id)
            db.session.commit()

    return '', 200

@app.route('/admin/trello/workspaces')
def trello_workspaces():
    if not is_admin(): return jsonify([])
    data = trello_api_get('members/me/organizations', {'fields': 'displayName,name'}) or []
    return jsonify([{'id': o['id'], 'name': o.get('displayName') or o.get('name')} for o in data])

@app.route('/admin/trello/boards')
def trello_boards():
    if not is_admin(): return jsonify([])
    workspace_id = request.args.get('workspace_id', '').strip()
    data = trello_api_get('members/me/boards', {'fields': 'name,idOrganization', 'filter': 'open'}) or []
    if workspace_id:
        data = [b for b in data if b.get('idOrganization') == workspace_id]
    return jsonify([{'id': b['id'], 'name': b['name']} for b in data])

@app.route('/admin/trello/boards/<board_id>/lists')
def trello_lists(board_id):
    if not is_admin(): return jsonify([])
    data = trello_api_get(f'boards/{board_id}/lists', {'fields': 'name', 'filter': 'open'}) or []
    return jsonify([{'id': l['id'], 'name': l['name']} for l in data])

@app.route('/admin/trello/settings', methods=['POST'])
def trello_save_settings():
    if not is_admin(): return redirect(url_for('admin_login'))
    conn = get_trello_connection()
    conn.workspace_id   = request.form.get('workspace_id', '').strip()
    conn.workspace_name = request.form.get('workspace_name', '').strip()
    conn.board_id       = request.form.get('board_id', '').strip()
    conn.board_name     = request.form.get('board_name', '').strip()
    conn.list_id        = request.form.get('list_id', '').strip()
    conn.list_name      = request.form.get('list_name', '').strip()
    conn.last_synced_at = datetime.utcnow()
    db.session.commit()
    flash('Trello board/list saved.', 'success')
    return redirect(url_for('admin_trello'))

@app.route('/admin/trello/ping-list/settings', methods=['POST'])
def trello_save_ping_list():
    if not is_admin(): return redirect(url_for('admin_login'))
    conn = get_trello_connection()
    conn.ping_board_id  = request.form.get('ping_board_id', '').strip()
    conn.ping_list_id   = request.form.get('ping_list_id', '').strip()
    conn.ping_list_name = request.form.get('ping_list_name', '').strip()
    db.session.commit()
    flash('Ping list saved.', 'success')
    return redirect(url_for('admin_trello'))

@app.route('/admin/trello/ping-list/import', methods=['POST'])
def trello_ping_list_import():
    if not is_admin(): return redirect(url_for('admin_login'))
    conn = get_trello_connection()
    if not conn.ping_list_id:
        flash('Pick a ping list first.', 'error')
        return redirect(url_for('admin_trello'))
    cards = trello_api_get(f'lists/{conn.ping_list_id}/cards', {'fields': 'name'}) or []
    added = skipped = 0
    new_subs = []
    for c in cards:
        handle = parse_discord_username(c.get('name', ''))
        if not handle:
            skipped += 1
            continue
        sub = PingListSubscriber.query.filter_by(trello_card_id=c['id']).first()
        if not sub:
            sub = PingListSubscriber(trello_card_id=c['id'], unsubscribe_token=uuid.uuid4().hex)
            db.session.add(sub)
            added += 1
            new_subs.append(sub)
        sub.discord_username = handle
        sub.trello_card_name = c.get('name', '')
        sub.active = True
    db.session.commit()
    if new_subs:
        settings = get_settings()
        for sub in new_subs:
            unsubscribe_url = url_for('notify_me_unsubscribe', token=sub.unsubscribe_token, _external=True)
            if send_discord_welcome_dm(settings, sub.discord_username, unsubscribe_url):
                sub.welcomed = True
        db.session.commit()
    flash(f'Imported {added} new subscriber(s) — {skipped} card(s) skipped (no "(discord)" tag).', 'success')
    return redirect(url_for('admin_trello'))

@app.route('/admin/trello/ping-list/notify', methods=['POST'])
def trello_ping_list_notify():
    if not is_admin(): return redirect(url_for('admin_login'))
    result = notify_ping_list_commissions_open()
    if not result['total'] and not result['email_total']:
        flash('No subscribers to notify.', 'error')
    else:
        if result['total']:
            flash(f"Pinged {result['sent']}/{result['total']} subscribers on Discord.", 'success')
        if result['email_total']:
            flash(f"Emailed {result['email_sent']}/{result['email_total']} subscribers.", 'success')
    return redirect(url_for('admin_trello'))

@app.route('/admin/trello/ping-list/<int:sub_id>/remove', methods=['POST'])
def trello_ping_list_remove(sub_id):
    if not is_admin(): return redirect(url_for('admin_login'))
    sub = PingListSubscriber.query.get_or_404(sub_id)
    db.session.delete(sub)
    db.session.commit()
    flash('Removed from ping list.', 'success')
    return redirect(url_for('admin_trello'))

@app.route('/admin/trello/cards/<card_id>')
def trello_card_detail(card_id):
    """Full card info for the read-a-card modal — name, desc, due, labels, members, checklists."""
    if not is_admin(): return jsonify({'error': 'unauthorized'}), 403
    card = trello_api_get(f'cards/{card_id}', {
        'fields': 'name,desc,due,start,url,shortUrl,idList,idBoard',
        'members': 'true', 'member_fields': 'fullName,username',
        'labels': 'true',
        'checklists': 'all', 'checklist_fields': 'name',
    })
    if card is None:
        return jsonify({'error': 'Could not load that card from Trello.'}), 502
    return jsonify(card)

@app.route('/admin/trello/lists/<list_id>/cards')
def trello_list_cards(list_id):
    """Cards in the selected list — used by the order page's 'link a card' picker."""
    if not is_admin(): return jsonify([])
    data = trello_api_get(f'lists/{list_id}/cards', {'fields': 'name,shortUrl'}) or []
    return jsonify([{'id': c['id'], 'name': c['name'], 'url': c.get('shortUrl', '')} for c in data])

@app.route('/admin/orders/<order_id>/trello/create', methods=['POST'])
def order_trello_create(order_id):
    if not is_admin(): return redirect(url_for('admin_login'))
    order = Order.query.filter_by(order_id=order_id).first_or_404()
    conn = get_trello_connection()
    if conn.status != 'connected' or not conn.list_id:
        flash('Connect Trello and pick a list under Admin → Trello first.', 'error')
        return redirect(url_for('admin_order_detail', order_id=order_id))
    card = trello_api_write('POST', 'cards', {
        'idList': conn.list_id,
        'name': f'{order.customer_name} — {order.commission_type or "Commission"} ({order.order_id})',
        'desc': order.description or '',
    })
    if not card:
        flash('Could not create the Trello card.', 'error')
        return redirect(url_for('admin_order_detail', order_id=order_id))
    _save_trello_mapping(order_id, card)
    add_log(order_id, 'Trello card created', card.get('name'))
    flash('Trello card created and linked to this order.', 'success')
    return redirect(url_for('admin_order_detail', order_id=order_id))

@app.route('/admin/orders/<order_id>/trello/link', methods=['POST'])
def order_trello_link(order_id):
    if not is_admin(): return redirect(url_for('admin_login'))
    Order.query.filter_by(order_id=order_id).first_or_404()
    card_id = request.form.get('card_id', '').strip()
    if not card_id:
        flash('No card selected.', 'error')
        return redirect(url_for('admin_order_detail', order_id=order_id))
    card = trello_api_get(f'cards/{card_id}', {'fields': 'name,shortUrl,idBoard,idList'})
    if not card:
        flash('Could not find that Trello card.', 'error')
        return redirect(url_for('admin_order_detail', order_id=order_id))
    _save_trello_mapping(order_id, card)
    add_log(order_id, 'Trello card linked', card.get('name'))
    flash('Trello card linked to this order.', 'success')
    return redirect(url_for('admin_order_detail', order_id=order_id))

@app.route('/admin/orders/<order_id>/trello/unlink', methods=['POST'])
def order_trello_unlink(order_id):
    if not is_admin(): return redirect(url_for('admin_login'))
    TrelloCardMapping.query.filter_by(order_id=order_id).delete()
    db.session.commit()
    add_log(order_id, 'Trello card unlinked')
    flash('Trello card unlinked from this order.', 'success')
    return redirect(url_for('admin_order_detail', order_id=order_id))

@app.route('/admin/orders/<order_id>/trello/delete', methods=['POST'])
def order_trello_delete(order_id):
    """Actually deletes the card from Trello (not just unlinking it locally)."""
    if not is_admin(): return redirect(url_for('admin_login'))
    mapping = TrelloCardMapping.query.filter_by(order_id=order_id).first()
    if not mapping:
        flash('No Trello card linked to this order.', 'error')
        return redirect(url_for('admin_order_detail', order_id=order_id))
    card_name = mapping.trello_card_name
    result = trello_api_write('DELETE', f'cards/{mapping.trello_card_id}')
    if result is None:
        flash('Could not delete the card from Trello — it may already be gone, or the connection has an issue.', 'error')
        return redirect(url_for('admin_order_detail', order_id=order_id))
    db.session.delete(mapping)
    db.session.commit()
    add_log(order_id, 'Trello card deleted', card_name)
    flash(f'Deleted "{card_name}" from Trello.', 'success')
    return redirect(url_for('admin_order_detail', order_id=order_id))

def _save_trello_mapping(order_id, card):
    mapping = TrelloCardMapping.query.filter_by(order_id=order_id).first()
    if not mapping:
        mapping = TrelloCardMapping(order_id=order_id)
        db.session.add(mapping)
    mapping.trello_card_id   = card['id']
    mapping.trello_board_id  = card.get('idBoard', '')
    mapping.trello_list_id   = card.get('idList', '')
    mapping.trello_card_name = card.get('name', '')
    mapping.trello_card_url  = card.get('shortUrl', '')
    mapping.last_synced_at   = datetime.utcnow()
    db.session.commit()

TRELLO_AUTO_SYNC_MIN_GAP_SECS = 240  # background loop won't re-hit the API more often than this

def sync_trello_orders(force=False):
    """Pulls cards from the configured 'in progress' Trello list — cards here are commissions
    that have already been paid for — and:
      1. auto-creates an Order (marked Paid) for any card that isn't tracked yet
      2. marks any already-tracked order still sitting in this list as Paid, in case it
         wasn't already (e.g. it was created manually and payment status wasn't set)
    Never sends a Discord notification — this is a silent background/admin-triggered import,
    not a customer-facing 'new order' event. With force=False (background loop), throttled so
    redundant gunicorn workers don't all hit the Trello API at once; force=True always runs."""
    conn = get_trello_connection()
    if conn.status != 'connected' or not conn.list_id:
        return {'created': 0, 'skipped': 0, 'marked_paid': 0, 'ran': False}
    if not force and conn.last_synced_at and \
       (datetime.utcnow() - conn.last_synced_at).total_seconds() < TRELLO_AUTO_SYNC_MIN_GAP_SECS:
        return {'created': 0, 'skipped': 0, 'marked_paid': 0, 'ran': False}

    cards = trello_api_get(f'lists/{conn.list_id}/cards', {'fields': 'name,desc,shortUrl,idBoard,idList'})
    conn.last_synced_at = datetime.utcnow()
    db.session.commit()
    if cards is None:
        return {'created': 0, 'skipped': 0, 'marked_paid': 0, 'ran': True}

    created = skipped = marked_paid = 0
    for c in cards:
        existing = TrelloCardMapping.query.filter_by(trello_card_id=c['id']).first()
        if existing:
            skipped += 1
            order = Order.query.filter_by(order_id=existing.order_id).first()
            if order and order.payment_status != 'Paid':
                old_payment = order.payment_status
                order.payment_status = 'Paid'
                db.session.commit()
                add_log(order.order_id, 'Payment Status Updated (Trello)',
                        f'{old_payment} → Paid — card is in the in-progress list')
                marked_paid += 1
            continue
        card_name = (c.get('name') or 'Trello Import').strip()
        order = Order(
            order_id=gen_id('ORD'),
            unique_link=gen_link(),
            customer_name=card_name[:200],
            commission_type=card_name[:500],
            description=c.get('desc', '') or '',
            price=0.0,
            status='In Progress',
            payment_status='Paid',
        )
        db.session.add(order)
        db.session.commit()
        _save_trello_mapping(order.order_id, c)
        add_log(order.order_id, 'Order Auto-Created from Trello',
                f'Imported from card "{card_name}" — marked Paid (in-progress list). Review customer details and price.')
        created += 1
    return {'created': created, 'skipped': skipped, 'marked_paid': marked_paid, 'ran': True}

def _trello_background_sync_loop():
    while True:
        time.sleep(TRELLO_AUTO_SYNC_MIN_GAP_SECS)
        try:
            with app.app_context():
                sync_trello_orders(force=False)
        except Exception as exc:
            print(f'[TrelloSync] background sync error: {exc}')

# ─── ADMIN FORM EDITOR ────────────────────────────────────────────────────────

@app.route('/admin/form', methods=['GET', 'POST'])
def admin_form_editor():
    if not is_admin(): return redirect(url_for('admin_login'))
    if request.method == 'POST':
        action = request.form.get('action')
        if action == 'add':
            label = request.form.get('label', '').strip()
            field_type = request.form.get('field_type', 'text')
            required = request.form.get('required') == 'on'
            options = request.form.get('options', '').strip()
            opts = [o.strip() for o in options.split('\n') if o.strip()] if options else []
            max_idx = db.session.query(db.func.max(FormField.order_index)).scalar() or 0
            field = FormField(
                field_key=f"field_{uuid.uuid4().hex[:8]}",
                label=label,
                field_type=field_type,
                required=required,
                options=json.dumps(opts),
                order_index=max_idx + 1
            )
            db.session.add(field)
            db.session.commit()
            flash('Field added.', 'success')
        elif action == 'delete':
            fid = request.form.get('field_id')
            field = FormField.query.get(fid)
            if field:
                db.session.delete(field)
                db.session.commit()
                flash('Field deleted.', 'success')
        elif action == 'toggle':
            fid = request.form.get('field_id')
            field = FormField.query.get(fid)
            if field:
                field.active = not field.active
                db.session.commit()
        return redirect(url_for('admin_form_editor'))
    fields = FormField.query.order_by(FormField.order_index).all()
    return render_template('admin/form_editor.html', fields=fields)


# ─── ADMIN COMMISSION TYPES ───────────────────────────────────────────────────

@app.route('/admin/commission-types')
def admin_commission_types():
    if not is_admin(): return redirect(url_for('admin_login'))
    types = CommissionType.query.order_by(
        CommissionType.category, CommissionType.order_index, CommissionType.id
    ).all()
    categories = sorted(set(t.category for t in CommissionType.query.all()))
    return render_template('admin/commission_types.html', types=types, categories=categories)

@app.route('/admin/commission-types/add', methods=['POST'])
def admin_add_commission_type():
    if not is_admin(): return redirect(url_for('admin_login'))
    category  = request.form.get('category', '').strip()
    custom_cat= request.form.get('custom_category', '').strip()
    type_name = request.form.get('type_name', '').strip()
    price     = float(request.form.get('price', 0) or 0)
    if custom_cat:
        category = custom_cat
    if category and type_name:
        max_idx = db.session.query(db.func.max(CommissionType.order_index)).scalar() or 0
        ct = CommissionType(category=category, type_name=type_name,
                            price=price, order_index=max_idx + 1)
        db.session.add(ct)
        db.session.commit()
        flash(f'Added "{type_name}" to {category}.', 'success')
    return redirect(url_for('admin_commission_types'))

@app.route('/admin/commission-types/<int:type_id>/update', methods=['POST'])
def admin_update_commission_type(type_id):
    if not is_admin(): return redirect(url_for('admin_login'))
    ct = CommissionType.query.get_or_404(type_id)
    ct.category  = request.form.get('category',  ct.category).strip()
    ct.type_name = request.form.get('type_name', ct.type_name).strip()
    ct.price     = float(request.form.get('price', ct.price) or ct.price)
    db.session.commit()
    flash(f'Updated "{ct.type_name}".', 'success')
    return redirect(url_for('admin_commission_types'))

@app.route('/admin/commission-types/<int:type_id>/toggle', methods=['POST'])
def admin_toggle_commission_type(type_id):
    if not is_admin(): return redirect(url_for('admin_login'))
    ct = CommissionType.query.get_or_404(type_id)
    ct.active = not ct.active
    db.session.commit()
    return redirect(url_for('admin_commission_types'))

@app.route('/admin/commission-types/<int:type_id>/delete', methods=['POST'])
def admin_delete_commission_type(type_id):
    if not is_admin(): return redirect(url_for('admin_login'))
    ct = CommissionType.query.get_or_404(type_id)
    name = ct.type_name
    db.session.delete(ct)
    db.session.commit()
    flash(f'Deleted "{name}".', 'success')
    return redirect(url_for('admin_commission_types'))


@app.route('/admin/commission-types/<int:type_id>/ref-images', methods=['POST'])
def admin_commission_type_ref_images(type_id):
    if not is_admin(): return redirect(url_for('admin_login'))
    ct = CommissionType.query.get_or_404(type_id)
    ct.allow_ref_images = request.form.get('allow_ref_images') == 'on'
    try:
        ct.max_ref_images = max(0, int(request.form.get('max_ref_images', 3)))
    except (ValueError, TypeError):
        ct.max_ref_images = 3
    db.session.commit()
    return redirect(url_for('admin_commission_types'))

@app.route('/admin/commission-types/reorder', methods=['POST'])
def admin_reorder_commission_types():
    if not is_admin(): return redirect(url_for('admin_login'))
    order = request.json.get('order', [])
    for idx, type_id in enumerate(order):
        ct = CommissionType.query.get(type_id)
        if ct:
            ct.order_index = idx
    db.session.commit()
    return jsonify({'ok': True})




@app.route('/ref-uploads/<filename>')
def serve_ref_upload(filename):
    ref_dir = os.path.join(app.static_folder, 'ref_uploads')
    return send_from_directory(ref_dir, filename)

@app.route('/gallery/<filename>')
def serve_gallery_image(filename):
    """Explicitly serve gallery images — ensures they work regardless of static config."""
    return send_from_directory(GALLERY_DIR, filename)

@app.route('/order-log-image/<filename>')
def serve_order_log_image(filename):
    return send_from_directory(ORDER_LOG_IMAGES_DIR, filename)

@app.route('/final-image/<filename>')
def serve_final_image(filename):
    return send_from_directory(FINAL_IMAGES_DIR, filename)


# ─── DISCOUNT CODES ──────────────────────────────────────────────────────────

def is_code_valid(code_str):
    """Returns (discount_obj_or_None, error_message)."""
    code_str = code_str.strip().upper()
    dc = DiscountCode.query.filter_by(code=code_str, active=True).first()
    if not dc:
        return None, 'Invalid discount code.'
    if dc.max_uses > 0 and dc.uses >= dc.max_uses:
        return None, 'This code has reached its usage limit.'
    if dc.expires:
        try:
            exp = datetime.strptime(dc.expires, '%m/%d/%Y')
            if datetime.utcnow() > exp:
                return None, 'This code has expired.'
        except ValueError:
            pass
    return dc, None

@app.route('/api/discount', methods=['POST'])
def api_discount():
    """AJAX endpoint called from the request form to validate a code."""
    code_str = request.json.get('code', '').strip().upper()
    dc, err  = is_code_valid(code_str)
    if err:
        return jsonify({'valid': False, 'error': err})
    if dc.type == 'percent':
        label = f'{dc.value:.0f}% off'
    else:
        label = f'${dc.value:.2f} off'
    return jsonify({'valid': True, 'type': dc.type, 'value': dc.value, 'label': label})

@app.route('/admin/discounts')
def admin_discounts():
    if not is_admin(): return redirect(url_for('admin_login'))
    codes = DiscountCode.query.order_by(DiscountCode.created_at.desc()).all()
    return render_template('admin/discounts.html', codes=codes)

@app.route('/admin/discounts/add', methods=['POST'])
def admin_add_discount():
    if not is_admin(): return redirect(url_for('admin_login'))
    code   = request.form.get('code','').strip().upper()
    dtype  = request.form.get('type','percent')
    try:    value    = float(request.form.get('value', 0))
    except: value    = 0.0
    try:    max_uses = int(request.form.get('max_uses', 0))
    except: max_uses = 0
    expires = request.form.get('expires','').strip()
    if code:
        if DiscountCode.query.filter_by(code=code).first():
            flash(f'Code "{code}" already exists.', 'error')
        else:
            dc = DiscountCode(code=code, type=dtype, value=value,
                              max_uses=max_uses, expires=expires)
            db.session.add(dc)
            db.session.commit()
            flash(f'Code "{code}" created.', 'success')
    return redirect(url_for('admin_discounts'))

@app.route('/admin/discounts/<int:dc_id>/toggle', methods=['POST'])
def admin_toggle_discount(dc_id):
    if not is_admin(): return redirect(url_for('admin_login'))
    dc = DiscountCode.query.get_or_404(dc_id)
    dc.active = not dc.active
    db.session.commit()
    return redirect(url_for('admin_discounts'))

@app.route('/admin/discounts/<int:dc_id>/delete', methods=['POST'])
def admin_delete_discount(dc_id):
    if not is_admin(): return redirect(url_for('admin_login'))
    dc = DiscountCode.query.get_or_404(dc_id)
    db.session.delete(dc)
    db.session.commit()
    flash(f'Code "{dc.code}" deleted.', 'success')
    return redirect(url_for('admin_discounts'))

# ─── GALLERY MANAGEMENT ───────────────────────────────────────────────────────

@app.route('/admin/gallery')
def admin_gallery():
    if not is_admin(): return redirect(url_for('admin_login'))
    images = GalleryImage.query.order_by(GalleryImage.order_index, GalleryImage.created_at).all()
    return render_template('admin/gallery.html', images=images)

@app.route('/admin/gallery/upload', methods=['POST'])
def admin_gallery_upload():
    if not is_admin(): return redirect(url_for('admin_login'))
    files   = request.files.getlist('images')
    caption = request.form.get('caption', '').strip()
    count   = 0
    for f in files:
        if f and allowed_file(f.filename):
            ext      = f.filename.rsplit('.', 1)[1].lower()
            filename = f"{uuid.uuid4().hex}.{ext}"
            f.save(os.path.join(GALLERY_DIR, filename))
            max_idx  = db.session.query(db.func.max(GalleryImage.order_index)).scalar() or 0
            img      = GalleryImage(filename=filename, caption=caption, order_index=max_idx + 1)
            db.session.add(img)
            count += 1
    db.session.commit()
    flash(f'{count} image{"s" if count!=1 else ""} uploaded.', 'success')
    return redirect(url_for('admin_gallery'))

@app.route('/admin/gallery/<int:img_id>/caption', methods=['POST'])
def admin_gallery_caption(img_id):
    if not is_admin(): return redirect(url_for('admin_login'))
    img = GalleryImage.query.get_or_404(img_id)
    img.caption = request.form.get('caption', '').strip()
    db.session.commit()
    return redirect(url_for('admin_gallery'))

@app.route('/admin/gallery/<int:img_id>/toggle', methods=['POST'])
def admin_gallery_toggle(img_id):
    if not is_admin(): return redirect(url_for('admin_login'))
    img = GalleryImage.query.get_or_404(img_id)
    img.active = not img.active
    db.session.commit()
    return redirect(url_for('admin_gallery'))

@app.route('/admin/gallery/<int:img_id>/delete', methods=['POST'])
def admin_gallery_delete(img_id):
    if not is_admin(): return redirect(url_for('admin_login'))
    img = GalleryImage.query.get_or_404(img_id)
    filepath = os.path.join(GALLERY_DIR, img.filename)
    if os.path.exists(filepath):
        os.remove(filepath)
    db.session.delete(img)
    db.session.commit()
    flash('Image deleted.', 'success')
    return redirect(url_for('admin_gallery'))

@app.route('/admin/gallery/reorder', methods=['POST'])
def admin_gallery_reorder():
    if not is_admin(): return jsonify({'ok': False})
    order = request.json.get('order', [])
    for idx, img_id in enumerate(order):
        img = GalleryImage.query.get(img_id)
        if img:
            img.order_index = idx
    db.session.commit()
    return jsonify({'ok': True})

# ─── ADMIN PAYMENT HISTORY ────────────────────────────────────────────────────

@app.route('/admin/payments')
def admin_payments():
    if not is_admin(): return redirect(url_for('admin_login'))
    payments = PaymentRecord.query.order_by(PaymentRecord.recorded_at.desc()).all()
    return render_template('admin/payments.html', payments=payments)

# ─── DISCORD INTERNAL API ────────────────────────────────────────────────────

@app.route('/api/internal/discord-reply', methods=['POST'])
def api_discord_reply():
    """Called by discord_bot.py when someone replies in a ticket thread."""
    data     = request.get_json(silent=True) or {}
    settings = SiteSettings.query.first()
    if not settings or data.get('secret') != settings.discord_bot_secret:
        return jsonify({'ok': False, 'error': 'unauthorized'}), 403
    thread_id   = data.get('thread_id', '').strip()
    message     = data.get('message',   '').strip()
    sender_name = data.get('sender_name', 'Discord User')
    if not thread_id or not message:
        return jsonify({'ok': False, 'error': 'missing_fields'}), 400
    ticket = Ticket.query.filter_by(discord_thread_id=thread_id, status='Open').first()
    if not ticket:
        return jsonify({'ok': False, 'error': 'no_ticket'}), 404
    msg = TicketMessage(
        ticket_id=ticket.ticket_id,
        sender='admin',
        message=f"[Discord — {sender_name}]\n{message}",
    )
    db.session.add(msg)
    db.session.commit()
    return jsonify({'ok': True, 'ticket_id': ticket.ticket_id})

@app.route('/api/internal/discord-ticket', methods=['POST'])
def api_discord_create_ticket():
    """Called by the bot's /ticket slash command to open a ticket from Discord."""
    data     = request.get_json(silent=True) or {}
    settings = SiteSettings.query.first()
    if not settings or data.get('secret') != settings.discord_bot_secret:
        return jsonify({'ok': False, 'error': 'unauthorized'}), 403
    customer_name = data.get('customer_name', 'Discord User')[:200]
    subject       = data.get('subject',  'Discord Ticket')[:300]
    first_msg     = data.get('message',  '').strip()
    order_id      = data.get('order_id', '').strip() or None
    channel_id    = settings.discord_ticket_channel or data.get('channel_id', '')
    ticket = Ticket(
        ticket_id     = gen_id('TKT'),
        order_id      = order_id,
        customer_name = customer_name,
        subject       = subject,
        status        = 'Open',
        expires_at    = datetime.utcnow() + timedelta(days=7),
    )
    db.session.add(ticket)
    db.session.flush()
    msg = TicketMessage(ticket_id=ticket.ticket_id, sender='customer', message=first_msg)
    db.session.add(msg)
    thread_id = _create_discord_thread(channel_id, ticket, first_msg, settings.discord_bot_token)
    if thread_id:
        ticket.discord_thread_id = thread_id
    db.session.commit()
    send_webhook(
        content="",
        embeds=[{
            'title':       f"🎫  NEW TICKET (Discord) — #{ticket.ticket_id}",
            'description': f"**{customer_name}** opened a ticket via Discord `/ticket`.\n\u200b",
            'color':       0x7c3aed,
            'fields': [
                {'name': '📦  Order ID',   'value': order_id or 'N/A',              'inline': True},
                {'name': '📌  Subject',    'value': subject,                         'inline': True},
                {'name': '💬  Message',    'value': (first_msg or '—')[:500],        'inline': False},
                {'name': '🔗  Admin Link', 'value': f"{request.host_url}admin/tickets/{ticket.ticket_id}", 'inline': True},
            ],
            'footer': {'text': f'Ticket {ticket.ticket_id}'},
            'timestamp': datetime.utcnow().isoformat(),
        }],
        webhook_type='ticket',
    )
    ticket_url = f"{request.host_url}admin/tickets/{ticket.ticket_id}"
    thread_url = f"https://discord.com/channels/@me/{thread_id}" if thread_id else None
    return jsonify({'ok': True, 'ticket_id': ticket.ticket_id,
                    'ticket_url': ticket_url, 'thread_url': thread_url})

# ─── API ENDPOINTS ────────────────────────────────────────────────────────────

@app.route('/api/commissions-status')
def api_commissions_status():
    settings = get_settings()
    return jsonify({'open': settings.commissions_open})

# ─── JINJA GLOBALS ───────────────────────────────────────────────────────────
@app.context_processor
def inject_globals():
    return dict(get_settings=get_settings)

# ─── SAFE COLUMN MIGRATIONS ──────────────────────────────────────────────────
# Adds any new columns to existing databases without losing data.
def run_migrations():
    import sqlite3
    con = sqlite3.connect(DB_PATH)
    cur = con.cursor()
    migrations = [
        "ALTER TABLE site_settings ADD COLUMN discord_webhook_status VARCHAR(500) DEFAULT ''",
        "ALTER TABLE site_settings ADD COLUMN discord_webhook_tickets VARCHAR(500) DEFAULT ''",
        "ALTER TABLE site_settings ADD COLUMN reopen_date VARCHAR(100) DEFAULT ''",
        # New columns on existing tables
        "ALTER TABLE commission_type ADD COLUMN allow_ref_images INTEGER DEFAULT 0",
        "ALTER TABLE commission_type ADD COLUMN max_ref_images INTEGER DEFAULT 3",
        "ALTER TABLE site_settings ADD COLUMN max_ref_images_default INTEGER DEFAULT 3",
        # login_log and commission_type tables are created by db.create_all() — no migration needed

        "ALTER TABLE site_settings ADD COLUMN close_date VARCHAR(100) DEFAULT ''",
        "ALTER TABLE \"order\" ADD COLUMN customer_instagram VARCHAR(100) DEFAULT ''",
        "ALTER TABLE \"order\" ADD COLUMN payment_method VARCHAR(50) DEFAULT ''",
        "ALTER TABLE \"order\" ADD COLUMN payment_username VARCHAR(200) DEFAULT ''",
        "ALTER TABLE site_settings ADD COLUMN banner_enabled INTEGER DEFAULT 0",
        "ALTER TABLE site_settings ADD COLUMN banner_text VARCHAR(500) DEFAULT ''",
        "ALTER TABLE site_settings ADD COLUMN banner_style VARCHAR(20) DEFAULT 'info'",
        "ALTER TABLE site_settings ADD COLUMN banner_link VARCHAR(300) DEFAULT ''",
        "ALTER TABLE site_settings ADD COLUMN banner_link_text VARCHAR(100) DEFAULT ''",
        "ALTER TABLE commission_request ADD COLUMN customer_instagram VARCHAR(100) DEFAULT ''",
        "ALTER TABLE commission_request ADD COLUMN payment_method VARCHAR(50) DEFAULT ''",
        "ALTER TABLE commission_request ADD COLUMN payment_username VARCHAR(200) DEFAULT ''",
        # Discord bi-directional sync
        "ALTER TABLE site_settings ADD COLUMN discord_bot_token VARCHAR(200) DEFAULT ''",
        "ALTER TABLE site_settings ADD COLUMN discord_ticket_channel VARCHAR(100) DEFAULT ''",
        "ALTER TABLE site_settings ADD COLUMN discord_bot_secret VARCHAR(100) DEFAULT ''",
        "ALTER TABLE ticket ADD COLUMN discord_thread_id VARCHAR(100)",
        "ALTER TABLE order_log ADD COLUMN image_filename VARCHAR(300) DEFAULT ''",
        "ALTER TABLE order_log ADD COLUMN customer_visible BOOLEAN DEFAULT 1",
        "ALTER TABLE trello_connection ADD COLUMN ping_list_id VARCHAR(64) DEFAULT ''",
        "ALTER TABLE trello_connection ADD COLUMN ping_list_name VARCHAR(200) DEFAULT ''",
        "ALTER TABLE trello_connection ADD COLUMN ping_board_id VARCHAR(64) DEFAULT ''",
        "ALTER TABLE trello_connection ADD COLUMN webhook_id VARCHAR(64) DEFAULT ''",
        "ALTER TABLE trello_connection ADD COLUMN webhook_callback_url VARCHAR(500) DEFAULT ''",
        "ALTER TABLE ping_list_subscriber ADD COLUMN unsubscribe_token VARCHAR(64) DEFAULT ''",
        "ALTER TABLE ping_list_subscriber ADD COLUMN welcomed BOOLEAN DEFAULT 0",
        "ALTER TABLE commission_notify_subscriber ADD COLUMN unsubscribe_token VARCHAR(64) DEFAULT ''",
        "ALTER TABLE commission_notify_subscriber ADD COLUMN discord_user_id VARCHAR(32) DEFAULT ''",
    ]
    for sql in migrations:
        try:
            cur.execute(sql)
        except Exception:
            pass  # Column already exists — safe to skip
    con.commit()
    con.close()

# ─── INIT ─────────────────────────────────────────────────────────────────────
# db.create_all() is safe on every restart — it only ADDS missing tables/columns.
# It never drops or overwrites existing data.

with app.app_context():
    run_migrations()  # Always safe — skips columns that already exist
    db.create_all()
    if not SiteSettings.query.first():
        db.session.add(SiteSettings())
        db.session.commit()
    # Seed commission types from PRESET_COMMISSIONS if DB is empty
    if not CommissionType.query.first():
        for idx, p in enumerate(PRESET_COMMISSIONS):
            ct = CommissionType(
                category=p['category'],
                type_name=p['type'],
                price=p['price'],
                order_index=idx
            )
            db.session.add(ct)
        db.session.commit()

    # Seed default form fields if none exist
    if not FormField.query.first():
        defaults = [
            FormField(field_key='character_description', label='Character Description', field_type='textarea', required=True, order_index=1),
            FormField(field_key='reference_images', label='Reference Images (URLs)', field_type='textarea', required=False, order_index=2),
            FormField(field_key='style_notes', label='Style Notes / Special Requests', field_type='textarea', required=False, order_index=3),
            FormField(field_key='deadline', label='Do you have a deadline?', field_type='text', required=False, order_index=4),
            FormField(field_key='character_complexity', label='Character Complexity', field_type='select', required=True,
                      options=json.dumps(['Simple', 'Moderate', 'Complex', 'Very Complex']), order_index=5),
        ]
        db.session.add_all(defaults)
        db.session.commit()

# Runs in every worker process, but sync_trello_orders() throttles itself via
# last_synced_at so redundant workers don't all hit the Trello API at once.
threading.Thread(target=_trello_background_sync_loop, daemon=True).start()

# ─── CONTACT FORM ─────────────────────────────────────────────────────────────

# Symbol sets for the CAPTCHA grid challenge
_SYMBOL_SETS = [
    {'target': '⭐', 'name': 'Stars',    'distractors': ['🌙', '☀️', '💫', '🌟', '✨', '🔆', '🌠', '⚡']},
    {'target': '💎', 'name': 'Gems',     'distractors': ['💠', '🔷', '🔹', '🟦', '🫧', '🔮', '🪩', '🫐']},
    {'target': '🎨', 'name': 'Palettes', 'distractors': ['🖌️', '✏️', '🖍️', '📝', '🎭', '🖼️', '🎪', '🎠']},
    {'target': '🌸', 'name': 'Blossoms', 'distractors': ['🌺', '🌹', '🌷', '🌻', '🍀', '🌼', '🪷', '💐']},
    {'target': '🦋', 'name': 'Butterflies', 'distractors': ['🐝', '🐛', '🪲', '🐞', '🦗', '🪳', '🪰', '🦟']},
    {'target': '🍓', 'name': 'Strawberries', 'distractors': ['🍒', '🍑', '🍇', '🍉', '🍊', '🍋', '🫐', '🍈']},
]

import random as _random
import hmac as _hmac
import hashlib as _hashlib

def _make_challenge():
    """Generate a fresh grid challenge. Returns (grid, correct_indices, token, target_emoji, target_name)."""
    sym_set = _random.choice(_SYMBOL_SETS)
    target  = sym_set['target']
    # Place 2–4 correct symbols in random positions
    num_correct = _random.randint(2, 4)
    positions   = list(range(9))
    _random.shuffle(positions)
    correct_positions = sorted(positions[:num_correct])
    # Fill remaining with distractors (no duplicates of target)
    distractors = _random.sample(sym_set['distractors'], 9 - num_correct)
    grid = [''] * 9
    for pos in correct_positions:
        grid[pos] = target
    di = 0
    for i in range(9):
        if grid[i] == '':
            grid[i] = distractors[di]; di += 1

    # Sign the correct answer so client can't tamper
    secret     = app.secret_key.encode()
    answer_str = ','.join(map(str, correct_positions))
    token      = _hmac.new(secret, answer_str.encode(), _hashlib.sha256).hexdigest()[:32]

    session['captcha_answer']  = correct_positions
    session['captcha_token']   = token
    session['captcha_issued']  = datetime.utcnow().isoformat()

    return grid, correct_positions, token, target, sym_set['name']


@app.route('/notify-me/discord/join')
def notify_me_discord_join():
    if not discord_join_configured():
        flash('Discord join-link isn\'t configured yet.', 'error')
        return redirect(url_for('index'))
    state = uuid.uuid4().hex
    session['discord_oauth_state'] = state
    redirect_uri = url_for('notify_me_discord_callback', _external=True)
    from urllib.parse import urlencode
    params = {
        'client_id': DISCORD_CLIENT_ID(),
        'redirect_uri': redirect_uri,
        'response_type': 'code',
        'scope': 'identify guilds.join',
        'state': state,
        'prompt': 'consent',
    }
    return redirect(f'https://discord.com/oauth2/authorize?{urlencode(params)}')

@app.route('/notify-me/discord/callback')
def notify_me_discord_callback():
    code = request.args.get('code')
    state = request.args.get('state')
    expected_state = session.pop('discord_oauth_state', None)
    if request.args.get('error'):
        flash('Discord sign-in was cancelled.', 'info')
        return redirect(url_for('index'))
    if not code or not expected_state or state != expected_state:
        flash('That Discord link expired or was invalid — try again.', 'error')
        return redirect(url_for('index'))

    redirect_uri = url_for('notify_me_discord_callback', _external=True)
    try:
        token_resp = requests.post(
            'https://discord.com/api/oauth2/token',
            data={
                'client_id': DISCORD_CLIENT_ID(),
                'client_secret': DISCORD_CLIENT_SECRET(),
                'grant_type': 'authorization_code',
                'code': code,
                'redirect_uri': redirect_uri,
            },
            headers={'Content-Type': 'application/x-www-form-urlencoded'},
            timeout=15,
        )
        token_resp.raise_for_status()
        access_token = token_resp.json()['access_token']

        user_resp = requests.get(
            'https://discord.com/api/users/@me',
            headers={'Authorization': f'Bearer {access_token}'}, timeout=15,
        )
        user_resp.raise_for_status()
        discord_user = user_resp.json()
        user_id = discord_user['id']
        username = discord_user['username']

        bot_token = get_settings().discord_bot_token
        join_resp = requests.put(
            f'https://discord.com/api/guilds/{DISCORD_GUILD_ID()}/members/{user_id}',
            headers={'Authorization': f'Bot {bot_token}', 'Content-Type': 'application/json'},
            json={'access_token': access_token},
            timeout=15,
        )
        if join_resp.status_code not in (201, 204):
            raise Exception(f'Discord returned {join_resp.status_code}: {join_resp.text[:200]}')
    except Exception as e:
        flash(f'Could not complete Discord setup: {e}', 'error')
        return redirect(url_for('index'))

    sub = CommissionNotifySubscriber.query.filter(
        db.or_(
            db.and_(CommissionNotifySubscriber.method == 'discord',
                    CommissionNotifySubscriber.discord_user_id == user_id),
            db.and_(CommissionNotifySubscriber.method == 'discord',
                    CommissionNotifySubscriber.contact == username),
        )
    ).first()
    is_new = sub is None
    if not sub:
        sub = CommissionNotifySubscriber(
            method='discord', contact=username, confirmed=True,
            unsubscribe_token=uuid.uuid4().hex,
        )
        db.session.add(sub)
    sub.discord_user_id = user_id
    sub.contact = username
    db.session.commit()

    if is_new:
        unsubscribe_url = url_for('notify_me_unsubscribe', token=sub.unsubscribe_token, _external=True)
        send_discord_welcome_dm(get_settings(), username, unsubscribe_url, user_id=user_id)
        flash("You're in! Welcome to the server — we'll DM you the moment commissions open.", 'success')
    else:
        flash("You're already signed up — welcome to the server!", 'success')
    return redirect(url_for('index'))

@app.route('/notify-me', methods=['POST'])
def notify_me():
    method = request.form.get('method', '').strip().lower()
    contact = request.form.get('contact', '').strip()
    next_url = request.form.get('next') or url_for('index')

    if method == 'discord':
        handle = contact.lstrip('@')
        if not handle:
            flash('Enter your Discord username.', 'error')
            return redirect(next_url)
        existing = CommissionNotifySubscriber.query.filter_by(method='discord', contact=handle).first()
        if not existing:
            existing = CommissionNotifySubscriber(
                method='discord', contact=handle, confirmed=True,
                unsubscribe_token=uuid.uuid4().hex,
            )
            db.session.add(existing)
            db.session.commit()
            unsubscribe_url = url_for('notify_me_unsubscribe', token=existing.unsubscribe_token, _external=True)
            send_discord_welcome_dm(get_settings(), handle, unsubscribe_url)
        flash("You're on the list — we'll DM you on Discord when commissions open.", 'success')
        return redirect(next_url)

    if method == 'email':
        email = contact.lower()
        if '@' not in email or '.' not in email.split('@')[-1]:
            flash('Enter a valid email address.', 'error')
            return redirect(next_url)
        if not email_configured():
            flash('Email notifications aren\'t set up yet — try Discord instead.', 'error')
            return redirect(next_url)
        existing = CommissionNotifySubscriber.query.filter_by(method='email', contact=email).first()
        if existing and existing.confirmed:
            flash("You're already signed up for email updates.", 'info')
            return redirect(next_url)
        if not existing:
            existing = CommissionNotifySubscriber(method='email', contact=email)
            db.session.add(existing)
        existing.confirm_token = uuid.uuid4().hex
        if not existing.unsubscribe_token:
            existing.unsubscribe_token = uuid.uuid4().hex
        db.session.commit()
        confirm_url = url_for('notify_me_confirm', token=existing.confirm_token, _external=True)
        unsubscribe_url = url_for('notify_me_unsubscribe', token=existing.unsubscribe_token, _external=True)
        html = branded_email_html(
            heading="Thanks for stopping by!",
            body_html=(
                "<p>You asked to be notified the moment <strong>Cioda's Commissions</strong> opens back up.</p>"
                "<p>Just one more click to confirm your email and you're all set — "
                "you'll get a message here the second commissions reopen.</p>"
            ),
            cta_url=confirm_url, cta_label="Confirm My Email",
            unsubscribe_url=unsubscribe_url,
        )
        sent = send_email(
            email, "Confirm — Commission reopening alerts",
            f"Thanks for stopping by Cioda's Commissions!\n\n"
            f"Click below to confirm you'd like an email when commissions reopen:\n\n{confirm_url}\n\n"
            f"If you didn't request this, just ignore it. Unsubscribe: {unsubscribe_url}",
            html_body=html,
        )
        if sent:
            flash('Check your email to confirm — one quick click and you\'re set.', 'success')
        else:
            flash('Could not send the confirmation email — please try again shortly.', 'error')
        return redirect(next_url)

    flash('Pick Discord or email.', 'error')
    return redirect(next_url)

@app.route('/notify-me/confirm/<token>')
def notify_me_confirm(token):
    sub = CommissionNotifySubscriber.query.filter_by(confirm_token=token, method='email').first()
    if not sub:
        flash('That confirmation link is invalid or already used.', 'error')
        return redirect(url_for('index'))
    sub.confirmed = True
    sub.confirm_token = ''
    db.session.commit()
    flash("Confirmed! We'll email you when commissions open.", 'success')
    return redirect(url_for('index'))

@app.route('/notify-me/unsubscribe/<token>')
def notify_me_unsubscribe(token):
    sub = CommissionNotifySubscriber.query.filter_by(unsubscribe_token=token).first()
    if sub:
        db.session.delete(sub)
        db.session.commit()
        flash("You won't receive any more commission-open notifications.", 'success')
        return redirect(url_for('index'))
    ping_sub = PingListSubscriber.query.filter_by(unsubscribe_token=token).first()
    if ping_sub:
        ping_sub.active = False
        db.session.commit()
        flash("You won't receive any more commission-open notifications.", 'success')
        return redirect(url_for('index'))
    flash('That link is invalid or already used.', 'error')
    return redirect(url_for('index'))

@app.route('/find-order', methods=['GET', 'POST'])
def find_order():
    orders = []
    searched = False
    method = request.form.get('method', 'order_id')
    submitted_name = ''
    submitted_email = ''
    submitted_order_id = ''
    submitted_discord = ''

    if request.method == 'POST':
        searched = True

        if method == 'order_id':
            submitted_order_id = request.form.get('order_id', '').strip()
            if submitted_order_id:
                order = Order.query.filter(
                    db.func.upper(Order.order_id) == submitted_order_id.upper()
                ).first()
                if order:
                    return redirect(f'/order/{order.unique_link}')

        elif method == 'discord':
            submitted_discord = request.form.get('customer_discord', '').strip()
            if submitted_discord:
                handle = submitted_discord.lstrip('@').lower()
                orders = Order.query.filter(
                    db.func.lower(db.func.ltrim(Order.customer_discord, '@')) == handle
                ).order_by(Order.created_at.desc()).all()

        else:  # name_email
            submitted_name  = request.form.get('customer_name', '').strip()
            submitted_email = request.form.get('customer_email', '').strip()
            if submitted_name and submitted_email:
                orders = Order.query.filter(
                    db.func.lower(Order.customer_name)  == submitted_name.lower(),
                    db.func.lower(Order.customer_email) == submitted_email.lower()
                ).order_by(Order.created_at.desc()).all()

    return render_template(
        'find_order.html',
        orders=orders,
        searched=searched,
        method=method,
        submitted_name=submitted_name,
        submitted_email=submitted_email,
        submitted_order_id=submitted_order_id,
        submitted_discord=submitted_discord,
    )


@app.route('/contact/verify', methods=['GET', 'POST'])
def contact_verify():
    if request.method == 'POST':
        # ── JSON validation request from JS ──
        data     = request.get_json(silent=True) or {}
        token    = data.get('token', '')
        selected = data.get('selected', [])
        elapsed  = float(data.get('elapsed', 0))
        moves    = int(data.get('moves', 0))

        # Honeypot fields
        if data.get('fullname') or data.get('firstname'):
            return jsonify({'ok': False, 'reason': 'Bot detected.'})

        # Timing check
        if elapsed < 2.5:
            return jsonify({'ok': False, 'reason': 'Too fast — are you a bot?'})

        # Mouse movement check
        if moves < 3:
            return jsonify({'ok': False, 'reason': 'No interaction detected.'})

        # Token check
        stored_token = session.get('captcha_token', '')
        if not stored_token or token != stored_token:
            return jsonify({'ok': False, 'reason': 'Invalid session — please refresh.'})

        # Answer check — selected must exactly match correct positions
        correct = session.get('captcha_answer', [])
        if sorted(selected) != sorted(correct):
            # Track failures
            fails = session.get('captcha_fails', 0) + 1
            session['captcha_fails'] = fails
            if fails >= 2:
                # Lock them out — signal client to redirect
                session.pop('captcha_answer',  None)
                session.pop('captcha_token',   None)
                session.pop('captcha_issued',  None)
                session['captcha_locked'] = True
                session['captcha_locked_at'] = datetime.utcnow().isoformat()
                return jsonify({'ok': False, 'lockout': True})
            # Regenerate challenge so they can't brute-force
            _make_challenge()
            remaining = 2 - fails
            return jsonify({'ok': False, 'reason': f'Wrong symbols — try the new puzzle. ({remaining} attempt{"s" if remaining != 1 else ""} remaining)'})

        # ✅ All checks passed
        session['contact_verified']    = True
        session['contact_verified_at'] = datetime.utcnow().isoformat()
        session['captcha_fails']       = 0
        session.pop('captcha_answer',  None)
        session.pop('captcha_token',   None)
        session.pop('captcha_issued',  None)
        return jsonify({'ok': True})

    # GET — serve the challenge page
    # If already locked out, bounce them — unless the lock has expired (5 min)
    # or was issued before the current server process started (i.e. a restart clears it).
    if session.get('captcha_locked'):
        locked_at_str = session.get('captcha_locked_at')
        still_locked = False
        if locked_at_str:
            try:
                locked_at = datetime.fromisoformat(locked_at_str)
                age = (datetime.utcnow() - locked_at).total_seconds()
                # Expire if older than 5 minutes OR was set before this server started
                if age < CAPTCHA_LOCKOUT_SECS and locked_at > SERVER_START_TIME:
                    still_locked = True
            except ValueError:
                pass  # Malformed timestamp — treat as expired
        if still_locked:
            return redirect('https://lockout.ciodrawz.space/')
        # Lock expired or predates this server run — clear it and let them retry
        session.pop('captcha_locked', None)
        session.pop('captcha_locked_at', None)
        session.pop('captcha_fails', None)

    grid, correct, token, target_emoji, target_name = _make_challenge()
    return render_template('contact_verify.html',
        grid            = grid,
        correct_indices = correct,
        token           = token,
        target_emoji    = target_emoji,
        target_name     = target_name,
    )


@app.route('/contact', methods=['GET', 'POST'])
def contact():
    # ── Gate: must have passed the CAPTCHA ──
    if not session.get('contact_verified'):
        return redirect(url_for('contact_verify'))

    # Expire verification after 15 minutes
    verified_at = session.get('contact_verified_at')
    if verified_at:
        try:
            age = (datetime.utcnow() - datetime.fromisoformat(verified_at)).total_seconds()
            if age > 900:
                session.pop('contact_verified', None)
                session.pop('contact_verified_at', None)
                return redirect(url_for('contact_verify'))
        except Exception:
            pass

    sent      = False
    sent_name = ''
    form      = {}

    if request.method == 'POST':
        # Honeypot
        if request.form.get('website_url') or request.form.get('phone_number'):
            return render_template('spam_blocked.html')

        ip = get_client_ip()
        if is_ip_blocked(ip):
            return render_template('spam_blocked.html')
        if not record_submission(ip):
            return render_template('spam_blocked.html')

        name     = request.form.get('contact_name',    '').strip()
        email    = request.form.get('contact_email',   '').strip()
        discord  = request.form.get('contact_discord', '').strip()
        subject  = request.form.get('contact_subject', '').strip()
        msg_type = request.form.get('contact_type',    'General Enquiry').strip()
        message  = request.form.get('contact_message', '').strip()

        if not name or not email or not subject or not message:
            flash('Please fill in all required fields.', 'error')
            return render_template('contact.html', sent=False, form=request.form)

        class _ContactMsg:
            request_id         = gen_id('CTT')
            customer_name      = name
            customer_email     = email
            customer_discord   = discord
            customer_instagram = ''
            payment_method     = ''
            commission_type    = f'Contact Form — {msg_type}'
            description        = message
            form_responses     = json.dumps({'Subject': subject, 'Message Type': msg_type})

        class _NoOrder:
            order_id    = ''
            unique_link = ''

        notify_contact_bot(_ContactMsg(), _NoOrder())

        # Clear verification so they must re-verify next time
        session.pop('contact_verified',    None)
        session.pop('contact_verified_at', None)

        sent      = True
        sent_name = name

    return render_template('contact.html', sent=sent, sent_name=sent_name, form=form)


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5002, debug=True)