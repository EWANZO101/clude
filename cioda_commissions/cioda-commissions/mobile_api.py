"""JSON API for the Cioda iPhone app (see /root/cioda_commissions/IOS).

Lives in its own module so app.py only needs one line at the very end:

    import mobile_api; mobile_api.register(sys.modules[__name__])

Everything here reuses app.py's own models and helpers (send_webhook,
auto_create_invoice, the request queue, discount checks, Discord thread
mirroring...), so an action taken in the app has exactly the same effects as
the same action on the website.

Two kinds of bearer token, both signed with FLASK_SECRET_KEY:
  - admin: from /admin/login; dies if ADMIN_PASSWORD_HASH changes.
  - order: from an order's PIN; dies if the PIN is reset or changed.

Push notifications ride on SQLAlchemy session events rather than hooks in each
route, so they fire no matter where a change comes from — the website, this
API, a Trello card move, or a reply in a Discord ticket thread.
"""

import hashlib
import json
import logging
import os
import threading
import time
import uuid
from collections import defaultdict
from datetime import datetime, timedelta
from functools import wraps

import requests as http
from flask import Blueprint, g, jsonify, request
from itsdangerous import BadSignature, SignatureExpired, URLSafeTimedSerializer
from sqlalchemy import event
from sqlalchemy.orm import Session
from sqlalchemy.orm.attributes import NO_VALUE

log = logging.getLogger(__name__)

ADMIN_TOKEN_MAX_AGE = 60 * 60 * 24 * 30   # 30 days
ORDER_TOKEN_MAX_AGE = 60 * 60 * 24 * 180  # 180 days — customers check back occasionally

# PIN guessing limit, per order link. The website has none; a 4-digit PIN
# needs one here since the API is trivially scriptable.
PIN_FAIL_MAX = 5
PIN_FAIL_WINDOW = 15 * 60

EXPO_PUSH_URL = "https://exp.host/--/api/v2/push/send"

core = None       # the app.py module, set by register()
PushDevice = None  # model class, created in register()

_pin_lock = threading.Lock()
_pin_fails = defaultdict(list)


def register(core_module):
    global core, PushDevice
    core = core_module
    db = core.db

    class MobilePushDevice(db.Model):
        """A phone running the iPhone app that wants notifications.
        role='admin'    → Cioda's phone: new requests, tickets, customer replies.
        role='customer' → following one order (order_link): status changes, replies."""
        __tablename__ = "mobile_push_device"
        id = db.Column(db.Integer, primary_key=True)
        token = db.Column(db.String(255), nullable=False, index=True)
        role = db.Column(db.String(10), nullable=False)
        order_link = db.Column(db.String(64), nullable=True, index=True)
        created_at = db.Column(db.DateTime, default=datetime.utcnow)

    PushDevice = MobilePushDevice
    with core.app.app_context():
        db.create_all()  # only creates the new table; existing ones are untouched

    core.app.register_blueprint(bp)
    _install_push_hooks()


bp = Blueprint("mobile_api", __name__, url_prefix="/api/m/v1")


# ─── helpers ──────────────────────────────────────────────────────────────────


def _serializer():
    return URLSafeTimedSerializer(core.app.secret_key, salt="mobile-api")


def _fingerprint(value):
    return hashlib.sha256((value or "").encode()).hexdigest()[:16]


def _err(message, status, **extra):
    return jsonify({"error": message, **extra}), status


def _iso(dt):
    # Stored as naive UTC throughout app.py; mark it so the phone converts to local time.
    return dt.replace(microsecond=0).isoformat() + "Z" if dt else None


def _site_url():
    return (os.environ.get("SITE_URL") or request.host_url).rstrip("/")


def _file_url(route, filename):
    return f"{_site_url()}/{route}/{filename}" if filename else None


def _body():
    return request.get_json(silent=True) or {}


def _form_responses(obj):
    try:
        return json.loads(obj.form_responses or "{}")
    except (TypeError, ValueError):
        return {}


def _public_form_responses(responses):
    """Customer-entered answers, minus the internal _keys (ref images, discount label)."""
    fields = {f.field_key: f.label for f in core.FormField.query.all()}
    out = []
    for key, value in responses.items():
        if key.startswith("_") or value in ("", None):
            continue
        out.append({"label": fields.get(key, key), "value": value})
    return out


def _ref_image_urls(responses):
    names = [n for n in (responses.get("_ref_images") or "").split(",") if n]
    return [_file_url("ref-uploads", n) for n in names]


# ─── auth decorators ────────────────────────────────────────────────────────────


def _bearer():
    header = request.headers.get("Authorization", "")
    return header[7:] if header.startswith("Bearer ") else None


def admin_required(view):
    @wraps(view)
    def wrapped(*args, **kwargs):
        token = _bearer()
        if not token:
            return _err("Sign in required.", 401)
        try:
            data = _serializer().loads(token, max_age=ADMIN_TOKEN_MAX_AGE)
        except (BadSignature, SignatureExpired):
            return _err("Session expired — please sign in again.", 401)
        if data.get("role") != "admin" or data.get("pw") != _fingerprint(core.ADMIN_PASSWORD_HASH):
            return _err("Session expired — please sign in again.", 401)
        return view(*args, **kwargs)

    return wrapped


def order_required(view):
    """Needs an order token for the <link> in the URL (issued after the PIN)."""

    @wraps(view)
    def wrapped(link, *args, **kwargs):
        order = core.Order.query.filter_by(unique_link=link).first()
        if not order:
            return _err("Order not found.", 404)
        token = _bearer()
        try:
            data = _serializer().loads(token or "", max_age=ORDER_TOKEN_MAX_AGE)
        except (BadSignature, SignatureExpired):
            return _err("Enter your PIN to open this order.", 401, pin_set=bool(order.pin_hash))
        if data.get("role") != "order" or data.get("link") != link or data.get("pin") != _fingerprint(order.pin_hash):
            return _err("Enter your PIN to open this order.", 401, pin_set=bool(order.pin_hash))
        g.order = order
        return view(link, *args, **kwargs)

    return wrapped


def _order_token(order):
    return _serializer().dumps({"role": "order", "link": order.unique_link, "pin": _fingerprint(order.pin_hash)})


# ─── serializers ────────────────────────────────────────────────────────────────


