from app.extensions import db
from app.models.chat import Conversation, ConversationParticipant, ConversationContext


def get_or_create_conversation(context_type, context_id, subject, participant_user_ids):
    conversation = Conversation.query.filter_by(context_type=context_type, context_id=context_id).first()
    if conversation is None:
        conversation = Conversation(subject=subject, context_type=context_type, context_id=context_id)
        db.session.add(conversation)
        db.session.flush()

    existing_ids = {p.user_id for p in conversation.participants}
    for user_id in participant_user_ids:
        if user_id not in existing_ids:
            db.session.add(ConversationParticipant(conversation_id=conversation.id, user_id=user_id))

    return conversation
