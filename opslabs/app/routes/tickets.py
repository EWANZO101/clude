"""Ticket routes — create, view, reply, live-poll endpoint, status flow."""
import os
from datetime import datetime, timedelta
import requests
from flask import (Blueprint, render_template, request, redirect, url_for,
                   flash, jsonify, abort, current_app, send_file, make_response)
from flask_login import login_required, current_user
from .. import db
from .. import ticket_uploads as uploads
from ..discord_dm import notify_owner, notify_staff
from ..models import (User, Ticket, TicketMessage, TicketAttachment, TicketCategory, Company,
                      TICKET_STATUS_VALID, TICKET_STATUS_FLOW, STATUS_META,
                      normalise_status, REPLY_VIA_CHOICES)

tickets_bp = Blueprint("tickets", __name__)


# Status-set permissions
USER_ALLOWED_STATUSES  = {"resolved"}                   # clients may only close their own ticket
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
        reply_via = request.form.get("reply_via", "web").strip()
        if reply_via not in REPLY_VIA_CHOICES:
            reply_via = "web"
        wants_json = request.accept_mimetypes.best == "application/json"

        def _reject(msg):
            if wants_json:
                return jsonify({"ok": False, "error": msg}), 400
            flash(msg, "error")
            # Re-render with what the user typed so nothing is lost.
            return render_template("tickets/new.html", companies=companies,
                                   form=request.form)

        if not subject or not body or not company_id:
            return _reject("Please fill in subject, description, and company.")

        company = Company.query.filter_by(id=company_id, is_active=True).first()
        if not company:
            return _reject("Please choose a valid company.")

        active_cats = company.categories.filter_by(is_active=True)
        if category_id:
            if not active_cats.filter_by(id=category_id).first():
                return _reject("Please choose a valid service for that company.")
        elif active_cats.first():
            return _reject("Please choose a service.")

        if reply_via != "web" and not current_user.discord_id:
            return _reject("To continue on Discord, link your Discord account first "
                           "(step 3 under “How should we reply?”).")

        t = Ticket(
            user_id=current_user.id,
            company_id=company_id,
            category_id=category_id,
            subject=subject[:200],
            priority=priority,
            status="seen",     # new tickets land at "seen"
            reply_via=reply_via,
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

        notify_owner(t, kind="opened", body=body)
        notify_staff(t, kind="new", body=body, author=current_user.username)

        flash(f"Ticket #{t.id} created.", "success")
        if wants_json:
            return jsonify({"ok": True, "id": t.id,
                            "url": url_for("tickets.view", tid=t.id, created=1)})
        return redirect(url_for("tickets.view", tid=t.id, created=1))
    return render_template("tickets/new.html", companies=companies, form={})


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
    att_ids = request.form.getlist("attachment_ids", type=int)
    atts = []
    if att_ids:
        atts = TicketAttachment.query.filter(
            TicketAttachment.id.in_(att_ids),
            TicketAttachment.ticket_id == t.id,
            TicketAttachment.user_id == current_user.id,
            TicketAttachment.status == "ready",
            TicketAttachment.message_id.is_(None),
        ).all()
        if len(atts) != len(set(att_ids)):
            return jsonify({"ok": False, "error": "An attachment is missing or still uploading."}), 400
    if not body and not atts:
        return jsonify({"ok": False, "error": "Empty message"}), 400

    msg = TicketMessage(
        ticket_id=t.id, user_id=current_user.id, source="web",
        body=body, is_internal=is_internal,
    )
    db.session.add(msg)
    db.session.flush()
    for a in atts:
        a.message_id = msg.id
    t.updated_at = datetime.utcnow()
    db.session.commit()

    # When a staff member replies for the first time on a "seen" ticket,
    # bump it forward to "in_progress" so the user sees real movement.
    if (getattr(current_user, 'is_staff', False) and not is_internal
            and t.status == "seen"):
        _set_status(t, "in_progress", actor=getattr(current_user, 'username', ''),
                    notify_discord=True, system_message=False)

    if not is_internal and current_user.id == t.user_id:
        notify_staff(t, kind="customer_message", body=_discord_body(body, atts, t),
                     author=current_user.username, via="web")

    if not is_internal:
        notify_owner(t, kind="message", body=_discord_body(body, atts, t),
                     author=getattr(current_user, 'username', ''),
                     author_role=getattr(current_user, 'role', ''),
                     from_owner=current_user.id == t.user_id, via="web")

    if not is_internal and t.discord_channel_id:
        _notify_bot("/discord/ticket/message", {
            "channel_id": t.discord_channel_id,
            "ticket_id": t.id,
            "author": getattr(current_user, 'username', ''),
            "author_role": getattr(current_user, 'role', ''),
            "body": _discord_body(body, atts, t),
        })
    return jsonify({"ok": True, "message": msg.to_dict()})


def _discord_body(body, atts, t):
    """Discord can't open login-protected files, so point at the ticket."""
    if not atts:
        return body
    link = url_for("tickets.view", tid=t.id, _external=True)
    lines = [f"📎 {a.original_name} ({a.kind})" for a in atts]
    return "\n".join(([body] if body else []) + lines + [f"View on the web: {link}"])


# ---------- Status change ----------
@tickets_bp.route("/<int:tid>/status", methods=["POST"])
@login_required
def status(tid):
    t = Ticket.query.get_or_404(tid)
    if not _can_view_ticket(t, current_user):
        abort(403)

    payload = request.get_json(silent=True) or {}   # form posts have no JSON body
    raw = (request.form.get("status") or payload.get("status") or "").strip()
    # normalise_status maps unknown values to "seen", so validate first.
    new_status = normalise_status(raw) if raw in TICKET_STATUS_VALID else None
    if new_status not in TICKET_STATUS_FLOW:
        return jsonify({"error": "Bad status"}), 400

    if getattr(current_user, 'is_staff', False):
        if new_status not in STAFF_ALLOWED_STATUSES:
            return jsonify({"error": "Forbidden"}), 403
    else:
        # Clients can only mark their own ticket as resolved (i.e. close it).
        if new_status not in USER_ALLOWED_STATUSES:
            return jsonify({"error": "Forbidden"}), 403

    resolution_note = (request.form.get("resolution_note")
                       or payload.get("resolution_note") or "").strip()[:1000] or None

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

    notify_owner(t, kind="status", body=resolution_note or "", author=actor)

    if notify_discord and t.discord_channel_id:
        _notify_bot("/discord/ticket/status", {
            "channel_id": t.discord_channel_id,
            "ticket_id": t.id,
            "status": new_status,
            "actor": actor,
            "resolution_note": resolution_note,
        })


# ---------- Reply channel preference (owner) ----------
@tickets_bp.route("/<int:tid>/reply-via", methods=["POST"])
@login_required
def set_reply_via(tid):
    t = Ticket.query.get_or_404(tid)
    if t.user_id != current_user.id:
        abort(403)
    payload = request.get_json(silent=True) or {}
    choice = (request.form.get("reply_via") or payload.get("reply_via") or "").strip()
    if choice not in REPLY_VIA_CHOICES:
        return jsonify({"ok": False, "error": "Choose web, discord or both."}), 400
    if choice != "web" and not current_user.discord_id:
        return jsonify({"ok": False, "error": "Link your Discord account first."}), 400
    t.reply_via = choice
    db.session.commit()
    if choice != "web":
        notify_owner(t, kind="opened", body="You'll now get replies for this ticket here.")
    return jsonify({"ok": True, "reply_via": choice})


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
    if assignee_id:
        assignee = User.query.get(assignee_id)
        if not assignee or not assignee.is_active or not assignee.is_staff:
            return jsonify({"ok": False, "error": "Tickets can only be assigned to active staff."}), 400
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


# ---------- Attachments: chunked upload (images + videos, 1 s – 5 min) ----------
def _upload_ticket(tid):
    t = Ticket.query.get_or_404(tid)
    if not _can_view_ticket(t, current_user):
        abort(403)
    return t


def _own_upload(t, aid):
    a = TicketAttachment.query.filter_by(id=aid, ticket_id=t.id).first()
    if not a or a.user_id != current_user.id:
        abort(404)
    return a


@tickets_bp.route("/<int:tid>/uploads", methods=["POST"])
@login_required
def upload_start(tid):
    t = _upload_ticket(tid)
    if t.is_terminal:
        return jsonify({"ok": False, "error": "Ticket is closed."}), 400
    data = request.get_json(silent=True) or {}
    name = os.path.basename(str(data.get("name") or "")).strip()[:255]
    try:
        kind, ext, mime, stored = uploads.classify(name, data.get("size"))
    except uploads.UploadError as e:
        return jsonify({"ok": False, "error": str(e)}), 400

    # Housekeeping: forget abandoned uploads.
    stale = datetime.utcnow() - timedelta(seconds=uploads.PARTIAL_MAX_AGE)
    TicketAttachment.query.filter(TicketAttachment.status == "uploading",
                                  TicketAttachment.created_at < stale).delete()
    uploads.sweep_partials()

    a = TicketAttachment(ticket_id=t.id, user_id=current_user.id, kind=kind,
                         original_name=name, stored_name=stored, mime=mime,
                         size=int(data["size"]), received=0, status="uploading")
    db.session.add(a)
    db.session.commit()
    open(uploads.partial_path(stored), "wb").close()
    return jsonify({"ok": True, "id": a.id, "chunk_size": uploads.CHUNK_BYTES})


@tickets_bp.route("/<int:tid>/uploads/<int:aid>", methods=["PUT"])
@login_required
def upload_chunk(tid, aid):
    t = _upload_ticket(tid)
    a = _own_upload(t, aid)
    if a.status != "uploading":
        return jsonify({"ok": False, "error": "Upload already finished."}), 400
    offset = request.args.get("offset", type=int)
    length = request.content_length or 0
    if offset != a.received:
        # Tell the client where to resume from.
        return jsonify({"ok": False, "error": "Wrong offset.", "received": a.received}), 409
    if length <= 0 or length > uploads.CHUNK_BYTES or a.received + length > a.size:
        return jsonify({"ok": False, "error": "Bad chunk size."}), 400

    path = uploads.partial_path(a.stored_name)
    written = 0
    with open(path, "r+b") as f:
        f.seek(offset)
        while True:
            buf = request.stream.read(1024 * 1024)
            if not buf:
                break
            written += len(buf)
            if written > length:
                break
            f.write(buf)
        f.truncate(offset + min(written, length))
    if written != length:
        return jsonify({"ok": False, "error": "Chunk was cut short.", "received": a.received}), 400
    a.received = offset + written
    db.session.commit()
    return jsonify({"ok": True, "received": a.received})


@tickets_bp.route("/<int:tid>/uploads/<int:aid>/complete", methods=["POST"])
@login_required
def upload_complete(tid, aid):
    t = _upload_ticket(tid)
    a = _own_upload(t, aid)
    if a.status == "ready":
        return jsonify({"ok": True, "attachment": a.to_dict()})
    if a.received != a.size:
        return jsonify({"ok": False, "error": "Upload is incomplete.", "received": a.received}), 400

    src = uploads.partial_path(a.stored_name)
    try:
        a.duration = uploads.verify(src, a.kind, a.stored_name.rsplit(".", 1)[-1])
    except uploads.UploadError as e:
        try:
            os.remove(src)
        except OSError:
            pass
        db.session.delete(a)
        db.session.commit()
        return jsonify({"ok": False, "error": str(e)}), 400

    dest = uploads.final_path(t.id, a.stored_name)
    os.replace(src, dest)
    os.chmod(dest, 0o644)
    a.status = "ready"
    db.session.commit()
    return jsonify({"ok": True, "attachment": a.to_dict()})


@tickets_bp.route("/<int:tid>/uploads/<int:aid>", methods=["DELETE"])
@login_required
def upload_cancel(tid, aid):
    t = _upload_ticket(tid)
    a = _own_upload(t, aid)
    if a.message_id:
        return jsonify({"ok": False, "error": "Already sent."}), 400
    for p in (uploads.partial_path(a.stored_name), uploads.final_path(t.id, a.stored_name)):
        try:
            os.remove(p)
        except OSError:
            pass
    db.session.delete(a)
    db.session.commit()
    return jsonify({"ok": True})


@tickets_bp.route("/attachments/<int:aid>")
@login_required
def attachment(aid):
    a = TicketAttachment.query.get_or_404(aid)
    t = Ticket.query.get(a.ticket_id)
    if a.status != "ready" or not t or not _can_view_ticket(t, current_user):
        abort(404)
    is_staff = getattr(current_user, "is_staff", False)
    if a.message_id is None and a.user_id != current_user.id and not is_staff:
        abort(404)
    if a.message and a.message.is_internal and not is_staff:
        abort(404)

    from urllib.parse import quote
    disposition = f"inline; filename*=UTF-8''{quote(a.original_name)}"
    if current_app.config.get("UPLOADS_X_ACCEL", True) and request.headers.get("X-Forwarded-For"):
        # nginx streams the file (with range support) instead of tying up a worker.
        resp = make_response("")
        resp.headers["X-Accel-Redirect"] = "/_ticket_uploads/" + uploads.final_relpath(t.id, a.stored_name)
    else:
        resp = send_file(uploads.final_path(t.id, a.stored_name), mimetype=a.mime,
                         conditional=True, max_age=0)
    resp.headers["Content-Type"] = a.mime
    resp.headers["Content-Disposition"] = disposition
    resp.headers["X-Content-Type-Options"] = "nosniff"
    resp.headers["Cache-Control"] = "private, max-age=3600"
    return resp