def _invoice_json(inv, link=None):
    try:
        items = json.loads(inv.items or "[]")
    except (TypeError, ValueError):
        items = []
    return {
        "invoice_id": inv.invoice_id,
        "order_id": inv.order_id,
        "customer_name": inv.customer_name,
        "amount": inv.amount,
        "items": items,
        "paid": bool(inv.paid),
        "paid_at": _iso(inv.paid_at),
        "due_date": inv.due_date or None,
        "notes": inv.notes or None,
        "created_at": _iso(inv.created_at),
        "pdf_url": f"{_site_url()}/order/{link}/invoice/{inv.invoice_id}/download" if link else None,
    }


def _ticket_json(t, with_messages=False):
    now = datetime.utcnow()
    out = {
        "ticket_id": t.ticket_id,
        "order_id": t.order_id,
        "customer_name": t.customer_name,
        "subject": t.subject,
        "status": t.status,
        "created_at": _iso(t.created_at),
        "expires_at": _iso(t.expires_at),
        "expired": bool(t.expires_at and now > t.expires_at),
    }
    if with_messages:
        msgs = core.TicketMessage.query.filter_by(ticket_id=t.ticket_id).order_by(core.TicketMessage.created_at).all()
        out["messages"] = [{"sender": m.sender, "message": m.message, "created_at": _iso(m.created_at)} for m in msgs]
    return out


def _log_json(entry):
    return {
        "event": entry.event,
        "details": entry.details,
        "image_url": _file_url("order-log-image", entry.image_filename),
        "customer_visible": bool(entry.customer_visible),
        "created_at": _iso(entry.created_at),
    }


def _order_summary(o):
    return {
        "order_id": o.order_id,
        "customer_name": o.customer_name,
        "commission_type": o.commission_type,
        "price": o.price,
        "status": o.status,
        "payment_status": o.payment_status,
        "eta": o.eta or None,
        "created_at": _iso(o.created_at),
    }


def _customer_order_json(o):
    responses = _form_responses(o)
    logs = core.OrderLog.query.filter_by(order_id=o.order_id, customer_visible=True).order_by(core.OrderLog.created_at.desc()).all()
    invoice = core.Invoice.query.filter_by(order_id=o.order_id).order_by(core.Invoice.created_at.desc()).first()
    tickets = core.Ticket.query.filter_by(order_link=o.unique_link).order_by(core.Ticket.created_at.desc()).all()
    finals = (
        core.OrderFinalImage.query.filter_by(order_id=o.order_id).order_by(core.OrderFinalImage.uploaded_at).all()
        if o.status == "Done" else []
    )
    return {
        **_order_summary(o),
        "description": o.description,
        "payment_method": o.payment_method or None,
        "progress": {
            "order_steps": core.ORDER_PROGRESS_STEPS,
            "order_index": core.ORDER_PROGRESS_STEPS.index(o.status) if o.status in core.ORDER_PROGRESS_STEPS else -1,
            "payment_steps": core.PAYMENT_PROGRESS_STEPS,
            "payment_index": core.PAYMENT_PROGRESS_STEPS.index(o.payment_status) if o.payment_status in core.PAYMENT_PROGRESS_STEPS else -1,
        },
        "discount": responses.get("_discount"),
        "answers": _public_form_responses(responses),
        "ref_images": _ref_image_urls(responses),
        "logs": [_log_json(entry) for entry in logs],
        "invoice": _invoice_json(invoice, o.unique_link) if invoice else None,
        "tickets": [_ticket_json(t) for t in tickets],
        "final_images": [_file_url("final-image", f.filename) for f in finals],
    }


# ─── public: storefront ───────────────────────────────────────────────────────────


@bp.route("/public/home")
def public_home():
    s = core.get_settings()
    gallery = core.GalleryImage.query.filter_by(active=True).order_by(core.GalleryImage.order_index, core.GalleryImage.created_at).all()
    global_max = s.max_ref_images_default or 3
    types = core.CommissionType.query.filter_by(active=True).order_by(
        core.CommissionType.category, core.CommissionType.order_index, core.CommissionType.id).all()
    categories = []
    for t in types:
        if not categories or categories[-1]["category"] != t.category:
            categories.append({"category": t.category, "types": []})
        categories[-1]["types"].append({
            "id": t.id, "name": t.type_name, "price": t.price,
            "allow_ref_images": bool(t.allow_ref_images),
            "max_ref_images": (t.max_ref_images if t.max_ref_images and t.max_ref_images > 0 else global_max),
        })
    fields = core.FormField.query.filter_by(active=True).order_by(core.FormField.order_index).all()
    return jsonify({
        "commissions_open": bool(s.commissions_open),
        "closed_message": s.closed_message,
        "reopen_date": s.reopen_date or None,
        "banner": {
            "text": s.banner_text, "style": s.banner_style,
            "link": s.banner_link or None, "link_text": s.banner_link_text or None,
        } if s.banner_enabled and s.banner_text else None,
        "price_list": categories,
        "gallery": [{"url": _file_url("gallery", i.filename), "caption": i.caption or None} for i in gallery],
        "form_fields": [{
            "key": f.field_key, "label": f.label, "type": f.field_type, "required": bool(f.required),
            "options": json.loads(f.options or "[]") if f.field_type == "select" else [],
        } for f in fields],
        "site_url": _site_url(),
    })


@bp.route("/public/discount", methods=["POST"])
def public_discount():
    dc, err = core.is_code_valid((_body().get("code") or "").strip().upper())
    if err:
        return jsonify({"valid": False, "error": err})
    label = f"{dc.value:.0f}% off" if dc.type == "percent" else f"${dc.value:.2f} off"
    return jsonify({"valid": True, "type": dc.type, "value": dc.value, "label": label})


# ─── public: request queue + submission ────────────────────────────────────────────


