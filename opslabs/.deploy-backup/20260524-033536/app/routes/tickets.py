"""Ticket routes — create, view, reply, live-poll endpoint."""
from datetime import datetime
import requests
from flask import (Blueprint, render_template, request, redirect, url_for,
                   flash, jsonify, abort, current_app)
from flask_login import login_required, current_user
from .. import db
from ..models import Ticket, TicketMessage, TicketCategory, Company

tickets_bp = Blueprint("tickets", __name__)


def _can_view_ticket(ticket, user):
    if user.is_staff:
        return True
    return ticket.user_id == user.id


def _notify_bot(endpoint, payload):
    """Fire-and-mostly-forget call to the Discord bot bridge."""
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
    if current_user.is_staff:
        q = Ticket.query.order_by(Ticket.updated_at.desc())
        scope = "staff"
    else:
        q = Ticket.query.filter_by(user_id=current_user.id).order_by(Ticket.updated_at.desc())
        scope = "own"

    status = request.args.get("status")
    if status in ("open", "pending", "closed"):
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
        category_id = request.form.get("category_id", type=int)
        priority = request.form.get("priority", "normal")

        if not (subject and body and company_id):
            flash("Subject, message, and company are required.", "error")
            return render_template("tickets/new.html", companies=companies)

        ticket = Ticket(
            user_id=current_user.id, company_id=company_id,
            category_id=category_id, subject=subject,
            priority=priority, status="open",
        )
        db.session.add(ticket)
        db.session.flush()

        db.session.add(TicketMessage(
            ticket_id=ticket.id, user_id=current_user.id,
            source="web", body=body,
        ))
        db.session.commit()

        # Ask bot to create a Discord channel
        result = _notify_bot("/discord/ticket/create", {
            "ticket_id": ticket.id,
            "subject": subject,
            "category": ticket.category.name if ticket.category else "General",
            "company": ticket.company.name if ticket.company else "Ops Labs",
            "owner": current_user.username,
            "owner_discord_id": current_user.discord_id,
            "priority": priority,
            "initial_message": body,
        })
        if result and result.get("channel_id"):
            ticket.discord_channel_id = result["channel_id"]
            db.session.commit()

        flash(f"Ticket #{ticket.id} created.", "success")
        return redirect(url_for("tickets.view", tid=ticket.id))
    return render_template("tickets/new.html", companies=companies)


@tickets_bp.route("/api/categories/<int:company_id>")
@login_required
def api_categories(company_id):
    cats = TicketCategory.query.filter_by(company_id=company_id, is_active=True).all()
    return jsonify([{"id": c.id, "name": c.name, "description": c.description}
                    for c in cats])


# ---------- View ----------
@tickets_bp.route("/<int:tid>")
@login_required
def view(tid):
    t = Ticket.query.get_or_404(tid)
    if not _can_view_ticket(t, current_user):
        abort(403)
    return render_template("tickets/view.html", ticket=t)


# ---------- Reply ----------
@tickets_bp.route("/<int:tid>/reply", methods=["POST"])
@login_required
def reply(tid):
    t = Ticket.query.get_or_404(tid)
    if not _can_view_ticket(t, current_user):
        abort(403)
    if t.status == "closed":
        return jsonify({"error": "Ticket is closed."}), 400

    body = (request.form.get("body") or (request.json or {}).get("body", "")).strip()
    is_internal = bool(request.form.get("is_internal") or
                       (request.json or {}).get("is_internal"))
    if not body:
        return jsonify({"error": "Message body required."}), 400
    if is_internal and not current_user.is_staff:
        is_internal = False

    m = TicketMessage(
        ticket_id=t.id, user_id=current_user.id,
        source="web", body=body, is_internal=is_internal,
    )
    db.session.add(m)
    t.updated_at = datetime.utcnow()
    if t.status == "pending" and not current_user.is_staff:
        t.status = "open"
    db.session.commit()

    if not is_internal and t.discord_channel_id:
        _notify_bot("/discord/ticket/message", {
            "channel_id": t.discord_channel_id,
            "ticket_id": t.id,
            "author": current_user.username,
            "author_role": current_user.role,
            "body": body,
        })
    return jsonify({"ok": True, "message": m.to_dict()})


# ---------- Status change (close/reopen) ----------
@tickets_bp.route("/<int:tid>/status", methods=["POST"])
@login_required
def status(tid):
    t = Ticket.query.get_or_404(tid)
    if not _can_view_ticket(t, current_user):
        abort(403)
    new_status = request.form.get("status") or (request.json or {}).get("status")
    if new_status not in ("open", "pending", "closed"):
        return jsonify({"error": "Bad status"}), 400

    # Only staff can set 'pending', users can only close their own
    if new_status == "pending" and not current_user.is_staff:
        return jsonify({"error": "Forbidden"}), 403

    t.status = new_status
    t.closed_at = datetime.utcnow() if new_status == "closed" else None
    t.updated_at = datetime.utcnow()

    db.session.add(TicketMessage(
        ticket_id=t.id, user_id=current_user.id,
        source="system",
        body=f"Ticket status set to **{new_status}** by {current_user.username}.",
    ))
    db.session.commit()

    if t.discord_channel_id:
        _notify_bot("/discord/ticket/status", {
            "channel_id": t.discord_channel_id,
            "ticket_id": t.id,
            "status": new_status,
            "actor": current_user.username,
        })
    return jsonify({"ok": True, "status": new_status})


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
    if not current_user.is_staff:
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
    if not current_user.is_staff:
        abort(403)
    t = Ticket.query.get_or_404(tid)
    assignee_id = request.form.get("assignee_id", type=int)
    t.assigned_to_id = assignee_id or None
    t.updated_at = datetime.utcnow()
    db.session.commit()
    return jsonify({"ok": True,
                    "assigned_to": t.assigned_to.username if t.assigned_to else None})
