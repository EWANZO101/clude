from app.extensions import db
from app.models.user import AccountType
from app.models.chat import Conversation, Message
from app.models.support import SupportTicket, TicketStatus
from app.models.notification import Notification
from tests.conftest import login


def test_customer_can_open_and_message_request_chat(client, make_user):
    from app.models.equipment import CustomerEquipmentRequest

    buyer = make_user(email="chatter@example.com", password="Password123")
    req = CustomerEquipmentRequest(user_id=buyer.id)
    db.session.add(req)
    db.session.commit()

    login(client, "chatter@example.com", "Password123")
    resp = client.get(f"/customer/requests/{req.id}/chat", follow_redirects=True)
    assert resp.status_code == 200
    conversation = Conversation.query.first()
    assert conversation is not None

    resp = client.post(f"/customer/messages/{conversation.id}", data={"body": "Hello there"})
    assert resp.status_code == 302
    msg = Message.query.filter_by(conversation_id=conversation.id).first()
    assert msg.body == "Hello there"
    assert msg.is_internal_note is False


def test_internal_note_hidden_from_customer(client, make_user):
    from app.models.equipment import CustomerEquipmentRequest

    buyer = make_user(email="chatter2@example.com", password="Password123")
    req = CustomerEquipmentRequest(user_id=buyer.id)
    db.session.add(req)
    db.session.commit()
    login(client, "chatter2@example.com", "Password123")
    client.get(f"/customer/requests/{req.id}/chat")
    conversation = Conversation.query.first()
    client.get("/auth/logout")

    make_user(email="chatadmin@example.com", password="Password123", account_type=AccountType.ADMIN, roles=["Super Admin"])
    login(client, "chatadmin@example.com", "Password123")
    client.post(f"/admin/chats/{conversation.id}", data={"body": "internal-only comment", "is_internal_note": "y"})
    client.post(f"/admin/chats/{conversation.id}", data={"body": "visible reply"})
    client.get("/auth/logout")

    login(client, "chatter2@example.com", "Password123")
    resp = client.get(f"/customer/messages/{conversation.id}")
    assert b"visible reply" in resp.data
    assert b"internal-only comment" not in resp.data


def test_customer_can_create_and_view_ticket(client, make_user):
    make_user(email="ticketer@example.com", password="Password123")
    login(client, "ticketer@example.com", "Password123")

    resp = client.post(
        "/customer/support/new",
        data={"subject": "Help", "category": "General", "priority": "normal", "description": "I need help"},
    )
    assert resp.status_code == 302
    ticket = SupportTicket.query.first()
    assert ticket is not None
    assert ticket.status == TicketStatus.OPEN

    resp = client.get(f"/customer/support/{ticket.id}")
    assert resp.status_code == 200


def test_admin_can_update_ticket_status_and_assign(client, make_user):
    customer = make_user(email="ticketer2@example.com", password="Password123")
    ticket = SupportTicket(user_id=customer.id, subject="Issue", category="General", description="desc")
    db.session.add(ticket)
    db.session.commit()

    admin = make_user(email="ticketadmin@example.com", password="Password123", account_type=AccountType.ADMIN, roles=["Super Admin"])
    login(client, "ticketadmin@example.com", "Password123")

    resp = client.post(f"/admin/tickets/{ticket.id}", data={"action": "set_status", "status": "resolved"})
    assert resp.status_code == 302
    db.session.refresh(ticket)
    assert ticket.status == TicketStatus.RESOLVED

    resp = client.post(f"/admin/tickets/{ticket.id}", data={"action": "assign_staff", "staff_id": admin.id})
    assert resp.status_code == 302
    db.session.refresh(ticket)
    assert ticket.assigned_staff_id == admin.id


def test_other_customer_cannot_view_ticket(client, make_user):
    owner = make_user(email="ticketowner@example.com", password="Password123")
    ticket = SupportTicket(user_id=owner.id, subject="Private", category="General", description="desc")
    db.session.add(ticket)
    db.session.commit()

    make_user(email="ticketintruder@example.com", password="Password123")
    login(client, "ticketintruder@example.com", "Password123")
    resp = client.get(f"/customer/support/{ticket.id}")
    assert resp.status_code == 404


def test_payment_creates_notification(client, make_user):
    from app.models.seller import SellerProfile, SellerStatus
    from app.models.server import Server, ServerStatus, InventoryStatus
    from app.payments.service import charge_invoice
    from app.models.finance import Invoice

    seller_user = make_user(email="notifyseller@example.com", password="Password123", account_type=AccountType.SELLER)
    seller = SellerProfile(user_id=seller_user.id, business_name="X", slug="x-notify", status=SellerStatus.ACTIVE)
    db.session.add(seller)
    db.session.commit()
    server = Server(
        seller_id=seller.id, title="N Server", slug="n-server", cpu_summary="c", ram_summary="r",
        storage_summary="s", network_summary="n", monthly_price=10,
        status=ServerStatus.PUBLISHED, inventory_status=InventoryStatus.AVAILABLE,
    )
    db.session.add(server)
    db.session.commit()

    buyer = make_user(email="notifybuyer@example.com", password="Password123")
    login(client, "notifybuyer@example.com", "Password123")
    client.post("/cart/add", data={"item_type": "server", "item_id": server.id})
    client.post("/checkout")

    invoice = Invoice.query.filter_by(user_id=buyer.id).first()
    charge_invoice(invoice, buyer)

    notification = Notification.query.filter_by(user_id=buyer.id, type="invoice.paid").first()
    assert notification is not None
