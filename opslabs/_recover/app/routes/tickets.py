"""Ticket routes — create, view, reply, live-poll endpoint, status flow."""
from datetime import datetime
import requests
from flask import (Blueprint, render_template, request, redirect, url_for,
                   flash, jsonify, abort, current_app)
from flask_login import login_required, current_user
from .. import db
from ..models import (Ticket, TicketMessage, TicketCategory, Company,
                      TICKET_STATUS_VALID, TICKET_STATUS_FLOW, STATUS_META,
                      normalise_status)

tickets_bp = Blueprint("tickets", __name__)


# Status-set permissions
USER_ALLOWED_STATUSES  = {"seen"}                       # client can't change much
STAFF_ALLOWED_STATUSES = set(TICKET_STATUS_FLOW)        # staff can do anything


def _can_view_ticket(ticket, user):
    if user.is_staff:
        return True
    return ticket.user_id == user.id


def _notify_bot(endpoint, payload):
    url = current_app.config["DISCORD_BOT_URL"].rstrip("/") + endpoint
    headers = {"X-Bridge-Key": current_app.config["DISCORD_BRIDGE_KEY"]}
    try:
        r = requests.post(url, json=payload, headers=headers, timeout=4)
        if r.ok:
            return r.json()
        current_app.logger.warning(f"Bot bridge {endpoint} -> {r.status_code}")
    except requests.RequestException as e:
        current_app.logger.warning(f"Bot bridge unreachable: {e}")
    return None


# ---------- List ----------
@tickets_bp.route("/")
@login_required
def index():
    if getattr(current_user, 'is_staff', False):
        q = Ticket.query.order_by(Ticket.updated_at.desc())
        scope = "staff"
    else:
        q = Ticket.query.filter_by(user_id=current_user.id).order_by(Ticket.updated_at.desc())
        scope = "own"

    raw = request.args.get("status")
    status = normalise_status(raw) if raw else None
    if status in TICKET_STATUS_FLOW:
        q = q.filter_by(status=status)
    tickets = q.limit(200).all()
    return render_template("tickets/index.html", tickets=tickets,
                           scope=scope, current_status=status)


# ---------- Create ----------
@tickets_bp.route("/new", methods=["GET", "POST"])
@login_required
def new():
    companies = Company.query.filter_by(is_active=True).all()
    if request.method == "POST":
        subject = request.form.get("subject", "").strip()
        body = request.form.get("body", "").strip()
        company_id = request.form.get("company_id", type=int)
        category_id = request.form.get("category_id", type=int) or None
        priority = request.form.get("priority", "normal").strip()
        if priority not in ("low", "normal", "high", "urgent"):
            priority = "normal"
        if not subject or not body or not company_id:
            flash("Please fill in subject, description, and company.", "error")
            return render_template("tickets/new.html", companies=companies)

        t = Ticket(
            user_id=current_user.id,
            company_id=company_id,
            category_id=category_id,
            subject=subject[:200],
            priority=priority,
            status="seen",     # new tickets land at "seen"
        )
        db.session.add(t)
        db.session.flush()
        db.session.add(TicketMessage(
            ticket_id=t.id, user_id=current_user.id, source="web", body=body,
        ))
        db.session.commit()

        # Tell the bot to make a channel (it will reply with channel_id)
        if current_app.config.get("DISCORD_BOT_URL"):
            bot_resp = _notify_bot("/discord/ticket/create", {
                "ticket_id": t.id,
                "subject": subject[:200],
                "owner": getattr(current_user, 'username', ''),
                "owner_discord_id": getattr(current_user, 'discord_id', ''),
                "category": t.category.name if t.category else "General",
                "company": t.company.name if t.company else "OpsLab Systems",
                "priority": priority,
                "initial_message": body,
                "status": "seen",
            })
            if bot_resp and bot_resp.get("channel_id"):
                t.discord_channel_id = bot_resp["channel_id"]
                db.session.commit()

        flash(f"Ticket #{t.id} created.", "success")
        return redirect(url_for("tickets.view", tid=t.id))
    return render_template("tickets/new.html", companies=companies)


# ---------- View ----------
@tickets_bp.route("/<int:tid>")
@login_required
def view(tid):
    t = Ticket.query.get_or_404(tid)
    if not _can_view_ticket(t, current_user):
        abort(403)
    return render_template("tickets/view.html", ticket=t,
                           status_flow=TICKET_STATUS_FLOW,
                           status_meta=STATUS_META)