@bp.route("/queue", methods=["POST"])
def queue_heartbeat():
    """The app's version of the website waiting room. Poll every ~5–10s with the
    same token until admitted; the same 5-on-the-form limit applies to both."""
    s = core.get_settings()
    if not s.commissions_open:
        return jsonify({"commissions_open": False, "closed_message": s.closed_message})
    token = (_body().get("token") or "").strip()
    if not (8 <= len(token) <= 64):
        return _err("Missing queue token.", 400)
    ip = core.get_client_ip()
    blocked, secs = core.is_overflow_blocked(ip)
    if blocked:
        return jsonify({"commissions_open": True, "busy": True, "retry_after": secs})
    info = core.get_queue_info(token)
    if info.get("overflow"):
        core.mark_overflow_blocked(ip)
        core.release_queue_token(token)
        return jsonify({"commissions_open": True, "busy": True, "retry_after": core.OVERFLOW_BLOCK_SECS})
    if info["can_proceed"]:
        core.mark_on_form(token)
    return jsonify({"commissions_open": True, "busy": False, "admitted": bool(info["can_proceed"]), **info})


def _queue_admitted(token):
    now = datetime.utcnow()
    with core._queue_lock:
        for e in core._queue:
            if e["token"] == token and e.get("on_form_since"):
                return e["on_form_since"] > now - timedelta(seconds=core.ON_FORM_TIMEOUT)
    return False


@bp.route("/requests", methods=["POST"])
def submit_request():
    """Mirrors app.py's commission_request POST: saves the request, creates the
    order + draft invoice straight away, and fires the same Discord notifications."""
    s = core.get_settings()
    if not s.commissions_open:
        return _err(s.closed_message or "Commissions are closed.", 403, closed=True)

    token = (request.form.get("queue_token") or "").strip()
    if not token or not _queue_admitted(token):
        return _err("Your spot in the queue expired — please join the queue again.", 409, queue=True)

    ip = core.get_client_ip()
    if core.is_ip_blocked(ip):
        return _err("Too many submissions. Please wait a few minutes and try again.", 429)

    f = request.form
    name = (f.get("customer_name") or "").strip()
    comm_types = [t for t in f.getlist("commission_type") if t]
    # Same required fields as the website form (templates/request_form.html).
    if not name:
        return _err("Please enter your name.", 400)
    if not comm_types:
        return _err("Please choose at least one commission type.", 400)
    if not any((f.get(k) or "").strip() for k in ("customer_discord", "customer_instagram", "customer_email")):
        return _err("Please give at least one way to reach you: Discord, Instagram or email.", 400)
    if not (f.get("description") or "").strip():
        return _err("Please describe what you'd like.", 400)
    if (f.get("payment_method") or "").strip() not in ("CashApp", "PayPal"):
        return _err("Please choose Cash App or PayPal.", 400)
    if not (f.get("payment_username") or "").strip():
        return _err("Please enter your $Cashtag or PayPal email.", 400)

    fields = core.FormField.query.filter_by(active=True).order_by(core.FormField.order_index).all()
    responses = {}
    for field in fields:
        value = (f.get(field.field_key) or "").strip()
        if field.required and not value:
            return _err(f"Please fill in “{field.label}”.", 400)
        responses[field.field_key] = value

    discount_label = ""
    code = (f.get("discount_code") or "").strip().upper()
    dc = None
    if code:
        dc, dc_err = core.is_code_valid(code)
        if dc_err:
            return _err(dc_err, 400)
        discount_label = f"{dc.value:.0f}% discount ({code})" if dc.type == "percent" else f"${dc.value:.2f} discount ({code})"

    # Counted only once the form is valid, so fixing typos doesn't use up the
    # 3-per-minute allowance and trigger the 10-minute spam block.
    if not core.record_submission(ip):
        return _err("Too many submissions. Please wait a few minutes and try again.", 429)

    # Reference images, capped exactly like the website does.
    global_max = s.max_ref_images_default or 3
    selected = core.CommissionType.query.filter(
        core.CommissionType.type_name.in_(comm_types), core.CommissionType.allow_ref_images == True  # noqa: E712
    ).all()
    ref_filenames = []
    if selected:
        max_allowed = max((t.max_ref_images if t.max_ref_images > 0 else global_max) for t in selected)
        ref_dir = os.path.join(core.app.static_folder, "ref_uploads")
        os.makedirs(ref_dir, exist_ok=True)
        for rf in request.files.getlist("ref_images")[:max_allowed]:
            if rf and core.allowed_file(rf.filename):
                ext = rf.filename.rsplit(".", 1)[1].lower()
                fname = f"ref_{uuid.uuid4().hex[:12]}.{ext}"
                rf.save(os.path.join(ref_dir, fname))
                ref_filenames.append(fname)
    if ref_filenames:
        responses["_ref_images"] = ",".join(ref_filenames)
    if discount_label:
        responses["_discount"] = discount_label
        dc.uses += 1

    comm_type = ", ".join(comm_types)
    common = dict(
        customer_name=name,
        customer_email=(f.get("customer_email") or "").strip(),
        customer_discord=(f.get("customer_discord") or "").strip(),
        customer_instagram=(f.get("customer_instagram") or "").strip(),
        payment_method=(f.get("payment_method") or "").strip(),
        payment_username=(f.get("payment_username") or "").strip(),
        commission_type=comm_type,
        description=(f.get("description") or "").strip(),
        form_responses=json.dumps(responses),
    )
    req = core.CommissionRequest(request_id=core.gen_id("REQ"), status="Pending", **common)
    core.db.session.add(req)
    order = core.Order(order_id=core.gen_id("ORD"), unique_link=core.gen_link(),
                       status="Awaiting Confirmation", payment_status="Unpaid", **common)
    core.db.session.add(order)
    core.db.session.commit()
    req.status = "Accepted"
    core.db.session.commit()

    core.add_log(order.order_id, "Order Created", f"Submitted via the iPhone app (Request #{req.request_id})")
    core.auto_create_invoice(order)
    core.send_webhook(
        f"🎨 **New Commission Request** from **{name}** (iPhone app)",
        embeds=[{
            "title": f"Order #{order.order_id} — {comm_type or 'Commission'}",
            "color": 0xF59E0B,
            "fields": [
                {"name": "Commission Type", "value": comm_type or "Not specified", "inline": True},
                {"name": "Discord", "value": common["customer_discord"] or "N/A", "inline": True},
                {"name": "Order ID", "value": order.order_id, "inline": True},
                {"name": "Tracking Link", "value": f"/order/{order.unique_link}"},
                {"name": "Description", "value": (common["description"] or "N/A")[:500]},
            ],
            "timestamp": datetime.utcnow().isoformat(),
        }],
    )
    core.notify_contact_bot(req, order)
    core.release_queue_token(token)
    return jsonify({"order_id": order.order_id, "link": order.unique_link}), 201


