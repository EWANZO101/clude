from app.extensions import db
from app.models.user import AccountType
from app.models.seller import SellerProfile, SellerStatus
from app.models.server import Server, ServerStatus, Favourite
from tests.conftest import login


def _make_active_seller(make_user):
    user = make_user(email="seller1@example.com", password="Password123", account_type=AccountType.SELLER)
    profile = SellerProfile(
        user_id=user.id,
        business_name="Acme Servers",
        slug="acme-servers",
        status=SellerStatus.ACTIVE,
    )
    db.session.add(profile)
    db.session.commit()
    return user, profile


def _make_server(seller, status=ServerStatus.PUBLISHED, **overrides):
    defaults = dict(
        seller_id=seller.id,
        title="Test Server",
        slug=f"test-server-{seller.id}-{status.value}",
        cpu_summary="1x Intel Xeon",
        ram_summary="64GB",
        storage_summary="1TB NVMe",
        network_summary="1Gb",
        monthly_price=100,
        status=status,
    )
    defaults.update(overrides)
    server = Server(**defaults)
    db.session.add(server)
    db.session.commit()
    return server


def test_published_server_visible_on_marketplace(client, make_user):
    _, seller = _make_active_seller(make_user)
    _make_server(seller, status=ServerStatus.PUBLISHED)

    resp = client.get("/servers")
    assert resp.status_code == 200
    assert b"Test Server" in resp.data


def test_draft_server_not_visible_on_marketplace(client, make_user):
    _, seller = _make_active_seller(make_user)
    _make_server(seller, status=ServerStatus.DRAFT)

    resp = client.get("/servers")
    assert resp.status_code == 200
    assert b"Test Server" not in resp.data


def test_seller_can_create_server_listing(client, make_user):
    user, seller = _make_active_seller(make_user)
    login(client, "seller1@example.com", "Password123")

    resp = client.post(
        "/seller/servers/new",
        data={
            "title": "My New Server",
            "cpu_summary": "2x AMD EPYC",
            "ram_summary": "128GB",
            "storage_summary": "2TB NVMe",
            "network_summary": "10Gb",
            "monthly_price": "199.99",
            "status": "published",
            "category_id": "0",
        },
    )
    assert resp.status_code == 302
    server = Server.query.filter_by(title="My New Server").first()
    assert server is not None
    assert server.seller_id == seller.id
    assert server.status == ServerStatus.PUBLISHED


def test_seller_cannot_edit_other_sellers_server(client, make_user):
    _, seller_a = _make_active_seller(make_user)
    server = _make_server(seller_a)

    other_user = make_user(email="seller2@example.com", password="Password123", account_type=AccountType.SELLER)
    other_seller = SellerProfile(
        user_id=other_user.id, business_name="Other Co", slug="other-co", status=SellerStatus.ACTIVE
    )
    db.session.add(other_seller)
    db.session.commit()

    login(client, "seller2@example.com", "Password123")
    resp = client.get(f"/seller/servers/{server.id}")
    assert resp.status_code == 404


def test_favourite_toggle_requires_login(client, make_user):
    _, seller = _make_active_seller(make_user)
    server = _make_server(seller)

    resp = client.post(f"/servers/{server.id}/favourite")
    assert resp.status_code == 302
    assert "/auth/login" in resp.headers["Location"]


def test_favourite_toggle_add_and_remove(client, make_user):
    _, seller = _make_active_seller(make_user)
    server = _make_server(seller)
    make_user(email="fan@example.com", password="Password123")
    login(client, "fan@example.com", "Password123")

    resp = client.post(f"/servers/{server.id}/favourite")
    assert resp.status_code == 302
    assert Favourite.query.count() == 1

    resp = client.post(f"/servers/{server.id}/favourite")
    assert resp.status_code == 302
    assert Favourite.query.count() == 0


def test_try_reserve_prevents_double_booking(app, make_user):
    _, seller = _make_active_seller(make_user)
    server = _make_server(seller)

    first = Server.try_reserve(server.id)
    db.session.commit()
    second = Server.try_reserve(server.id)
    db.session.commit()

    assert first is True
    assert second is False
