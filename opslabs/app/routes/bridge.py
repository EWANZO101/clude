"""
Discord bridge endpoints.

  Bot → web
    /discord/message       mirror message
    /discord/status        status change from a Discord button
    /discord/link          link Discord → web user (with ticket transfer)
    /discord/unlink
    /discord/resolve-user  ticket-panel auto-create
    /discord/my-tickets    list a Discord user's tickets
    /discord/dm/open-tickets   a user's open tickets that accept DM replies
    /discord/dm/message        a customer's DM reply → ticket message

Auth: shared secret header (X-Bridge-Key) = DISCORD_BRIDGE_KEY env.
"""
import secrets
from datetime import datetime
from functools import wraps
from flask import Blueprint, request, jsonify, current_app, abort, url_for
from .. import db
from ..models import (Ticket, TicketMessage, User, Company, TicketCategory, DiscordLinkCode,
                      TICKET_STATUS_FLOW, TICKET_STATUS_VALID, STATUS_META, normalise_status)
from ..discord_dm import notify_owner, notify_staff

bridge_bp = Blueprint("bridge", __name__)


def bridge_auth(f):
    @wraps(f)
    def wrapper(*a, **kw):
        sent = request.headers.get("X-Bridge-Key", "")
        expected = current_app.config["DISCORD_BRIDGE_KEY"]
        if not expected or sent != expected:
            abort(401)
        return f(*a, **kw)
    return wrapper


# ─── Discord → web: mirror chat message ──────────────────────────────
@bridge_bp.route("/discord/message", methods=["POST"])
@bridge_auth
def discord_message():
    data = request.get_json(silent=True) or {}
    channel_id = str(data.get("channel_id") or "")
    body = (data.get("body") or "").strip()
    author = data.get("author") or "discord-user"
    discord_id = str(data.get("discord_id") or "")
    discord_msg_id = str(data.get("discord_message_id") or "") or None

    if not (channel_id and body):
        return jsonify({"error": "channel_id and body required"}), 400

    t = Ticket.query.filter_by(discord_channel_id=channel_id).first()
    if not t:
        return jsonify({"error": "ticket not found"}), 404
    if t.is_terminal:
        return jsonify({"error": "ticket is closed"}), 400

    user = User.query.filter_by(discord_id=discord_id).first() if discord_id else None

    msg = TicketMessage(
        ticket_id=t.id,
        user_id=user.id if user else None,
        source="discord",
        discord_message_id=discord_msg_id,
        discord_author=author,
        body=body,
    )
    db.session.add(msg)
    t.updated_at = datetime.utcnow()
    db.session.commit()
    notify_owner(t, kind="message", body=body, author=author,
                 author_role=(user.role if user else "staff"),
                 from_owner=bool(user and user.id == t.user_id), via="channel")
    if user and user.id == t.user_id:
        notify_staff(t, kind="customer_message", body=body, author=user.username,
                     via="ticket channel")
    return jsonify({"ok": True, "message_id": msg.id})


# ─── Discord → web: status change (5-stage) ──────────────────────────
@bridge_bp.route("/discord/status", methods=["POST"])
@bridge_auth
def discord_status():
    data = request.get_json(silent=True) or {}
    channel_id = str(data.get("channel_id") or "")
    raw = (data.get("status") or "").strip()
    actor = data.get("actor") or "discord-user"
    resolution_note = (data.get("resolution_note") or "").strip() or None

    new_status = normalise_status(raw) if raw in TICKET_STATUS_VALID else None
    if new_status not in TICKET_STATUS_FLOW:
        return jsonify({"error": "bad status"}), 400

    t = Ticket.query.filter_by(discord_channel_id=channel_id).first()
    if not t:
        return jsonify({"error": "ticket not found"}), 404

    meta = STATUS_META[new_status]
    t.status = new_status
    if resolution_note:
        t.resolution_note = resolution_note
    if meta.get("terminal"):
        t.closed_at = datetime.utcnow()
    else:
        t.closed_at = None
    t.updated_at = datetime.utcnow()

    body = f"Status set to **{meta['label']}** by {actor} (via Discord)."
    if resolution_note:
        body += f"\n\n> {resolution_note}"
    db.session.add(TicketMessage(
        ticket_id=t.id, source="system", body=body, discord_author=actor,
    ))
    db.session.commit()
    notify_owner(t, kind="status", body=resolution_note or "", author=actor)
    return jsonify({"ok": True, "status": new_status, "ticket": t.to_dict()})


