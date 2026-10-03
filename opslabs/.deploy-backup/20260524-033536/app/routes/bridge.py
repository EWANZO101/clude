"""
Discord bridge endpoints.

The bot calls these when:
  - a Discord user posts a message in a ticket channel
  - a Discord user closes/reopens a ticket from Discord
  - linking a Discord account to a web user (with automatic ticket transfer)
  - resolving a Discord ID → web user (auto-creates a placeholder if missing)
  - listing a Discord user's tickets

Auth: shared secret header (X-Bridge-Key) — set DISCORD_BRIDGE_KEY in env.
"""
import secrets
from datetime import datetime
from functools import wraps
from flask import Blueprint, request, jsonify, current_app, abort
from .. import db
from ..models import Ticket, TicketMessage, User, Company, TicketCategory

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


# ---------------------------------------------------------------------------
# Discord -> web: mirror chat message
# ---------------------------------------------------------------------------
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
    if t.status == "closed":
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
    return jsonify({"ok": True, "message_id": msg.id})


# ---------------------------------------------------------------------------
# Discord -> web: status change
# ---------------------------------------------------------------------------
@bridge_bp.route("/discord/status", methods=["POST"])
@bridge_auth
def discord_status():
    data = request.get_json(silent=True) or {}
    channel_id = str(data.get("channel_id") or "")
    new_status = data.get("status")
    actor = data.get("actor") or "discord-user"
    if new_status not in ("open", "pending", "closed"):
        return jsonify({"error": "bad status"}), 400
    t = Ticket.query.filter_by(discord_channel_id=channel_id).first()
    if not t:
        return jsonify({"error": "ticket not found"}), 404
    t.status = new_status
    t.closed_at = datetime.utcnow() if new_status == "closed" else None
    t.updated_at = datetime.utcnow()
    db.session.add(TicketMessage(
        ticket_id=t.id, source="system",
        body=f"Status set to **{new_status}** by {actor} (via Discord).",
        discord_author=actor,
    ))
    db.session.commit()
    return jsonify({"ok": True})


# ---------------------------------------------------------------------------
# Link Discord account → web user, transferring placeholder tickets.
# ---------------------------------------------------------------------------
@bridge_bp.route("/discord/link", methods=["POST"])
@bridge_auth
def discord_link():
    data = request.get_json(silent=True) or {}
    identifier = (data.get("identifier") or "").strip()
    discord_id = str(data.get("discord_id") or "")
    discord_username = data.get("discord_username") or None
    if not (identifier and discord_id):
        return jsonify({"error": "identifier and discord_id required"}), 400

    target = User.query.filter(
        (User.username == identifier) | (User.email == identifier.lower())
    ).first()
    if not target:
        return jsonify({"error": "user not found"}), 404

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


# ---------------------------------------------------------------------------
# Unlink
# ---------------------------------------------------------------------------
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


# ---------------------------------------------------------------------------
# Resolve / auto-create (used by the ticket panel)
# ---------------------------------------------------------------------------
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


# ---------------------------------------------------------------------------
# A Discord user's own tickets (used by /my-tickets slash command)
# ---------------------------------------------------------------------------
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