# ─── customer: order access ───────────────────────────────────────────────────────


@bp.route("/orders/lookup", methods=["POST"])
def order_lookup():
    """Order ID (or a pasted link) → link + whether a PIN is set, same as the
    website's Find My Order by ID. The PIN still guards the details."""
    body = _body()
    link = (body.get("link") or "").strip().lower()
    oid = (body.get("order_id") or "").strip().upper()
    if oid and not oid.startswith("ORD-"):
        oid = "ORD-" + oid
    if link:
        order = core.Order.query.filter_by(unique_link=link).first()
    else:
        order = core.Order.query.filter(core.db.func.upper(core.Order.order_id) == oid).first() if oid else None
    if not order:
        return _err("No order found with that ID. It looks like ORD-1A2B3C.", 404)
    return jsonify({"order_id": order.order_id, "link": order.unique_link, "pin_set": bool(order.pin_hash)})


def _pin_blocked(link):
    now = time.time()
    with _pin_lock:
        _pin_fails[link] = [t for t in _pin_fails[link] if t > now - PIN_FAIL_WINDOW]
        return len(_pin_fails[link]) >= PIN_FAIL_MAX


def _pin_failed(link):
    with _pin_lock:
        _pin_fails[link].append(time.time())


@bp.route("/orders/<link>/pin", methods=["POST"])
def order_pin(link):
    """Set the PIN (first visit) or check it. Either way, returns an order token."""
    order = core.Order.query.filter_by(unique_link=link).first()
    if not order:
        return _err("Order not found.", 404)
    pin = str(_body().get("pin") or "").strip()

    if not order.pin_hash:
        if not pin.isdigit() or not (4 <= len(pin) <= 8):
            return _err("Your PIN must be 4–8 digits.", 400)
        order.pin_hash = hashlib.sha256(pin.encode()).hexdigest()
        core.db.session.commit()
        core.add_log(order.order_id, "PIN Set", "Customer set a PIN to protect their order (iPhone app)")
        return jsonify({"token": _order_token(order), "order_id": order.order_id, "created": True})

    if _pin_blocked(link):
        return _err("Too many wrong PINs. Try again in 15 minutes.", 429)
    if hashlib.sha256(pin.encode()).hexdigest() != order.pin_hash:
        _pin_failed(link)
        return _err("That PIN isn't right.", 401)
    return jsonify({"token": _order_token(order), "order_id": order.order_id, "created": False})


@bp.route("/orders/<link>")
@order_required
def customer_order(link):
    return jsonify({"order": _customer_order_json(g.order)})


@bp.route("/orders/<link>/tickets", methods=["POST"])
@order_required
def customer_new_ticket(link):
    order = g.order
    body = _body()
    subject = (body.get("subject") or "").strip()[:300]
    message = (body.get("message") or "").strip()
    if not message:
        return _err("Please write a message.", 400)
    name = order.customer_name
    ticket = core.Ticket(ticket_id=core.gen_id("TKT"), order_link=link, order_id=order.order_id,
                         customer_name=name, subject=subject, expires_at=datetime.utcnow() + timedelta(hours=24))
    core.db.session.add(ticket)
    core.db.session.flush()
    core.db.session.add(core.TicketMessage(ticket_id=ticket.ticket_id, sender="customer", message=message))
    core.db.session.commit()
    site = _site_url()
    core.send_webhook(content="", embeds=[{
        "title": f"🎫  NEW TICKET — #{ticket.ticket_id}",
        "description": f"**{name}** has opened a new support ticket (iPhone app).\n​",
        "color": 0x6366F1,
        "fields": [
            {"name": "📦  Order ID", "value": f"`{order.order_id}`", "inline": True},
            {"name": "👤  Customer", "value": name, "inline": True},
            {"name": "​", "value": "​", "inline": False},
            {"name": "📌  Subject", "value": subject or "(no subject)", "inline": False},
            {"name": "💬  Message", "value": message[:1000], "inline": False},
            {"name": "⏰  Expires", "value": ticket.expires_at.strftime("%b %d %Y at %H:%M UTC"), "inline": True},
            {"name": "🔗  Admin Link", "value": f"{site}/admin/tickets/{ticket.ticket_id}", "inline": True},
            {"name": "💬  Ticket Link", "value": f"{site}/order/{link}/ticket/{ticket.ticket_id}", "inline": True},
        ],
        "footer": {"text": f"Ticket {ticket.ticket_id}  •  {order.order_id}"},
        "timestamp": datetime.utcnow().isoformat(),
    }], webhook_type="ticket")
    settings = core.SiteSettings.query.first()
    thread_id = core._create_discord_thread(settings.discord_ticket_channel, ticket, message, settings.discord_bot_token)
    if thread_id:
        ticket.discord_thread_id = thread_id
        core.db.session.commit()
    return jsonify({"ticket": _ticket_json(ticket, with_messages=True)}), 201


def _customer_ticket_or_404(link, ticket_id):
    return core.Ticket.query.filter_by(ticket_id=ticket_id, order_link=link).first()


@bp.route("/orders/<link>/tickets/<ticket_id>")
@order_required
def customer_ticket(link, ticket_id):
    t = _customer_ticket_or_404(link, ticket_id)
    if not t:
        return _err("Ticket not found.", 404)
    return jsonify({"ticket": _ticket_json(t, with_messages=True)})