# ─── Link Discord → web user, transferring placeholder tickets ───────
@bridge_bp.route("/discord/link", methods=["POST"])
@bridge_auth
def discord_link():
    data = request.get_json(silent=True) or {}
    code = (data.get("code") or "").strip()
    discord_id = str(data.get("discord_id") or "")
    discord_username = data.get("discord_username") or None
    if not discord_id:
        return jsonify({"error": "discord_id required"}), 400
    if not code:
        # Linking by username/email let anyone claim anyone's account.
        return jsonify({"error": "Get a link code from the website first "
                                 "(open a ticket → Discord DMs → Get my link code)."}), 400

    target = DiscordLinkCode.redeem(code)
    if not target:
        db.session.rollback()
        return jsonify({"error": "That code is invalid or has expired. Get a new one on the website."}), 404

    placeholder = User.query.filter(
        User.discord_id == discord_id,
        User.id != target.id,
    ).first()

    transferred_tickets = 0
    transferred_messages = 0
    if placeholder:
        if not placeholder.email.endswith("@opslabsystems.local"):
            return jsonify({
                "error": (
                    f"discord_id is already linked to user '{placeholder.username}'. "
                    f"Ask staff to unlink it first."
                ),
            }), 409

        transferred_tickets = Ticket.query.filter_by(user_id=placeholder.id) \
            .update({"user_id": target.id}, synchronize_session=False)
        transferred_messages = TicketMessage.query.filter_by(user_id=placeholder.id) \
            .update({"user_id": target.id}, synchronize_session=False)
        Ticket.query.filter_by(assigned_to_id=placeholder.id) \
            .update({"assigned_to_id": target.id}, synchronize_session=False)

        db.session.delete(placeholder)

    target.discord_id = discord_id
    target.discord_username = discord_username
    db.session.commit()

    return jsonify({
        "ok": True,
        "user": target.username,
        "user_id": target.id,
        "transferred_tickets": transferred_tickets,
        "transferred_messages": transferred_messages,
    })


@bridge_bp.route("/discord/unlink", methods=["POST"])
@bridge_auth
def discord_unlink():
    data = request.get_json(silent=True) or {}
    discord_id = str(data.get("discord_id") or "")
    if not discord_id:
        return jsonify({"error": "discord_id required"}), 400
    user = User.query.filter_by(discord_id=discord_id).first()
    if not user:
        return jsonify({"error": "not linked"}), 404
    user.discord_id = None
    user.discord_username = None
    db.session.commit()
    return jsonify({"ok": True, "user": user.username})


# ─── Resolve / auto-create (ticket panel) ─────────────────────────────
@bridge_bp.route("/discord/resolve-user", methods=["POST"])
@bridge_auth
def discord_resolve_user():
    data = request.get_json(silent=True) or {}
    discord_id = str(data.get("discord_id") or "")
    discord_username = (data.get("discord_username") or "").strip() or None

    if not discord_id:
        return jsonify({"error": "discord_id required"}), 400

    user = User.query.filter_by(discord_id=discord_id).first()

    if user is None:
        if not _allow_auto_create():
            return jsonify({"error": "no linked user; ask the user to /link-account first"}), 404

        base = (discord_username or f"discord_{discord_id}").split("#", 1)[0]
        base = "".join(c for c in base if c.isalnum() or c in "._-")[:30] or f"d_{discord_id[-6:]}"

        username = base
        i = 1
        while User.query.filter_by(username=username).first():
            i += 1
            username = f"{base}{i}"

        email = f"{username}+discord@opslabsystems.local"
        user = User(
            username=username,
            email=email,
            role="user",
            is_active=True,
            discord_id=discord_id,
            discord_username=discord_username,
        )
        user.set_password(secrets.token_urlsafe(32))
        db.session.add(user)
        db.session.commit()
        current_app.logger.info("Auto-created placeholder user '%s' for discord_id %s",
                                username, discord_id)
    else:
        if discord_username and user.discord_username != discord_username:
            user.discord_username = discord_username
            db.session.commit()

    default_company = Company.query.filter_by(is_active=True).order_by(Company.id).first()
    if not default_company:
        return jsonify({"error": "no active company configured"}), 500

    categories = {
        c.name: c.id
        for c in TicketCategory.query.filter_by(
            company_id=default_company.id, is_active=True
        ).all()
    }

    return jsonify({
        "user_id": user.id,
        "username": user.username,
        "is_placeholder": user.email.endswith("@opslabsystems.local"),
        "default_company_id": default_company.id,
        "default_company": default_company.name,
        "categories": categories,
    })