# ---------- Reply ----------
@tickets_bp.route("/<int:tid>/reply", methods=["POST"])
@login_required
def reply(tid):
    t = Ticket.query.get_or_404(tid)
    if not _can_view_ticket(t, current_user):
        abort(403)
    if t.is_terminal:
        return jsonify({"ok": False, "error": "Ticket is closed."}), 400

    body = (request.form.get("body") or "").strip()
    is_internal = bool(request.form.get("is_internal")) and getattr(current_user, 'is_staff', False)
    if not body:
        return jsonify({"ok": False, "error": "Empty message"}), 400

    msg = TicketMessage(
        ticket_id=t.id, user_id=current_user.id, source="web",
        body=body, is_internal=is_internal,
    )
    db.session.add(msg)
    t.updated_at = datetime.utcnow()
    db.session.commit()

    # When a staff member replies for the first time on a "seen" ticket,
    # bump it forward to "in_progress" so the user sees real movement.
    if (getattr(current_user, 'is_staff', False) and not is_internal
            and t.status == "seen"):
        _set_status(t, "in_progress", actor=getattr(current_user, 'username', ''),
                    notify_discord=True, system_message=False)

    if not is_internal and t.discord_channel_id:
        _notify_bot("/discord/ticket/message", {
            "channel_id": t.discord_channel_id,
            "ticket_id": t.id,
            "author": getattr(current_user, 'username', ''),
            "author_role": getattr(current_user, 'role', ''),
            "body": body,
        })
    return jsonify({"ok": True, "message": msg.to_dict()})


# ---------- Status change ----------
@tickets_bp.route("/<int:tid>/status", methods=["POST"])
@login_required
def status(tid):
    t = Ticket.query.get_or_404(tid)
    if not _can_view_ticket(t, current_user):
        abort(403)

    raw = (request.form.get("status")
           or (request.json or {}).get("status") or "").strip()
    new_status = normalise_status(raw) if raw else None
    if new_status not in TICKET_STATUS_FLOW:
        return jsonify({"error": "Bad status"}), 400

    if getattr(current_user, 'is_staff', False):
        if new_status not in STAFF_ALLOWED_STATUSES:
            return jsonify({"error": "Forbidden"}), 403
    else:
        # Clients can only mark their own ticket as resolved (i.e. close it).
        if new_status != "resolved":
            return jsonify({"error": "Forbidden"}), 403

    resolution_note = (request.form.get("resolution_note")
                       or (request.json or {}).get("resolution_note") or "").strip() or None

    _set_status(t, new_status, actor=getattr(current_user, 'username', ''),
                resolution_note=resolution_note, notify_discord=True)

    return jsonify({"ok": True, "status": new_status,
                    "ticket": t.to_dict()})


def _set_status(t: Ticket, new_status: str, *, actor: str,
                resolution_note: str | None = None,
                notify_discord: bool = True,
                system_message: bool = True) -> None:
    """Internal helper — updates status + writes a system message + pings bot."""
    meta = STATUS_META.get(new_status, STATUS_META["seen"])

    t.status = new_status
    if resolution_note:
        t.resolution_note = resolution_note
    if meta.get("terminal"):
        t.closed_at = datetime.utcnow()
    else:
        t.closed_at = None
    t.updated_at = datetime.utcnow()

    if system_message:
        body = f"Status set to **{meta['label']}** by {actor}."
        if resolution_note:
            body += f"\n\n> {resolution_note}"
        db.session.add(TicketMessage(
            ticket_id=t.id, source="system", body=body,
        ))

    db.session.commit()

    if notify_discord and t.discord_channel_id:
        _notify_bot("/discord/ticket/status", {
            "channel_id": t.discord_channel_id,
            "ticket_id": t.id,
            "status": new_status,
            "actor": actor,
            "resolution_note": resolution_note,
        })


# ---------- Live poll (every 5s from view.html) ----------
@tickets_bp.route("/<int:tid>/poll")
@login_required
def poll(tid):
    t = Ticket.query.get_or_404(tid)
    if not _can_view_ticket(t, current_user):
        abort(403)
    since_id = request.args.get("since_id", type=int, default=0)

    q = TicketMessage.query.filter(
        TicketMessage.ticket_id == t.id,
        TicketMessage.id > since_id,
    )
    if not getattr(current_user, 'is_staff', False):
        q = q.filter(TicketMessage.is_internal.is_(False))

    msgs = q.order_by(TicketMessage.id.asc()).all()
    return jsonify({
        "ticket": t.to_dict(),
        "messages": [m.to_dict() for m in msgs],
        "server_time": datetime.utcnow().isoformat(),
    })


# ---------- Assign (staff) ----------
@tickets_bp.route("/<int:tid>/assign", methods=["POST"])
@login_required
def assign(tid):
    if not getattr(current_user, 'is_staff', False):
        abort(403)
    t = Ticket.query.get_or_404(tid)
    assignee_id = request.form.get("assignee_id", type=int)
    t.assigned_to_id = assignee_id or None
    t.updated_at = datetime.utcnow()
    db.session.commit()
    return jsonify({"ok": True,
                    "assigned_to": t.assigned_to.username if t.assigned_to else None})


# ---------- API: list categories for the "New ticket" form's dropdown ----------
@tickets_bp.route("/api/categories/<int:cid>")
@login_required
def api_categories(cid):
    cats = TicketCategory.query.filter_by(company_id=cid, is_active=True).all()
    return jsonify([{"id": c.id, "name": c.name, "description": c.description}
                    for c in cats])