@bp.route("/orders/<link>/tickets/<ticket_id>/messages", methods=["POST"])
@order_required
def customer_ticket_reply(link, ticket_id):
    t = _customer_ticket_or_404(link, ticket_id)
    if not t:
        return _err("Ticket not found.", 404)
    if t.expires_at and datetime.utcnow() > t.expires_at:
        return _err("This ticket has expired. Open a new one if you still need help.", 400)
    message = (_body().get("message") or "").strip()
    if not message:
        return _err("Please write a message.", 400)
    core.db.session.add(core.TicketMessage(ticket_id=ticket_id, sender="customer", message=message))
    core.db.session.commit()
    site = _site_url()
    core.send_webhook(content="", embeds=[{
        "title": f"💬  CUSTOMER REPLY — #{ticket_id}",
        "description": f"**{t.customer_name}** has replied to their ticket (iPhone app).\n​",
        "color": 0x818CF8,
        "fields": [
            {"name": "📦  Order ID", "value": f"`{t.order_id or 'N/A'}`", "inline": True},
            {"name": "👤  Customer", "value": t.customer_name, "inline": True},
            {"name": "​", "value": "​", "inline": False},
            {"name": "📌  Subject", "value": t.subject or "(no subject)", "inline": False},
            {"name": "💬  Message", "value": message[:1000], "inline": False},
            {"name": "🔗  Admin Link", "value": f"{site}/admin/tickets/{ticket_id}", "inline": True},
            {"name": "💬  Ticket Link", "value": f"{site}/order/{link}/ticket/{ticket_id}", "inline": True},
        ],
        "footer": {"text": f"Ticket {ticket_id}"},
        "timestamp": datetime.utcnow().isoformat(),
    }], webhook_type="ticket")
    settings = core.SiteSettings.query.first()
    if t.discord_thread_id and settings.discord_bot_token:
        core._send_to_discord_thread(t.discord_thread_id, f"**💬 Customer reply — {t.customer_name}**\n{message[:1800]}",
                                     settings.discord_bot_token)
    return jsonify({"ticket": _ticket_json(t, with_messages=True)})


# ─── admin ────────────────────────────────────────────────────────────────────────


@bp.route("/admin/login", methods=["POST"])
def admin_login():
    ip = core.get_client_ip()
    if core.is_login_blocked(ip):
        return _err("Too many failed attempts. Try again in a few minutes.", 429)
    body = _body()
    username = body.get("username") or ""
    password = body.get("password") or ""
    import hmac
    ok = hmac.compare_digest(username, core.ADMIN_USERNAME) and core.check_password_hash(core.ADMIN_PASSWORD_HASH, password)
    core.db.session.add(core.LoginLog(
        ip_address=ip, user_agent=request.headers.get("User-Agent", "")[:500], success=ok,
        note="Admin login successful (iPhone app)" if ok else f"Failed attempt (iPhone app) — username: {username[:50]}",
    ))
    core.db.session.commit()
    if not ok:
        core.record_login_failure(ip)
        return _err("Wrong username or password.", 401)
    core.clear_login_failures(ip)
    return jsonify({"token": _serializer().dumps({"role": "admin", "pw": _fingerprint(core.ADMIN_PASSWORD_HASH)})})


@bp.route("/admin/dashboard")
@admin_required
def admin_dashboard():
    s = core.get_settings()
    recent = core.Order.query.order_by(core.Order.created_at.desc()).limit(10).all()
    return jsonify({
        "commissions_open": bool(s.commissions_open),
        "stats": {
            "pending_requests": core.CommissionRequest.query.filter_by(status="Pending").count(),
            "awaiting_confirmation": core.Order.query.filter_by(status="Awaiting Confirmation").count(),
            "in_progress": core.Order.query.filter_by(status="In Progress").count(),
            "open_tickets": core.Ticket.query.filter_by(status="Open").count(),
            "unpaid": core.Order.query.filter_by(payment_status="Unpaid").count(),
            "total_orders": core.Order.query.count(),
        },
        "recent_orders": [_order_summary(o) for o in recent],
    })


@bp.route("/admin/commissions/toggle", methods=["POST"])
@admin_required
def admin_toggle():
    s = core.get_settings()
    was_closed = not s.commissions_open
    s.commissions_open = not s.commissions_open
    core.db.session.commit()
    pinged = None
    if was_closed and s.commissions_open and _body().get("notify_subscribers"):
        pinged = core.notify_ping_list_commissions_open()
    return jsonify({"commissions_open": bool(s.commissions_open), "notified": pinged})


@bp.route("/admin/orders")
@admin_required
def admin_orders():
    q = (request.args.get("q") or "").strip()
    status = (request.args.get("status") or "").strip()
    query = core.Order.query
    if q:
        like = f"%{q}%"
        query = query.filter(core.db.or_(
            core.Order.order_id.ilike(like), core.Order.customer_name.ilike(like), core.Order.customer_email.ilike(like),
            core.Order.customer_discord.ilike(like), core.Order.customer_instagram.ilike(like)))
    if status:
        query = query.filter(core.Order.status == status)
    orders = query.order_by(core.Order.created_at.desc()).limit(300).all()
    return jsonify({"orders": [_order_summary(o) for o in orders], "statuses": core.ORDER_STATUSES,
                    "payment_statuses": core.PAYMENT_STATUSES})


def _admin_order_json(o):
    responses = _form_responses(o)
    logs = core.OrderLog.query.filter_by(order_id=o.order_id).order_by(core.OrderLog.created_at.desc()).all()
    return {
        **_order_summary(o),
        "link": o.unique_link,
        "tracking_url": f"{_site_url()}/order/{o.unique_link}",
        "customer_email": o.customer_email or None,
        "customer_discord": o.customer_discord or None,
        "customer_instagram": o.customer_instagram or None,
        "payment_method": o.payment_method or None,
        "payment_username": o.payment_username or None,
        "description": o.description,
        "notes": o.notes or None,
        "pin_set": bool(o.pin_hash),
        "discount": responses.get("_discount"),
        "answers": _public_form_responses(responses),
        "ref_images": _ref_image_urls(responses),
        "logs": [_log_json(entry) for entry in logs],
        "invoices": [_invoice_json(i, o.unique_link) for i in core.Invoice.query.filter_by(order_id=o.order_id).all()],
        "tickets": [_ticket_json(t) for t in core.Ticket.query.filter_by(order_id=o.order_id).all()],
        "payments": [{"amount": p.amount, "method": p.method, "recorded_at": _iso(p.recorded_at), "notes": p.notes}
                     for p in core.PaymentRecord.query.filter_by(order_id=o.order_id).all()],
        "final_images": [{"id": f.id, "url": _file_url("final-image", f.filename)}
                         for f in core.OrderFinalImage.query.filter_by(order_id=o.order_id).order_by(core.OrderFinalImage.uploaded_at).all()],
    }


def _admin_order_or_404(order_id):
    return core.Order.query.filter_by(order_id=order_id).first()