# ─── A Discord user's own tickets ────────────────────────────────────
@bridge_bp.route("/discord/my-tickets", methods=["POST"])
@bridge_auth
def discord_my_tickets():
    data = request.get_json(silent=True) or {}
    discord_id = str(data.get("discord_id") or "")
    limit = min(int(data.get("limit") or 10), 25)
    if not discord_id:
        return jsonify({"error": "discord_id required"}), 400

    user = User.query.filter_by(discord_id=discord_id).first()
    if not user:
        return jsonify({"tickets": [], "user_id": None, "is_placeholder": False})

    tickets = (Ticket.query
               .filter_by(user_id=user.id)
               .order_by(Ticket.updated_at.desc())
               .limit(limit).all())

    return jsonify({
        "user_id": user.id,
        "username": user.username,
        "is_placeholder": user.email.endswith("@opslabsystems.local"),
        "tickets": [t.to_dict() for t in tickets],
    })


def _allow_auto_create() -> bool:
    val = current_app.config.get("DISCORD_AUTO_CREATE_USERS")
    if val is None:
        return True
    return str(val).lower() in ("1", "true", "yes", "on")


# ─── DMs: a user's open tickets that accept Discord replies ──────────
@bridge_bp.route("/discord/dm/open-tickets", methods=["POST"])
@bridge_auth
def discord_dm_open_tickets():
    data = request.get_json(silent=True) or {}
    discord_id = str(data.get("discord_id") or "")
    user = User.query.filter_by(discord_id=discord_id).first() if discord_id else None
    if not user:
        return jsonify({"linked": False, "tickets": []})
    rows = (Ticket.query.filter(Ticket.user_id == user.id,
                                Ticket.reply_via.in_(("discord", "both")))
            .order_by(Ticket.updated_at.desc()).limit(50).all())
    return jsonify({"linked": True, "username": user.username,
                    "tickets": [{"id": t.id, "subject": t.subject, "status": t.status}
                                for t in rows if not t.is_terminal]})


# ─── DMs: customer reply from a Discord DM → ticket message ──────────
@bridge_bp.route("/discord/dm/message", methods=["POST"])
@bridge_auth
def discord_dm_message():
    data = request.get_json(silent=True) or {}
    discord_id = str(data.get("discord_id") or "")
    body = (data.get("body") or "").strip()
    try:
        ticket_id = int(data.get("ticket_id"))
    except (TypeError, ValueError):
        return jsonify({"error": "ticket_id required"}), 400
    if not (discord_id and body):
        return jsonify({"error": "discord_id and body required"}), 400

    user = User.query.filter_by(discord_id=discord_id).first()
    t = Ticket.query.get(ticket_id)
    if not user or not t or t.user_id != user.id:
        return jsonify({"error": "ticket not found"}), 404
    if t.reply_via not in ("discord", "both"):
        return jsonify({"error": "This ticket only accepts replies on the website."}), 403
    if t.is_terminal:
        return jsonify({"error": "This ticket is closed."}), 400

    msg = TicketMessage(ticket_id=t.id, user_id=user.id, source="discord",
                        discord_message_id=str(data.get("discord_message_id") or "") or None,
                        discord_author=data.get("author") or user.discord_username, body=body[:8000])
    db.session.add(msg)
    t.updated_at = datetime.utcnow()
    db.session.commit()
    notify_staff(t, kind="customer_message", body=msg.body, author=user.username,
                 via="Discord DM")
    return jsonify({"ok": True, "message_id": msg.id, "channel_id": t.discord_channel_id,
                    "ticket": {"id": t.id, "subject": t.subject}})


