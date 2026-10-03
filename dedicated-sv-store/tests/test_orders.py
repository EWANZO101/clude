from app.extensions import db
from app.models.user import AccountType
from app.models.seller import SellerProfile, SellerStatus
from app.models.server import Server, ServerStatus, InventoryStatus
from app.models.order import CartItem, Order, OrderItemType, OrderStatus
from tests.conftest import login


def _make_seller_and_server(make_user, **overrides):
    user = make_user(email="seller@example.com", password="Password123", account_type=AccountType.SELLER)
    seller = SellerProfile(user_id=user.id, business_name="Acme", slug="acme", status=SellerStatus.ACTIVE)
    db.session.add(seller)
    db.session.commit()

    defaults = dict(
        seller_id=seller.id,
        title="Test Server",
        slug="test-server",
        cpu_summary="CPU",
        ram_summary="RAM",
        storage_summary="Storage",
        network_summary="Network",
        monthly_price=100,
        status=ServerStatus.PUBLISHED,
        inventory_status=InventoryStatus.AVAILABLE,
    )
    defaults.update(overrides)
    server = Server(**defaults)
    db.session.add(server)
    db.session.commit()
    return seller, server


def test_add_server_to_cart(client, make_user):
    _, server = _make_seller_and_server(make_user)
    make_user(email="buyer@example.com", password="Password123")
    login(client, "buyer@example.com", "Password123")

    resp = client.post("/cart/add", data={"item_type": "server", "item_id": server.id})
    assert resp.status_code == 302
    assert CartItem.query.count() == 1


def test_cannot_add_unavailable_server_to_cart(client, make_user):
    _, server = _make_seller_and_server(make_user, inventory_status=InventoryStatus.SOLD)
    make_user(email="buyer2@example.com", password="Password123")
    login(client, "buyer2@example.com", "Password123")

    resp = client.post("/cart/add", data={"item_type": "server", "item_id": server.id}, follow_redirects=True)
    assert b"no longer available" in resp.data
    assert CartItem.query.count() == 0


def test_checkout_creates_order_and_reserves_inventory(client, make_user):
    seller, server = _make_seller_and_server(make_user)
    buyer = make_user(email="buyer3@example.com", password="Password123")
    login(client, "buyer3@example.com", "Password123")

    client.post("/cart/add", data={"item_type": "server", "item_id": server.id})
    resp = client.post("/checkout")
    assert resp.status_code == 302

    order = Order.query.filter_by(user_id=buyer.id).first()
    assert order is not None
    assert order.seller_id == seller.id
    assert order.status == OrderStatus.AWAITING_PAYMENT
    assert order.subtotal == 100
    assert order.total == 120  # 100 subtotal + 20% default tax
    assert len(order.items) == 1
    assert order.items[0].item_type == OrderItemType.SERVER

    db.session.refresh(server)
    assert server.inventory_status == InventoryStatus.RESERVED
    assert CartItem.query.count() == 0


def test_checkout_prevents_double_booking(client, make_user):
    seller, server = _make_seller_and_server(make_user)
    make_user(email="buyer4@example.com", password="Password123")
    make_user(email="buyer5@example.com", password="Password123")

    login(client, "buyer4@example.com", "Password123")
    client.post("/cart/add", data={"item_type": "server", "item_id": server.id})
    client.post("/checkout")
    client.get("/auth/logout")

    login(client, "buyer5@example.com", "Password123")
    client.post("/cart/add", data={"item_type": "server", "item_id": server.id})
    resp = client.post("/checkout", follow_redirects=True)
    assert b"no longer available" in resp.data

    assert Order.query.count() == 1


def test_seller_cannot_view_other_sellers_order(client, make_user):
    seller, server = _make_seller_and_server(make_user)
    buyer = make_user(email="buyer6@example.com", password="Password123")
    login(client, "buyer6@example.com", "Password123")
    client.post("/cart/add", data={"item_type": "server", "item_id": server.id})
    client.post("/checkout")
    order = Order.query.filter_by(user_id=buyer.id).first()
    client.get("/auth/logout")

    other_seller_user = make_user(email="seller2@example.com", password="Password123", account_type=AccountType.SELLER)
    db.session.add(SellerProfile(user_id=other_seller_user.id, business_name="Other", slug="other", status=SellerStatus.ACTIVE))
    db.session.commit()
    login(client, "seller2@example.com", "Password123")

    resp = client.get(f"/seller/orders/{order.id}")
    assert resp.status_code == 404


def test_admin_can_update_order_status(client, make_user):
    _, server = _make_seller_and_server(make_user)
    buyer = make_user(email="buyer7@example.com", password="Password123")
    login(client, "buyer7@example.com", "Password123")
    client.post("/cart/add", data={"item_type": "server", "item_id": server.id})
    client.post("/checkout")
    order = Order.query.filter_by(user_id=buyer.id).first()
    client.get("/auth/logout")

    make_user(email="admin@example.com", password="Password123", account_type=AccountType.ADMIN, roles=["Super Admin"])
    login(client, "admin@example.com", "Password123")

    resp = client.post(f"/admin/orders/{order.id}", data={"action": "set_status", "status": "paid"})
    assert resp.status_code == 302
    db.session.refresh(order)
    assert order.status == OrderStatus.PAID
    assert len(order.status_history) >= 1


def test_order_progress_info(client, make_user):
    _, server = _make_seller_and_server(make_user)
    buyer = make_user(email="buyer8@example.com", password="Password123")
    login(client, "buyer8@example.com", "Password123")
    client.post("/cart/add", data={"item_type": "server", "item_id": server.id})
    client.post("/checkout")
    order = Order.query.filter_by(user_id=buyer.id).first()

    order.status = OrderStatus.PENDING
    info = order.progress_info
    assert info["current_index"] == 0
    assert info["stopped"] is False

    order.status = OrderStatus.SHIPPED
    info = order.progress_info
    assert info["current_index"] == 5
    assert info["percent"] == round(6 / 7 * 100)

    order.status = OrderStatus.COMPLETED
    info = order.progress_info
    assert info["current_index"] == len(info["steps"]) - 1
    assert info["percent"] == 100
    assert info["stopped"] is False

    order.status = OrderStatus.CANCELLED
    info = order.progress_info
    assert info["stopped"] is True
    assert info["percent"] == 0
    assert info["stopped_label"] == "This order was cancelled."
