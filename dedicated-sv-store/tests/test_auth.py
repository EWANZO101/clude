from app.models.user import User, AccountType
from tests.conftest import login


def test_register_creates_customer(client):
    resp = client.post(
        "/auth/register",
        data={
            "first_name": "Jane",
            "last_name": "Doe",
            "email": "jane@example.com",
            "password": "StrongPass123",
            "confirm_password": "StrongPass123",
        },
    )
    assert resp.status_code == 302

    user = User.query.filter_by(email="jane@example.com").first()
    assert user is not None
    assert user.account_type == AccountType.CUSTOMER
    assert user.customer_profile is not None
    assert not user.is_email_verified


def test_register_rejects_duplicate_email(client, make_user):
    make_user(email="dupe@example.com")
    resp = client.post(
        "/auth/register",
        data={
            "first_name": "Jane",
            "last_name": "Doe",
            "email": "dupe@example.com",
            "password": "StrongPass123",
            "confirm_password": "StrongPass123",
        },
    )
    assert resp.status_code == 200
    assert b"already exists" in resp.data


def test_register_rejects_weak_password(client):
    resp = client.post(
        "/auth/register",
        data={
            "first_name": "Jane",
            "last_name": "Doe",
            "email": "weak@example.com",
            "password": "weak",
            "confirm_password": "weak",
        },
    )
    assert resp.status_code == 200
    assert User.query.filter_by(email="weak@example.com").first() is None


def test_login_success_redirects_to_dashboard(client, make_user):
    make_user(email="login@example.com", password="Password123")
    resp = login(client, "login@example.com", "Password123")
    assert resp.status_code == 302
    assert "/customer" in resp.headers["Location"]


def test_login_wrong_password_fails(client, make_user):
    make_user(email="wrongpw@example.com", password="Password123")
    resp = login(client, "wrongpw@example.com", "WrongPassword")
    assert resp.status_code == 200
    assert b"Invalid email or password" in resp.data


def test_account_locks_after_failed_attempts(client, make_user):
    user = make_user(email="lockout@example.com", password="Password123")
    for _ in range(5):
        login(client, "lockout@example.com", "WrongPassword")

    user_refreshed = User.query.filter_by(email="lockout@example.com").first()
    assert user_refreshed.is_locked()

    resp = login(client, "lockout@example.com", "Password123")
    assert b"temporarily locked" in resp.data


def test_logout_requires_login(client):
    resp = client.get("/auth/logout")
    assert resp.status_code == 302
    assert "/auth/login" in resp.headers["Location"]


def test_inactive_user_cannot_login(client, make_user):
    user = make_user(email="inactive@example.com", password="Password123")
    user.is_active = False
    from app.extensions import db

    db.session.commit()

    resp = login(client, "inactive@example.com", "Password123")
    assert b"deactivated" in resp.data