# ─── Staff inbox in Discord DMs (reply / status / browse from the bot) ─
def _staff_from(data):
    discord_id = str(data.get("discord_id") or "")
    user = User.query.filter_by(discord_id=discord_id).first() if discord_id else None
    if not user or not user.is_active or not user.is_staff:
        abort(403)
    return user


def _ticket_arg(data):
    try:
        t = Ticket.query.get(int(data.get("ticket_id")))
    except (TypeError, ValueError):
        t = None
    if not t:
        abort(404)
    return t


def _ticket_summary(t):
    return {"id": t.id, "subject": t.subject, "status": t.status, "priority": t.priority,
            "owner": t.owner.username if t.owner else "", "reply_via": t.reply_via or "web",
            "category": t.category.name if t.category else "General",
            "updated_at": t.updated_at.isoformat() if t.updated_at else None}


@bridge_bp.route("/discord/staff/tickets", methods=["POST"])
@bridge_auth
def discord_staff_tickets():
    _staff_from(request.get_json(silent=True) or {})
    rows = (Ticket.query.filter(Ticket.status.notin_(("resolved", "denied")))
            .order_by(Ticket.updated_at.desc()).limit(25).all())
    return jsonify({"ok": True, "tickets": [_ticket_summary(t) for t in rows]})


@bridge_bp.route("/discord/staff/ticket", methods=["POST"])
@bridge_auth
def discord_staff_ticket():
    data = request.get_json(silent=True) or {}
    _staff_from(data)
    t = _ticket_arg(data)
    msgs = (TicketMessage.query.filter_by(ticket_id=t.id)
            .order_by(TicketMessage.id.desc()).limit(8).all())[::-1]
    return jsonify({"ok": True, "ticket": _ticket_summary(t),
                    "web_url": url_for("tickets.view", tid=t.id, _external=True),
                    "messages": [m.to_dict() for m in msgs]})


@bridge_bp.route("/discord/staff/reply", methods=["POST"])
@bridge_auth
def discord_staff_reply():
    from .tickets import _set_status, _notify_bot
    data = request.get_json(silent=True) or {}
    staff = _staff_from(data)
    t = _ticket_arg(data)
    body = (data.get("body") or "").strip()[:8000]
    internal = bool(data.get("internal"))
    if not body:
        return jsonify({"ok": False, "error": "Empty message."}), 400
    if t.is_terminal:
        return jsonify({"ok": False, "error": f"Ticket #{t.id} is closed."}), 400

    db.session.add(TicketMessage(ticket_id=t.id, user_id=staff.id, source="discord",
                                 discord_author=staff.discord_username, body=body,
                                 is_internal=internal))
    t.updated_at = datetime.utcnow()
    db.session.commit()
    if internal:
        return jsonify({"ok": True, "ticket_id": t.id, "internal": True})

    if t.status == "seen":
        _set_status(t, "in_progress", actor=staff.username, notify_discord=True, system_message=False)
    notify_owner(t, kind="message", body=body, author=staff.username,
                 author_role=staff.role, via="channel")
    if t.discord_channel_id:
        _notify_bot("/discord/ticket/message", {
            "channel_id": t.discord_channel_id, "ticket_id": t.id,
            "author": staff.username, "author_role": staff.role, "body": body,
        })
    return jsonify({"ok": True, "ticket_id": t.id})


@bridge_bp.route("/discord/staff/status", methods=["POST"])
@bridge_auth
def discord_staff_status():
    from .tickets import _set_status
    data = request.get_json(silent=True) or {}
    staff = _staff_from(data)
    t = _ticket_arg(data)
    raw = (data.get("status") or "").strip()
    new_status = normalise_status(raw) if raw in TICKET_STATUS_VALID else None
    if new_status not in TICKET_STATUS_FLOW:
        return jsonify({"ok": False, "error": "Bad status."}), 400
    note = (data.get("note") or "").strip()[:1000] or None
    _set_status(t, new_status, actor=staff.username, resolution_note=note, notify_discord=True)
    return jsonify({"ok": True, "ticket_id": t.id, "status": new_status})
