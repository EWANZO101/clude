from app.models.seller import SellerStatus
from tests.conftest import login


def test_customer_can_apply_as_seller(client, make_user):
    make_user(email="wantstosell@example.com", password="Password123")
    login(client, "wantstosell@example.com", "Password123")

    resp = client.post(
        "/seller/apply",
        data={"business_name": "Acme Hosting", "description": "We host servers."},
    )
    assert resp.status_code == 302

    resp = client.get("/seller/", follow_redirects=True)
    assert b"under review" in resp.data


def test_seller_application_creates_pending_profile(client, make_user):
    user = make_user(email="pendingseller@example.com", password="Password123")
    login(client, "pendingseller@example.com", "Password123")
    client.post(
        "/seller/apply",
        data={"business_name": "Beta Servers", "description": "Servers for everyone."},
    )
    assert user.seller_profile is not None
    assert user.seller_profile.status == SellerStatus.APPLICATION


def test_anonymous_cannot_apply(client):
    resp = client.get("/seller/apply")
    assert resp.status_code == 302
    assert "/auth/login" in resp.headers["Location"]
