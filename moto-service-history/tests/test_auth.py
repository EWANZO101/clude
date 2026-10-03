from tests.conftest import register, login


def test_register_and_redirect_to_dashboard(client):
    resp = register(client)
    assert resp.status_code == 302
    assert resp.headers["Location"] == "/dashboard"


def test_duplicate_username_rejected(client):
    register(client, "rider")
    client.post("/auth/logout")
    resp = register(client, "rider")
    assert resp.status_code == 200
    assert b"already taken" in resp.data


def test_login_wrong_password_rejected(client):
    register(client, "rider")
    client.post("/auth/logout")
    resp = login(client, "rider", "wrongpassword")
    assert resp.status_code == 200
    assert b"Incorrect username or password" in resp.data


def test_disabled_account_cannot_log_in(client, app):
    register(client, "rider")
    client.post("/auth/logout")

    with app.app_context():
        from app.models import User
        from app.extensions import db
        u = User.query.filter_by(username="rider").first()
        u.is_disabled = True
        db.session.commit()

    resp = login(client, "rider")
    assert b"disabled" in resp.data


def test_dashboard_requires_login(client):
    resp = client.get("/dashboard", follow_redirects=False)
    assert resp.status_code == 302
    assert "/auth/login" in resp.headers["Location"]


def test_default_admin_created_on_boot(client):
    resp = login(client, "admin", "changeme123")
    assert resp.status_code == 302
    resp = client.get("/admin/")
    assert resp.status_code == 200
