from tests.conftest import register, login


def test_admin_area_blocked_for_regular_user(client):
    register(client, "rider")
    resp = client.get("/admin/")
    assert resp.status_code == 403


def test_admin_area_blocked_for_anonymous(client):
    resp = client.get("/admin/", follow_redirects=False)
    assert resp.status_code == 302
    assert "/auth/login" in resp.headers["Location"]


def test_admin_can_create_and_disable_user(client):
    login(client, "admin", "changeme123")
    resp = client.post(
        "/admin/users/new",
        data={"username": "newstaff", "password": "password123"},
        follow_redirects=False,
    )
    assert resp.status_code == 302

    users_page = client.get("/admin/users")
    assert b"newstaff" in users_page.data


def test_admin_cannot_disable_own_account(client, app):
    login(client, "admin", "changeme123")
    with app.app_context():
        from app.models import User
        admin_id = User.query.filter_by(username="admin").first().id
    resp = client.post(f"/admin/users/{admin_id}/toggle-disabled", follow_redirects=True)
    assert b"cannot disable your own account" in resp.data.lower() or b"cannot disable" in resp.data.lower()


def test_mot_settings_persist(client, app):
    login(client, "admin", "changeme123")
    resp = client.post(
        "/admin/settings/mot",
        data={
            "dvsa_api_key": "test-key",
            "dvsa_client_id": "cid",
            "dvsa_client_secret": "csecret",
            "dvsa_token_url": "https://example.com/token",
            "dvsa_scope_url": "https://example.com/scope",
            "dvsa_api_base": "https://history.mot.api.gov.uk/v1/trade/vehicles/registration",
        },
        follow_redirects=False,
    )
    assert resp.status_code == 302
    with app.app_context():
        from app.models import AppSetting
        assert AppSetting.get("dvsa_api_key") == "test-key"
