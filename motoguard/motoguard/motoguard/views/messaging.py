"""Internal messaging. Server-readable (moderation-capable), rate-limited,
block + report supported. No personal contact details are ever exposed."""
import os
import uuid
import time
from collections import defaultdict
from flask import (Blueprint, render_template, redirect, url_for, request,
                   flash, abort, current_app, jsonify)
from flask_login import login_required, current_user
from sqlalchemy import or_, and_
from ..extensions import db
from ..models import Conversation, Message, Block, User, Vehicle, Report
from ..services import notify

bp = Blueprint("messaging", __name__)

# simple in-process rate limiter: {user_id: [timestamps]}
_rate = defaultdict(list)


def _rate_ok(uid):
    now = time.time()
    window = [t for t in _rate[uid] if now - t < 60]
    _rate[uid] = window
    if len(window) >= current_app.config["MESSAGE_RATE_PER_MIN"]:
        return False
    window.append(now)
    return True


def _is_blocked(a, b):
    return db.session.query(Block.id).filter(
        or_(and_(Block.blocker_id == a, Block.blocked_id == b),
            and_(Block.blocker_id == b, Block.blocked_id == a))).first() is not None


def _get_or_create_convo(uid, other_id, vehicle_id=None):
    convo = Conversation.query.filter(
        or_(and_(Conversation.user_a_id == uid, Conversation.user_b_id == other_id),
            and_(Conversation.user_a_id == other_id, Conversation.user_b_id == uid))
    ).first()
    if not convo:
        convo = Conversation(user_a_id=uid, user_b_id=other_id, vehicle_id=vehicle_id)
        db.session.add(convo)
        db.session.commit()
    return convo


@bp.route("/")
@login_required
def inbox():
    convos = Conversation.query.filter(
        or_(Conversation.user_a_id == current_user.id,
            Conversation.user_b_id == current_user.id)
    ).order_by(Conversation.last_at.desc()).all()
    return render_template("messaging/inbox.html", convos=convos)


@bp.route("/start/<int:user_id>")
@login_required
def start(user_id):
    if user_id == current_user.id:
        abort(400)
    other = db.session.get(User, user_id) or abort(404)
    if _is_blocked(current_user.id, other.id):
        flash("You cannot message this user.", "error")
        return redirect(url_for("messaging.inbox"))
    vehicle_id = request.args.get("vehicle_id", type=int)
    convo = _get_or_create_convo(current_user.id, other.id, vehicle_id)
    return redirect(url_for("messaging.thread", convo_id=convo.id))


@bp.route("/<int:convo_id>", methods=["GET", "POST"])
@login_required
def thread(convo_id):
    convo = db.session.get(Conversation, convo_id) or abort(404)
    if current_user.id not in (convo.user_a_id, convo.user_b_id):
        abort(403)
    other = convo.other(current_user.id)

    if request.method == "POST":
        if _is_blocked(current_user.id, other.id):
            flash("Messaging blocked between you and this user.", "error")
            return redirect(url_for("messaging.thread", convo_id=convo.id))
        if not _rate_ok(current_user.id):
            flash("Slow down — message rate limit reached.", "warning")
            return redirect(url_for("messaging.thread", convo_id=convo.id))
        body = (request.form.get("body") or "").strip()
        attachment = None
        f = request.files.get("attachment")
        if f and f.filename:
            ext = f.filename.rsplit(".", 1)[-1].lower()
            if ext in current_app.config["ALLOWED_IMAGE_EXT"]:
                attachment = f"{uuid.uuid4().hex}.{ext}"
                f.save(os.path.join(current_app.config["UPLOAD_FOLDER"], attachment))
        if body or attachment:
            from datetime import datetime
            m = Message(conversation_id=convo.id, sender_id=current_user.id,
                        body=body, attachment=attachment)
            convo.last_at = datetime.utcnow()
            db.session.add(m)
            db.session.commit()
            notify(other.id, f"New message from {current_user.username}",
                   url_for("messaging.thread", convo_id=convo.id))
        return redirect(url_for("messaging.thread", convo_id=convo.id))

    # mark inbound as read
    Message.query.filter(Message.conversation_id == convo.id,
                         Message.sender_id != current_user.id,
                         Message.is_read.is_(False)).update({"is_read": True})
    db.session.commit()
    msgs = convo.messages.order_by(Message.created_at.asc()).all()
    return render_template("messaging/thread.html", convo=convo, other=other, msgs=msgs)


@bp.route("/block/<int:user_id>", methods=["POST"])
@login_required
def block(user_id):
    if user_id != current_user.id and not _is_blocked(current_user.id, user_id):
        db.session.add(Block(blocker_id=current_user.id, blocked_id=user_id))
        db.session.commit()
    flash("User blocked.", "success")
    return redirect(url_for("messaging.inbox"))


@bp.route("/report/<int:convo_id>", methods=["POST"])
@login_required
def report(convo_id):
    convo = db.session.get(Conversation, convo_id) or abort(404)
    if current_user.id not in (convo.user_a_id, convo.user_b_id):
        abort(403)
    db.session.add(Report(reporter_id=current_user.id, target_type="conversation",
                          target_id=convo.id, reason=request.form.get("reason", "")))
    db.session.commit()
    flash("Conversation reported to moderators.", "success")
    return redirect(url_for("messaging.thread", convo_id=convo.id))
