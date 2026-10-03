from app.extensions import db
from app.models.user import AccountType
from app.models.seller import SellerProfile, SellerStatus
from app.models.server import Server, ServerStatus, InventoryStatus
from app.models.order import Order, OrderItem, OrderItemType
from tests.conftest import login


def _login_admin(client, make_user, email="serveradmin@example.com"):
    make_user(email=email, password="Password123", account_type=AccountType.ADMIN, roles=["Super Admin"])
    login(client, email, "Password123")


def test_admin_can_create_platform_owned_server(client, make_user):
    _login_admin(client, make_user)

    resp = client.post(
        "/admin/servers/new",
        data={
            "seller_id": "0", "category_id": "0", "title": "Admin Server", "status": "published",
            "cpu_summary": "c", "ram_summary": "r", "storage_summary": "s", "network_summary": "n",
            "monthly_price": "50",
        },
    )
    assert resp.status_code == 302
    server = Server.query.filter_by(title="Admin Server").first()
    assert server is not None
    assert server.seller_id is None
    assert server.status == ServerStatus.PUBLISHED


def test_admin_can_create_server_for_existing_seller(client, make_user):
    _login_admin(client, make_user)
    seller_user = make_user(email="assignseller@example.com", password="Password123", account_type=AccountType.SELLER)
    seller = SellerProfile(user_id=seller_user.id, business_name="Assign Co", slug="assign-co", status=SellerStatus.ACTIVE)
    db.session.add(seller)
    db.session.commit()

    resp = client.post(
        "/admin/servers/new",
        data={
            "seller_id": str(seller.id), "category_id": "0", "title": "Seller Assigned Server", "status": "draft",
            "cpu_summary": "c", "ram_summary": "r", "storage_summary": "s", "network_summary": "n",
            "monthly_price": "75",
        },
    )
    assert resp.status_code == 302
    server = Server.query.filter_by(title="Seller Assigned Server").first()
    assert server.seller_id == seller.id


def test_admin_can_edit_server(client, make_user):
    _login_admin(client, make_user)
    server = Server(
        title="Editable", slug="editable", cpu_summary="c", ram_summary="r",
        storage_summary="s", network_summary="n", monthly_price=10, status=ServerStatus.DRAFT,
    )
    db.session.add(server)
    db.session.commit()

    resp = client.post(
        f"/admin/servers/{server.id}/edit",
        data={
            "seller_id": "0", "category_id": "0", "title": "Renamed", "status": "published",
            "cpu_summary": "c2", "ram_summary": "r", "storage_summary": "s", "network_summary": "n",
            "monthly_price": "20",
        },
    )
    assert resp.status_code == 302
    db.session.refresh(server)
    assert server.title == "Renamed"
    assert server.cpu_summary == "c2"
    assert server.status == ServerStatus.PUBLISHED
    assert float(server.monthly_price) == 20


def test_admin_can_delete_server_without_order_history(client, make_user):
    _login_admin(client, make_user)
    server = Server(
        title="Deletable", slug="deletable", cpu_summary="c", ram_summary="r",
        storage_summary="s", network_summary="n", monthly_price=10, status=ServerStatus.DRAFT,
    )
    db.session.add(server)
    db.session.commit()
    server_id = server.id

    resp = client.post(f"/admin/servers/{server_id}/delete")
    assert resp.status_code == 302
    assert db.session.get(Server, server_id) is None


def test_admin_cannot_delete_server_with_order_history(client, make_user):
    _login_admin(client, make_user)
    buyer = make_user(email="serverbuyer@example.com", password="Password123")
    server = Server(
        title="Ordered", slug="ordered", cpu_summary="c", ram_summary="r",
        storage_summary="s", network_summary="n", monthly_price=10, status=ServerStatus.DRAFT,
    )
    db.session.add(server)
    db.session.flush()
    order = Order(user_id=buyer.id)
    db.session.add(order)
    db.session.flush()
    db.session.add(
        OrderItem(
            order_id=order.id, item_type=OrderItemType.SERVER, server_id=server.id,
            title_snapshot="Ordered", unit_monthly_price=10, line_total=10,
        )
    )
    db.session.commit()
    server_id = server.id

    resp = client.post(f"/admin/servers/{server_id}/delete", follow_redirects=True)
    assert b"can" in resp.data and b"deleted" in resp.data
    assert db.session.get(Server, server_id) is not None


def test_admin_can_change_stock_status(client, make_user):
    _login_admin(client, make_user)
    server = Server(
        title="Stocked", slug="stocked", cpu_summary="c", ram_summary="r",
        storage_summary="s", network_summary="n", monthly_price=10,
        status=ServerStatus.PUBLISHED, inventory_status=InventoryStatus.AVAILABLE,
    )
    db.session.add(server)
    db.session.commit()

    resp = client.post(
        f"/admin/servers/{server.id}",
        data={"action": "set_inventory_status", "inventory_status": "maintenance"},
    )
    assert resp.status_code == 302
    db.session.refresh(server)
    assert server.inventory_status == InventoryStatus.MAINTENANCE
    assert len(server.inventory_events) == 1


def test_non_admin_staff_cannot_create_server(client, make_user):
    make_user(email="noaccess@example.com", password="Password123", account_type=AccountType.STAFF, roles=["Support"])
    login(client, "noaccess@example.com", "Password123")
    resp = client.get("/admin/servers/new")
    assert resp.status_code == 403