@bp.route("/admin/orders/<order_id>")
@admin_required
def admin_order(order_id):
    o = _admin_order_or_404(order_id)
    if not o:
        return _err("Order not found.", 404)
    return jsonify({"order": _admin_order_json(o), "statuses": core.ORDER_STATUSES, "payment_statuses": core.PAYMENT_STATUSES})


@bp.route("/admin/orders/<order_id>/update", methods=["POST"])
@admin_required
def admin_order_update(order_id):
    """Mirrors admin_update_order: status, payment status, ETA, notes, price."""
    o = _admin_order_or_404(order_id)
    if not o:
        return _err("Order not found.", 404)
    body = _body()
    if "status" in body and body["status"] not in core.ORDER_STATUSES:
        return _err("Unknown status.", 400)
    if "payment_status" in body and body["payment_status"] not in core.PAYMENT_STATUSES:
        return _err("Unknown payment status.", 400)
    old_status, old_payment = o.status, o.payment_status
    o.status = body.get("status", o.status)
    o.payment_status = body.get("payment_status", o.payment_status)
    if "eta" in body:
        o.eta = (body.get("eta") or "").strip()
    if "notes" in body:
        o.notes = (body.get("notes") or "").strip()
    if "price" in body:
        try:
            o.price = float(body["price"])
        except (TypeError, ValueError):
            return _err("Price must be a number.", 400)
    o.updated_at = datetime.utcnow()
    core.db.session.commit()
    core.auto_create_invoice(o)
    if old_status != o.status:
        core.add_log(order_id, "Status Updated", f"{old_status} → {o.status}")
        core.send_webhook(f"🔄 **Order Status Updated** — #{order_id}", embeds=[{
            "color": 0x22C55E,
            "fields": [
                {"name": "Customer", "value": o.customer_name, "inline": True},
                {"name": "New Status", "value": o.status, "inline": True},
                {"name": "Payment", "value": o.payment_status, "inline": True},
            ],
            "timestamp": datetime.utcnow().isoformat(),
        }], webhook_type="status")
    if old_payment != o.payment_status:
        core.add_log(order_id, "Payment Status Updated", f"{old_payment} → {o.payment_status}")
    return jsonify({"order": _admin_order_json(o)})


@bp.route("/admin/orders/<order_id>/log", methods=["POST"])
@admin_required
def admin_order_log(order_id):
    """Add a progress update (optionally with a WIP image, multipart) — like the website's order log form."""
    o = _admin_order_or_404(order_id)
    if not o:
        return _err("Order not found.", 404)
    src = request.form if request.form else _body()
    event_text = (src.get("event") or "").strip()
    if not event_text:
        return _err("Give the update a title.", 400)
    visible = str(src.get("customer_visible", "true")).lower() in ("1", "true", "on", "yes")
    image_filename = ""
    image = request.files.get("image")
    if image and image.filename and core.allowed_file(image.filename):
        image_filename = f"{uuid.uuid4().hex}.{image.filename.rsplit('.', 1)[1].lower()}"
        image.save(os.path.join(core.ORDER_LOG_IMAGES_DIR, image_filename))
    core.db.session.add(core.OrderLog(order_id=order_id, event=event_text, details=(src.get("details") or "").strip() or None,
                                      image_filename=image_filename, customer_visible=visible))
    core.db.session.commit()
    return jsonify({"order": _admin_order_json(o)}), 201


@bp.route("/admin/orders/<order_id>/final-images", methods=["POST"])
@admin_required
def admin_final_images(order_id):
    o = _admin_order_or_404(order_id)
    if not o:
        return _err("Order not found.", 404)
    count = 0
    for f in request.files.getlist("images"):
        if f and f.filename and core.allowed_file(f.filename):
            filename = f"{uuid.uuid4().hex}.{f.filename.rsplit('.', 1)[1].lower()}"
            f.save(os.path.join(core.FINAL_IMAGES_DIR, filename))
            core.db.session.add(core.OrderFinalImage(order_id=order_id, filename=filename))
            count += 1
    if not count:
        return _err("No images received (PNG, JPG, GIF or WEBP).", 400)
    core.db.session.commit()
    core.add_log(order_id, "Finished Artwork Uploaded", f"{count} file(s) added")
    return jsonify({"order": _admin_order_json(o)}), 201


@bp.route("/admin/orders/<order_id>/final-images/<int:img_id>", methods=["DELETE"])
@admin_required
def admin_final_image_delete(order_id, img_id):
    img = core.OrderFinalImage.query.filter_by(id=img_id, order_id=order_id).first()
    if not img:
        return _err("Image not found.", 404)
    path = os.path.join(core.FINAL_IMAGES_DIR, img.filename)
    if os.path.exists(path):
        os.remove(path)
    core.db.session.delete(img)
    core.db.session.commit()
    return "", 204


@bp.route("/admin/requests")
@admin_required
def admin_requests():
    reqs = core.CommissionRequest.query.order_by(core.CommissionRequest.created_at.desc()).limit(200).all()
    out = []
    for r in reqs:
        responses = _form_responses(r)
        out.append({
            "request_id": r.request_id, "customer_name": r.customer_name, "customer_email": r.customer_email or None,
            "customer_discord": r.customer_discord or None, "customer_instagram": r.customer_instagram or None,
            "commission_type": r.commission_type, "description": r.description, "status": r.status,
            "payment_method": r.payment_method or None, "discount": responses.get("_discount"),
            "answers": _public_form_responses(responses), "ref_images": _ref_image_urls(responses),
            "created_at": _iso(r.created_at),
        })
    return jsonify({"requests": out})


@bp.route("/admin/requests/<req_id>/action", methods=["POST"])
@admin_required
def admin_request_action(req_id):
    r = core.CommissionRequest.query.filter_by(request_id=req_id).first()
    if not r:
        return _err("Request not found.", 404)
    action = _body().get("action")
    if action not in ("accept", "decline"):
        return _err("Action must be accept or decline.", 400)
    r.status = "Accepted" if action == "accept" else "Declined"
    core.db.session.commit()
    return jsonify({"request_id": r.request_id, "status": r.status})


@bp.route("/admin/tickets")
@admin_required
def admin_tickets():
    tickets = core.Ticket.query.order_by(core.Ticket.created_at.desc()).limit(200).all()
    return jsonify({"tickets": [_ticket_json(t) for t in tickets]})


