from flask import render_template, redirect, url_for, abort
from flask_login import current_user

from app.extensions import db
from app.models.chat import Conversation, ConversationParticipant, Message
from app.models.equipment import CustomerEquipmentRequest
from app.chat.forms import CustomerMessageForm
from app.chat.service import get_or_create_conversation


def register_customer_chat_views(customer_bp):
    @customer_bp.route("/messages")
    def messages():
        conversations = (
            Conversation.query.join(ConversationParticipant)
            .filter(ConversationParticipant.user_id == current_user.id)
            .order_by(Conversation.updated_at.desc())
            .all()
        )
        return render_template("customer/messages/list.html", conversations=conversations)

    @customer_bp.route("/messages/<int:conversation_id>", methods=["GET", "POST"])
    def conversation_detail(conversation_id):
        participant = ConversationParticipant.query.filter_by(
            conversation_id=conversation_id, user_id=current_user.id
        ).first()
        if participant is None:
            abort(404)
        conversation = participant.conversation

        form = CustomerMessageForm()
        if form.validate_on_submit():
            db.session.add(Message(conversation_id=conversation.id, sender_id=current_user.id, body=form.body.data))
            db.session.commit()
            return redirect(url_for("customer.conversation_detail", conversation_id=conversation.id))

        return render_template(
            "customer/messages/detail.html", conversation=conversation, form=form,
            visible_messages=conversation.visible_messages(False),
        )

    @customer_bp.route("/requests/<int:request_id>/chat")
    def request_chat(request_id):
        req = CustomerEquipmentRequest.query.filter_by(id=request_id, user_id=current_user.id).first()
        if req is None:
            abort(404)
        from app.models.chat import ConversationContext

        conversation = get_or_create_conversation(
            ConversationContext.EQUIPMENT_REQUEST, req.id, f"Request {req.request_number}", [req.user_id],
        )
        db.session.commit()
        return redirect(url_for("customer.conversation_detail", conversation_id=conversation.id))
