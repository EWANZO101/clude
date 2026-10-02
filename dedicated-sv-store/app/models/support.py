import enum
import random
import string

from app.extensions import db
from app.models.base import TimestampMixin, utcnow


class TicketPriority(str, enum.Enum):
    LOW = "low"
    NORMAL = "normal"
    HIGH = "high"
    URGENT = "urgent"


class TicketStatus(str, enum.Enum):
    OPEN = "open"
    IN_PROGRESS = "in_progress"
    WAITING_FOR_CUSTOMER = "waiting_for_customer"
    RESOLVED = "resolved"
    CLOSED = "closed"


def _generate_ticket_number():
    return "TCK-" + "".join(random.choices(string.digits, k=8))


class SupportTicket(db.Model, TimestampMixin):
    __tablename__ = "support_tickets"

    id = db.Column(db.Integer, primary_key=True)
    ticket_number = db.Column(db.String(20), unique=True, default=_generate_ticket_number, nullable=False)
    user_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False)

    subject = db.Column(db.String(255), nullable=False)
    category = db.Column(db.String(100))
    priority = db.Column(db.Enum(TicketPriority, name="ticket_priority"), default=TicketPriority.NORMAL, nullable=False)
    description = db.Column(db.Text, nullable=False)

    related_order_id = db.Column(db.Integer, db.ForeignKey("orders.id"))
    related_server_id = db.Column(db.Integer, db.ForeignKey("servers.id"))
    related_equipment_request_id = db.Column(db.Integer, db.ForeignKey("customer_equipment_requests.id"))

    status = db.Column(db.Enum(TicketStatus, name="ticket_status"), default=TicketStatus.OPEN, nullable=False)
    assigned_staff_id = db.Column(db.Integer, db.ForeignKey("users.id"))

    user = db.relationship("User", foreign_keys=[user_id])
    assigned_staff = db.relationship("User", foreign_keys=[assigned_staff_id])
    related_order = db.relationship("Order")
    related_server = db.relationship("Server")
    related_equipment_request = db.relationship("CustomerEquipmentRequest")
    messages = db.relationship(
        "TicketMessage", back_populates="ticket", cascade="all, delete-orphan", order_by="TicketMessage.created_at"
    )

    def __repr__(self):
        return f"<SupportTicket {self.ticket_number}>"

    def visible_messages(self, viewer_is_staff):
        if viewer_is_staff:
            return self.messages
        return [m for m in self.messages if not m.is_internal_note]


class TicketMessage(db.Model):
    __tablename__ = "ticket_messages"

    id = db.Column(db.Integer, primary_key=True)
    ticket_id = db.Column(db.Integer, db.ForeignKey("support_tickets.id"), nullable=False)
    sender_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False)
    body = db.Column(db.Text, nullable=False)
    is_internal_note = db.Column(db.Boolean, default=False, nullable=False)
    created_at = db.Column(db.DateTime(timezone=True), default=utcnow, nullable=False)

    ticket = db.relationship("SupportTicket", back_populates="messages")
    sender = db.relationship("User")