@bp.route("/admin/tickets/<ticket_id>")
@admin_required
def admin_ticket(ticket_id):
    t = core.Ticket.query.filter_by(ticket_id=ticket_id).first()
    if not t:
        return _err("Ticket not found.", 404)
    return jsonify({"ticket": _ticket_json(t, with_messages=True)})


@bp.route("/admin/tickets/<ticket_id>/reply", methods=["POST"])
@admin_required
def admin_ticket_reply(ticket_id):
    t = core.Ticket.query.filter_by(ticket_id=ticket_id).first()
    if not t:
        return _err("Ticket not found.", 404)
    message = (_body().get("message") or "").strip()
    if not message:
        return _err("Please write a reply.", 400)
    core.db.session.add(core.TicketMessage(ticket_id=ticket_id, sender="admin", message=message))
    core.db.session.commit()
    site = _site_url()
    core.send_webhook(content="", embeds=[{
        "title": f"🎨  ADMIN REPLY — #{ticket_id}",
        "description": f"Cioda has replied to ticket **#{ticket_id}**.\n​",
        "color": 0xC084FC,
        "fields": [
            {"name": "📦  Order ID", "value": f"`{t.order_id or 'N/A'}`", "inline": True},
            {"name": "👤  Customer", "value": t.customer_name, "inline": True},
            {"name": "​", "value": "​", "inline": False},
            {"name": "📌  Subject", "value": t.subject or "(no subject)", "inline": False},
            {"name": "💬  Reply", "value": message[:1000], "inline": False},
            {"name": "🔗  Admin Link", "value": f"{site}/admin/tickets/{ticket_id}", "inline": True},
            {"name": "💬  Ticket Link", "value": f"{site}/order/{t.order_link}/ticket/{ticket_id}" if t.order_link else "N/A", "inline": True},
        ],
        "footer": {"text": f"Ticket {ticket_id}"},
        "timestamp": datetime.utcnow().isoformat(),
    }], webhook_type="ticket")
    settings = core.SiteSettings.query.first()
    if t.discord_thread_id and settings.discord_bot_token:
        core._send_to_discord_thread(t.discord_thread_id, f"**🎨 Admin reply**\n{message[:1800]}", settings.discord_bot_token)
    return jsonify({"ticket": _ticket_json(t, with_messages=True)})


@bp.route("/admin/tickets/<ticket_id>/close", methods=["POST"])
@admin_required
def admin_ticket_close(ticket_id):
    t = core.Ticket.query.filter_by(ticket_id=ticket_id).first()
    if not t:
        return _err("Ticket not found.", 404)
    t.status = "Closed"
    core.db.session.commit()
    core.send_webhook(content="", embeds=[{
        "title": f"🔒  TICKET CLOSED — #{ticket_id}",
        "description": f"Ticket **#{ticket_id}** has been closed by admin.\n​",
        "color": 0x374151,
        "fields": [
            {"name": "📦  Order ID", "value": f"`{t.order_id or 'N/A'}`", "inline": True},
            {"name": "👤  Customer", "value": t.customer_name, "inline": True},
            {"name": "📌  Subject", "value": t.subject or "(no subject)", "inline": False},
        ],
        "footer": {"text": f"Ticket {ticket_id}"},
        "timestamp": datetime.utcnow().isoformat(),
    }], webhook_type="ticket")
    return jsonify({"ticket": _ticket_json(t, with_messages=True)})


@bp.route("/admin/invoices")
@admin_required
def admin_invoices():
    invs = core.Invoice.query.order_by(core.Invoice.created_at.desc()).limit(300).all()
    links = {o.order_id: o.unique_link for o in core.Order.query.filter(core.Order.order_id.in_([i.order_id for i in invs])).all()}
    return jsonify({"invoices": [_invoice_json(i, links.get(i.order_id)) for i in invs]})


@bp.route("/admin/invoices/<invoice_id>/mark-paid", methods=["POST"])
@admin_required
def admin_invoice_paid(invoice_id):
    """Mirrors admin_mark_paid: invoice paid, order Paid, payment record, Discord webhook."""
    inv = core.Invoice.query.filter_by(invoice_id=invoice_id).first()
    if not inv:
        return _err("Invoice not found.", 404)
    if inv.paid:
        return _err("That invoice is already marked paid.", 400)
    body = _body()
    try:
        amount = float(body.get("amount", inv.amount))
    except (TypeError, ValueError):
        return _err("Amount must be a number.", 400)
    inv.paid = True
    inv.paid_at = datetime.utcnow()
    order = core.Order.query.filter_by(order_id=inv.order_id).first()
    if order:
        order.payment_status = "Paid"
        core.add_log(inv.order_id, "Payment Received", f"Invoice {invoice_id} marked paid")
    core.db.session.add(core.PaymentRecord(order_id=inv.order_id, invoice_id=invoice_id, amount=amount,
                                           notes=(body.get("notes") or "").strip()))
    core.db.session.commit()
    core.send_webhook(f"💸 **Payment Received** — Invoice #{invoice_id}", embeds=[{
        "color": 0x22C55E,
        "fields": [
            {"name": "Order", "value": inv.order_id, "inline": True},
            {"name": "Amount", "value": f"${inv.amount:.2f}", "inline": True},
            {"name": "Customer", "value": inv.customer_name or "N/A", "inline": True},
        ],
        "timestamp": datetime.utcnow().isoformat(),
    }])
    return jsonify({"invoice": _invoice_json(inv, order.unique_link if order else None)})


# ─── push registration ─────────────────────────────────────────────────────────────


def _valid_push_token(token):
    return token.startswith(("ExponentPushToken[", "ExpoPushToken[")) and token.endswith("]") and len(token) <= 255


def _register_device(token, role, order_link=None):
    if not _valid_push_token(token):
        return _err("Invalid push token.", 400)
    existing = PushDevice.query.filter_by(token=token, role=role, order_link=order_link).first()
    if not existing:
        core.db.session.add(PushDevice(token=token, role=role, order_link=order_link))
        core.db.session.commit()
    return jsonify({"registered": True})


def _unregister_device(token, role, order_link=None):
    PushDevice.query.filter_by(token=token, role=role, order_link=order_link).delete(synchronize_session=False)
    core.db.session.commit()
    return "", 204


