import json

from app.extensions import db
from app.models.user import AccountType
from app.models.seller import SellerProfile, SellerStatus
from app.models.server import Server, ServerStatus, InventoryStatus
from app.models.api import ApiKey, Webhook


def _make_seller(make_user):
    user = make_user(email="apiseller@example.com", password="Password123", account_type=AccountType.SELLER)
    seller = SellerProfile(user_id=user.id, business_name="API Co", slug="api-co", status=SellerStatus.ACTIVE)
    db.session.add(seller)
    db.session.commit()
    return user, seller


def _issue_key(user_id, scopes=None, seller_id=None):
    api_key, raw = ApiKey.generate(user_id=user_id, name="Test key", scopes=scopes or [], seller_id=seller_id)
    db.session.add(api_key)
    db.session.commit()
    return raw


def test_public_servers_endpoint_requires_no_key(client, make_user):
    _, seller = _make_seller(make_user)
    server = Server(
        seller_id=seller.id, title="Pub Server", slug="pub-server", cpu_summary="c", ram_summary="r",
        storage_summary="s", network_summary="n", monthly_price=10,
        status=ServerStatus.PUBLISHED, inventory_status=InventoryStatus.AVAILABLE,
    )
    db.session.add(server)
    db.session.commit()

    resp = client.get("/api/v1/servers")
    assert resp.status_code == 200
    data = resp.get_json()
    assert data["success"] is True
    assert any(s["title"] == "Pub Server" for s in data["data"])


def test_protected_endpoint_requires_api_key(client):
    resp = client.get("/api/v1/orders")
    assert resp.status_code == 401
    assert resp.get_json()["success"] is False


def test_invalid_api_key_rejected(client):
    resp = client.get("/api/v1/orders", headers={"X-API-Key": "dsv_bogus"})
    assert resp.status_code == 401


def test_seller_can_create_server_via_api(client, make_user):
    user, seller = _make_seller(make_user)
    raw_key = _issue_key(user.id, scopes=["servers:write"], seller_id=seller.id)

    resp = client.post(
        "/api/v1/servers",
        headers={"X-API-Key": raw_key},
        data=json.dumps(
            {
                "title": "New API Server", "cpu_summary": "c", "ram_summary": "r",
                "storage_summary": "s", "network_summary": "n", "monthly_price": 50,
            }
        ),
        content_type="application/json",
    )
    assert resp.status_code == 201
    server = Server.query.filter_by(title="New API Server").first()
    assert server is not None
    assert server.seller_id == seller.id


def test_seller_cannot_update_other_sellers_server_via_api(client, make_user):
    user, seller = _make_seller(make_user)
    other_user = make_user(email="apiseller2@example.com", password="Password123", account_type=AccountType.SELLER)
    other_seller = SellerProfile(user_id=other_user.id, business_name="Other API Co", slug="other-api-co", status=SellerStatus.ACTIVE)
    db.session.add(other_seller)
    db.session.commit()

    server = Server(
        seller_id=other_seller.id, title="Not yours", slug="not-yours", cpu_summary="c", ram_summary="r",
        storage_summary="s", network_summary="n", monthly_price=10, status=ServerStatus.PUBLISHED,
    )
    db.session.add(server)
    db.session.commit()

    raw_key = _issue_key(user.id, scopes=["servers:write"], seller_id=seller.id)
    resp = client.put(
        f"/api/v1/servers/{server.id}",
        headers={"X-API-Key": raw_key},
        data=json.dumps({"title": "Hijacked"}),
        content_type="application/json",
    )
    assert resp.status_code == 403


def test_admin_endpoint_rejects_non_admin_key(client, make_user):
    user, seller = _make_seller(make_user)
    raw_key = _issue_key(user.id, scopes=["admin:read"], seller_id=seller.id)

    resp = client.get("/api/v1/customers", headers={"X-API-Key": raw_key})
    assert resp.status_code == 403


def test_admin_key_can_list_customers(client, make_user):
    admin = make_user(email="apiadmin@example.com", password="Password123", account_type=AccountType.ADMIN, roles=["Super Admin"])
    make_user(email="apicust@example.com", password="Password123")
    raw_key = _issue_key(admin.id, scopes=["admin:read"])

    resp = client.get("/api/v1/customers", headers={"X-API-Key": raw_key})
    assert resp.status_code == 200
    data = resp.get_json()
    assert any(c["email"] == "apicust@example.com" for c in data["data"])


def test_revoked_key_is_rejected(client, make_user):
    user, seller = _make_seller(make_user)
    raw_key = _issue_key(user.id, seller_id=seller.id)
    api_key = ApiKey.query.filter_by(user_id=user.id).first()
    api_key.is_active = False
    db.session.commit()

    resp = client.get("/api/v1/inventory", headers={"X-API-Key": raw_key})
    assert resp.status_code == 401


def test_seller_can_register_webhook_via_api(client, make_user):
    user, seller = _make_seller(make_user)
    raw_key = _issue_key(user.id, scopes=["webhooks:manage"], seller_id=seller.id)

    resp = client.post(
        "/api/v1/webhooks",
        headers={"X-API-Key": raw_key},
        data=json.dumps({"url": "https://example.com/hook", "events": ["order.paid"]}),
        content_type="application/json",
    )
    assert resp.status_code == 201
    webhook = Webhook.query.filter_by(seller_id=seller.id).first()
    assert webhook is not None
    assert webhook.url == "https://example.com/hook"
