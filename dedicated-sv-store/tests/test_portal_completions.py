from app.extensions import db
from app.models.user import AccountType
from app.models.seller import SellerProfile, SellerStatus
from app.models.server import Server, ServerStatus, InventoryStatus
from app.models.order import Order, OrderItem, OrderItemType, OrderPaymentStatus
from app.models.equipment import EquipmentType, CustomerEquipmentRequest, CustomerEquipmentItem
from app.models.chat import Conversation, Message
from tests.conftest import login


def _make_seller_and_paid_order(make_user, buyer_email="portalbuyer@example.com"):
    seller_user = make_user(email="portalseller@example.com", password="Password123", account_type=AccountType.SELLER)
    seller = SellerProfile(user_id=seller_user.id, business_name="Portal Co", slug="portal-co", status=SellerStatus.ACTIVE)
    db.session.add(seller)
    db.session.commit()

    buyer = make_user(email=buyer_email, password="Password123")
    server = Server(
        seller_id=seller.id, title="Portal Server", slug="portal-server", cpu_summary="c", ram_summary="r",
        storage_summary="s", network_summary="n", monthly_price=100,
        status=ServerStatus.PUBLISHED, inventory_status=InventoryStatus.SOLD,
    )
    db.session.add(server)
    db.session.flush()
    order = Order(user_id=buyer.id, seller_id=seller.id, total=100, payment_status=OrderPaymentStatus.PAID)
    db.session.add(order)
    db.session.flush()
    db.session.add(
        OrderItem(
            order_id=order.id, item_type=OrderItemType.SERVER, server_id=server.id,
            title_snapshot="Portal Server", unit_monthly_price=100, line_total=100,
        )
    )
    db.session.commit()
    return seller_user, seller, buyer, server, order


def test_customer_settings_updates_profile_and_user(client, make_user):
    make_user(email="settingsuser@example.com", password="Password123")
    login(client, "settingsuser@example.com", "Password123")

    resp = client.post(
        "/customer/settings",
        data={
            "first_name": "New", "last_name": "Name", "company_name": "Acme",
            "billing_city": "London", "billing_country": "GB",
        },
    )
    assert resp.status_code == 302

    from app.models.user import User

    user = User.query.filter_by(email="settingsuser@example.com").first()
    assert user.first_name == "New"
    assert user.customer_profile.company_name == "Acme"


def test_customer_my_servers_lists_purchased_server(client, make_user):
    _, _, buyer, server, order = _make_seller_and_paid_order(make_user)
    login(client, "portalbuyer@example.com", "Password123")

    resp = client.get("/customer/servers")
    assert resp.status_code == 200
    assert b"Portal Server" in resp.data


def test_customer_my_equipment_lists_items_across_requests(client, make_user):
    buyer = make_user(email="equipuser@example.com", password="Password123")
    et = EquipmentType(name="Server", slug="server-portal", is_networking=False)
    db.session.add(et)
    db.session.commit()
    req = CustomerEquipmentRequest(user_id=buyer.id)
    db.session.add(req)
    db.session.flush()
    db.session.add(CustomerEquipmentItem(request_id=req.id, equipment_type_id=et.id, manufacturer="Dell", model="R760", quantity=1))
    db.session.commit()

    login(client, "equipuser@example.com", "Password123")
    resp = client.get("/customer/equipment")
    assert resp.status_code == 200
    assert b"Dell" in resp.data


def test_seller_settings_updates_profile(client, make_user):
    seller_user, seller, _, _, _ = _make_seller_and_paid_order(make_user)
    login(client, "portalseller@example.com", "Password123")

    resp = client.post(
        "/seller/settings",
        data={"business_name": "Renamed Co", "support_email": "support@renamed.example"},
    )
    assert resp.status_code == 302
    db.session.refresh(seller)
    assert seller.business_name == "Renamed Co"


def test_seller_customers_lists_buyers(client, make_user):
    _, _, buyer, _, _ = _make_seller_and_paid_order(make_user)
    login(client, "portalseller@example.com", "Password123")

    resp = client.get("/seller/customers")
    assert resp.status_code == 200
    assert b"portalbuyer@example.com" in resp.data


def test_seller_sales_lists_orders(client, make_user):
    _, _, _, _, order = _make_seller_and_paid_order(make_user)
    login(client, "portalseller@example.com", "Password123")

    resp = client.get("/seller/sales")
    assert resp.status_code == 200
    assert order.order_number.encode() in resp.data


def test_seller_revenue_reflects_paid_orders(client, make_user):
    _make_seller_and_paid_order(make_user)
    login(client, "portalseller@example.com", "Password123")

    resp = client.get("/seller/revenue")
    assert resp.status_code == 200
    assert b"100" in resp.data


def test_order_chat_customer_and_seller_can_exchange_messages(client, make_user):
    _, _, buyer, _, order = _make_seller_and_paid_order(make_user)
    login(client, "portalbuyer@example.com", "Password123")

    resp = client.get(f"/customer/orders/{order.id}/chat", follow_redirects=True)
    assert resp.status_code == 200
    conversation = Conversation.query.first()
    assert conversation is not None

    client.post(f"/customer/messages/{conversation.id}", data={"body": "Question about my order"})
    client.get("/auth/logout")

    login(client, "portalseller@example.com", "Password123")
    resp = client.get("/seller/messages")
    assert order.order_number.encode() in resp.data

    resp = client.get(f"/seller/messages/{conversation.id}")
    assert b"Question about my order" in resp.data

    client.post(f"/seller/messages/{conversation.id}", data={"body": "Sure, happy to help"})
    reply = Message.query.filter_by(body="Sure, happy to help").first()
    assert reply is not None
    assert reply.is_internal_note is False


def test_seller_cannot_view_other_sellers_order_conversation(client, make_user):
    _, _, buyer, _, order = _make_seller_and_paid_order(make_user)
    login(client, "portalbuyer@example.com", "Password123")
    client.get(f"/customer/orders/{order.id}/chat")
    conversation = Conversation.query.first()
    client.get("/auth/logout")

    other_seller_user = make_user(email="otherseller2@example.com", password="Password123", account_type=AccountType.SELLER)
    db.session.add(SellerProfile(user_id=other_seller_user.id, business_name="Other", slug="other-2", status=SellerStatus.ACTIVE))
    db.session.commit()
    login(client, "otherseller2@example.com", "Password123")

    resp = client.get(f"/seller/messages/{conversation.id}")
    assert resp.status_code == 404
