from unittest.mock import patch

from app.extensions import db
from app.models.user import AccountType
from app.models.seller import SellerProfile, SellerStatus
from app.models.server import Server, ServerStatus
from app.models.order import Order, OrderItem, OrderItemType, OrderPaymentStatus
from app.models.integrations import HardwareApiConnection, SellerApiConnection, ConnectionStatus
from app.integrations.adapters import ConnectionTestResult
from tests.conftest import login


def _login_admin(client, make_user, email="completionsadmin@example.com"):
    make_user(email=email, password="Password123", account_type=AccountType.ADMIN, roles=["Super Admin"])
    login(client, email, "Password123")


def test_admin_customer_servers_lists_purchased_items(client, make_user):
    _login_admin(client, make_user)
    buyer = make_user(email="csbuyer@example.com", password="Password123")
    server = Server(
        title="CS Server", slug="cs-server", cpu_summary="c", ram_summary="r",
        storage_summary="s", network_summary="n", monthly_price=10, status=ServerStatus.DRAFT,
    )
    db.session.add(server)
    db.session.flush()
    order = Order(user_id=buyer.id, total=10)
    db.session.add(order)
    db.session.flush()
    db.session.add(
        OrderItem(order_id=order.id, item_type=OrderItemType.SERVER, server_id=server.id, title_snapshot="CS Server", unit_monthly_price=10, line_total=10)
    )
    db.session.commit()

    resp = client.get("/admin/customer-servers")
    assert resp.status_code == 200
    assert b"CS Server" in resp.data
    assert b"csbuyer@example.com" in resp.data


def test_admin_seller_orders_aggregates_by_seller(client, make_user):
    _login_admin(client, make_user)
    seller_user = make_user(email="soseller@example.com", password="Password123", account_type=AccountType.SELLER)
    seller = SellerProfile(user_id=seller_user.id, business_name="SO Seller", slug="so-seller", status=SellerStatus.ACTIVE)
    db.session.add(seller)
    db.session.flush()
    buyer = make_user(email="sobuyer@example.com", password="Password123")
    db.session.add(Order(user_id=buyer.id, seller_id=seller.id, total=150, payment_status=OrderPaymentStatus.PAID))
    db.session.commit()

    resp = client.get("/admin/seller-orders")
    assert resp.status_code == 200
    assert b"SO Seller" in resp.data
    assert b"150" in resp.data


def test_admin_orders_can_filter_by_seller(client, make_user):
    _login_admin(client, make_user)
    seller_user = make_user(email="filterseller@example.com", password="Password123", account_type=AccountType.SELLER)
    seller = SellerProfile(user_id=seller_user.id, business_name="Filter Co", slug="filter-co", status=SellerStatus.ACTIVE)
    db.session.add(seller)
    db.session.flush()
    buyer = make_user(email="filterbuyer@example.com", password="Password123")
    order = Order(user_id=buyer.id, seller_id=seller.id, total=99)
    db.session.add(order)
    other_buyer = make_user(email="otherbuyer@example.com", password="Password123")
    db.session.add(Order(user_id=other_buyer.id, seller_id=None, total=5))
    db.session.commit()

    resp = client.get(f"/admin/orders?seller={seller.id}")
    assert resp.status_code == 200
    assert order.order_number.encode() in resp.data


def test_admin_can_add_and_test_hardware_api_connection(client, make_user):
    _login_admin(client, make_user)

    resp = client.post(
        "/admin/hardware-apis",
        data={
            "name": "Test Feed", "provider_type": "generic_rest", "base_url": "https://example.com/api",
            "sync_frequency_hours": "24", "is_active": "y",
        },
    )
    assert resp.status_code == 302
    conn = HardwareApiConnection.query.filter_by(name="Test Feed").first()
    assert conn is not None
    assert conn.status == ConnectionStatus.UNTESTED

    with patch("app.integrations.admin_views.get_adapter") as mock_get_adapter:
        mock_get_adapter.return_value.test_connection.return_value = ConnectionTestResult(True, "Reachable (HTTP 200).")
        resp = client.post(f"/admin/hardware-apis/{conn.id}/test")
        assert resp.status_code == 302

    db.session.refresh(conn)
    assert conn.status == ConnectionStatus.CONNECTED
    assert conn.last_checked_at is not None


def test_admin_hardware_api_test_records_failure(client, make_user):
    _login_admin(client, make_user)
    conn = HardwareApiConnection(name="Flaky", base_url="https://unreachable.example")
    db.session.add(conn)
    db.session.commit()

    with patch("app.integrations.admin_views.get_adapter") as mock_get_adapter:
        mock_get_adapter.return_value.test_connection.return_value = ConnectionTestResult(False, "Connection refused")
        client.post(f"/admin/hardware-apis/{conn.id}/test")

    db.session.refresh(conn)
    assert conn.status == ConnectionStatus.FAILED
    assert conn.last_error == "Connection refused"


def test_admin_can_add_seller_api_connection(client, make_user):
    _login_admin(client, make_user)
    seller_user = make_user(email="provseller@example.com", password="Password123", account_type=AccountType.SELLER)
    seller = SellerProfile(user_id=seller_user.id, business_name="Provider Co", slug="provider-co", status=SellerStatus.ACTIVE)
    db.session.add(seller)
    db.session.commit()

    resp = client.post(
        "/admin/providers",
        data={
            "seller_id": str(seller.id), "name": "Their inventory API", "provider_type": "generic_rest",
            "base_url": "https://seller-system.example.com/api", "is_active": "y",
        },
    )
    assert resp.status_code == 302
    conn = SellerApiConnection.query.filter_by(name="Their inventory API").first()
    assert conn is not None
    assert conn.seller_id == seller.id


def test_non_admin_cannot_manage_integrations(client, make_user):
    make_user(email="noaccess2@example.com", password="Password123", account_type=AccountType.STAFF, roles=["Support"])
    login(client, "noaccess2@example.com", "Password123")
    resp = client.get("/admin/hardware-apis")
    assert resp.status_code == 403
