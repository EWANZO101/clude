import enum

from app.extensions import db
from app.models.base import TimestampMixin, utcnow


class ConversationContext(str, enum.Enum):
    ORDER = "order"
    EQUIPMENT_REQUEST = "equipment_request"
    SHIPMENT = "shipment"
    GENERAL = "general"


class Conversation(db.Model, TimestampMixin):
    __tablename__ = "conversations"

    id = db.Column(db.Integer, primary_key=True)
    subject = db.Column(db.String(255))
    context_type = db.Column(db.Enum(ConversationContext, name="conversation_context"), default=ConversationContext.GENERAL)
    context_id = db.Column(db.Integer)
    is_active = db.Column(db.Boolean, default=True, nullable=False)

    participants = db.relationship(
        "ConversationParticipant", back_populates="conversation", cascade="all, delete-orphan"
    )
    messages = db.relationship(
        "Message", back_populates="conversation", cascade="all, delete-orphan", order_by="Message.created_at"
    )

    def __repr__(self):
        return f"<Conversation {self.id} {self.subject}>"

    def visible_messages(self, viewer_is_staff):
        if viewer_is_staff:
            return self.messages
        return [m for m in self.messages if not m.is_internal_note]

    def last_message(self):
        return self.messages[-1] if self.messages else None


class ConversationParticipant(db.Model):
    __tablename__ = "conversation_participants"

    id = db.Column(db.Integer, primary_key=True)
    conversation_id = db.Column(db.Integer, db.ForeignKey("conversations.id"), nullable=False)
    user_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False)
    last_read_at = db.Column(db.DateTime(timezone=True))

    conversation = db.relationship("Conversation", back_populates="participants")
    user = db.relationship("User")

    __table_args__ = (db.UniqueConstraint("conversation_id", "user_id", name="uq_conversation_participant"),)


class Message(db.Model):
    __tablename__ = "messages"

    id = db.Column(db.Integer, primary_key=True)
    conversation_id = db.Column(db.Integer, db.ForeignKey("conversations.id"), nullable=False)
    sender_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False)
    body = db.Column(db.Text, nullable=False)
    is_internal_note = db.Column(db.Boolean, default=False, nullable=False)
    created_at = db.Column(db.DateTime(timezone=True), default=utcnow, nullable=False)

    conversation = db.relationship("Conversation", back_populates="messages")
    sender = db.relationship("User")
    attachments = db.relationship("MessageAttachment", back_populates="message", cascade="all, delete-orphan")


class MessageAttachment(db.Model):
    __tablename__ = "message_attachments"

    id = db.Column(db.Integer, primary_key=True)
    message_id = db.Column(db.Integer, db.ForeignKey("messages.id"), nullable=False)
    file_path = db.Column(db.String(500), nullable=False)
    original_filename = db.Column(db.String(255))

    message = db.relationship("Message", back_populates="attachments")