@bp.route("/admin/push", methods=["POST", "DELETE"])
@admin_required
def admin_push():
    token = (_body().get("token") or "").strip()
    if request.method == "DELETE":
        return _unregister_device(token, "admin")
    return _register_device(token, "admin")


@bp.route("/admin/push/test", methods=["POST"])
@admin_required
def admin_push_test():
    if not PushDevice.query.filter_by(role="admin").first():
        return _err("No phones are registered for admin notifications yet.", 400)
    _dispatch([("admin", None, "Test notification", "Notifications from your commission site are working.", {"kind": "test"})])
    return jsonify({"sent": True})


@bp.route("/orders/<link>/push", methods=["POST", "DELETE"])
@order_required
def order_push(link):
    token = (_body().get("token") or "").strip()
    if request.method == "DELETE":
        return _unregister_device(token, "customer", link)
    return _register_device(token, "customer", link)


# ─── push dispatch (SQLAlchemy events) ───────────────────────────────────────────────


def _pending(session):
    return session.info.setdefault("mobile_push_pending", [])


def _install_push_hooks():
    Order, Ticket, TicketMessage, CommissionRequest = core.Order, core.Ticket, core.TicketMessage, core.CommissionRequest

    @event.listens_for(Order.status, "set")
    def _order_status(target, value, oldvalue, initiator):
        if oldvalue in (NO_VALUE, None) or oldvalue == value or target.id is None:
            return
        from sqlalchemy.orm import object_session
        sess = object_session(target)
        if sess is not None:
            _pending(sess).append(("customer", target.unique_link, f"Order {target.order_id}: {value}",
                                   _status_blurb(value), {"kind": "order", "link": target.unique_link}))

    @event.listens_for(Order.payment_status, "set")
    def _order_payment(target, value, oldvalue, initiator):
        if oldvalue in (NO_VALUE, None) or oldvalue == value or target.id is None or value != "Paid":
            return
        from sqlalchemy.orm import object_session
        sess = object_session(target)
        if sess is not None:
            _pending(sess).append(("customer", target.unique_link, f"Payment received — {target.order_id}",
                                   "Thank you! Your payment has been marked as paid.", {"kind": "order", "link": target.unique_link}))

    @event.listens_for(Session, "after_flush")
    def _after_flush(session, flush_context):
        new = list(session.new)
        # Remembered across flushes until commit: routes often flush the new
        # Ticket first and add its opening message in a later flush.
        new_ticket_ids = session.info.setdefault("mobile_new_tickets", set())
        new_ticket_ids.update(o.ticket_id for o in new if isinstance(o, Ticket))
        # A request form submission (website or app) saves the request and its
        # auto-created order together; point the push at that order.
        new_orders = [o for o in new if isinstance(o, core.Order)]
        for obj in new:
            if isinstance(obj, CommissionRequest):
                order = next((o for o in new_orders if o.customer_name == obj.customer_name), None)
                data = {"kind": "order", "order_id": order.order_id} if order else {"kind": "requests"}
                _pending(session).append(("admin", None, "New commission request",
                                          f"{obj.customer_name} · {obj.commission_type or 'Commission'}", data))
            elif isinstance(obj, Ticket):
                _pending(session).append(("admin", None, f"New ticket from {obj.customer_name}",
                                          obj.subject or "Support ticket", {"kind": "ticket", "ticket_id": obj.ticket_id}))
            elif isinstance(obj, TicketMessage):
                if obj.ticket_id in new_ticket_ids:
                    continue  # the opening message; the "new ticket" push covers it
                with session.no_autoflush:  # we're mid-flush; don't trigger another one
                    ticket = session.query(Ticket).filter_by(ticket_id=obj.ticket_id).first()
                if not ticket:
                    continue
                preview = (obj.message or "")[:140]
                if obj.sender == "customer":
                    _pending(session).append(("admin", None, f"Reply from {ticket.customer_name}", preview,
                                              {"kind": "ticket", "ticket_id": ticket.ticket_id}))
                elif obj.sender == "admin" and ticket.order_link:
                    _pending(session).append(("customer", ticket.order_link, "Cioda replied to your ticket", preview,
                                              {"kind": "ticket", "link": ticket.order_link, "ticket_id": ticket.ticket_id}))

    @event.listens_for(Session, "after_commit")
    def _after_commit(session):
        session.info.pop("mobile_new_tickets", None)
        items = session.info.pop("mobile_push_pending", None)
        if items:
            _dispatch(items)

    @event.listens_for(Session, "after_rollback")
    def _after_rollback(session):
        session.info.pop("mobile_push_pending", None)
        session.info.pop("mobile_new_tickets", None)


def _status_blurb(status):
    return {
        "Accepted": "Great news, your commission has been accepted!",
        "Declined": "Your commission request was declined. Open the app for details.",
        "Pending": "Your commission is queued up and waiting to start.",
        "In Progress": "Cioda has started working on your commission.",
        "Done": "Your commission is finished! Open the app to see it.",
    }.get(status, f"Your order status is now {status}.")


def _dispatch(items):
    """Send on a background thread with its own app context — never blocks or breaks the request."""
    app = core.app

    def run():
        try:
            with app.app_context():
                messages = []
                for role, link, title, body, data in items:
                    q = PushDevice.query.filter_by(role=role)
                    if role == "customer":
                        q = q.filter_by(order_link=link)
                    for d in q.all():
                        messages.append({"to": d.token, "title": title, "body": body, "data": data,
                                         "sound": "default", "priority": "high"})
                if not messages:
                    return
                dead = set()
                for i in range(0, len(messages), 100):  # Expo accepts up to 100 per request
                    batch = messages[i:i + 100]
                    res = http.post(EXPO_PUSH_URL, json=batch, timeout=10).json()
                    for msg, ticket in zip(batch, res.get("data", [])):
                        if ticket.get("status") == "error" and (ticket.get("details") or {}).get("error") == "DeviceNotRegistered":
                            dead.add(msg["to"])
                if dead:
                    PushDevice.query.filter(PushDevice.token.in_(dead)).delete(synchronize_session=False)
                    core.db.session.commit()
        except Exception:  # noqa: BLE001 - a push failure must never surface anywhere
            log.exception("mobile push dispatch failed")

    threading.Thread(target=run, daemon=True).start()
