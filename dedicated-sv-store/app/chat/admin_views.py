from flask import render_template, redirect, url_for, request
from flask_login import current_user

from app.extensions import db
from app.models.chat import Conversation, Message, ConversationContext
from app.models.equipment import CustomerEquipmentRequest
from app.chat.forms import MessageForm
from app.chat.service import get_or_create_conversation
from app.utils.helpers import paginate_query
from app.utils.permissions import permission_required


def register_admin_chat_views(admin_bp):
    @admin_bp.route("/chats")
    @permission_required("chat.view")
    def chats():
        page = request.args.get("page", 1, type=int)
        query = Conversation.query.order_by(Conversation.updated_at.desc())
        pagination = paginate_query(query, page, 25)
        return render_template("admin/chat/list.html", pagination=pagination)

    @admin_bp.route("/chats/<int:conversation_id>", methods=["GET", "POST"])
    @permission_required("chat.view")
    def conversation_detail(conversation_id):
        conversation = db.session.get(Conversation, conversation_id)
        if conversation is None:
            from flask import abort

            abort(404)

        form = MessageForm()
        if form.validate_on_submit():
            db.session.add(
                Message(
                    conversation_id=conversation.id, sender_id=current_user.id,
                    body=form.body.data, is_internal_note=form.is_internal_note.data,
                )
            )
            db.session.commit()
            return redirect(url_for("admin.conversation_detail", conversation_id=conversation.id))

        return render_template("admin/chat/detail.html", conversation=conversation, form=form)

    @admin_bp.route("/requests/<int:request_id>/chat")
    @permission_required("chat.view")
    def request_chat(request_id):
        req = db.session.get(CustomerEquipmentRequest, request_id)
        if req is None:
            from flask import abort

            abort(404)
        conversation = get_or_create_conversation(
            ConversationContext.EQUIPMENT_REQUEST, req.id, f"Request {req.request_number}", [req.user_id],
        )
        db.session.commit()
        return redirect(url_for("admin.conversation_detail", conversation_id=conversation.id))
