from app.models.user import AccountType
from tests.conftest import login


def test_super_admin_has_all_permissions(make_user):
    admin = make_user(email="admin@example.com", account_type=AccountType.ADMIN, roles=["Super Admin"])
    assert admin.has_permission("users.edit")
    assert admin.has_permission("invoices.view")


def test_customer_has_no_admin_permissions(make_user):
    customer = make_user(email="cust@example.com")
    assert not customer.has_permission("users.edit")


def test_finance_role_scoped_permissions(make_user):
    finance_user = make_user(email="finance@example.com", account_type=AccountType.STAFF, roles=["Finance"])
    assert finance_user.has_permission("invoices.view")
    assert finance_user.has_permission("payments.refund")
    assert not finance_user.has_permission("users.edit")


def test_non_staff_cannot_access_admin(client, make_user):
    make_user(email="regular@example.com", password="Password123")
    login(client, "regular@example.com", "Password123")
    resp = client.get("/admin/")
    assert resp.status_code == 403


def test_staff_without_permission_gets_403(client, make_user):
    make_user(email="supportonly@example.com", password="Password123", account_type=AccountType.STAFF, roles=["Support"])
    login(client, "supportonly@example.com", "Password123")
    resp = client.get("/admin/users")
    assert resp.status_code == 403


def test_admin_dashboard_accessible_to_super_admin(client, make_user):
    make_user(email="root@example.com", password="Password123", account_type=AccountType.ADMIN, roles=["Super Admin"])
    login(client, "root@example.com", "Password123")
    resp = client.get("/admin/")
    assert resp.status_code == 200


def test_admin_can_reset_user_password(client, make_user):
    make_user(email="pwadmin@example.com", password="Password123", account_type=AccountType.ADMIN, roles=["Super Admin"])
    target = make_user(email="pwtarget@example.com", password="OldPassword123")
    login(client, "pwadmin@example.com", "Password123")

    resp = client.post(
        f"/admin/users/{target.id}",
        data={"action": "set_password", "new_password": "BrandNewPass123", "confirm_password": "BrandNewPass123"},
    )
    assert resp.status_code == 302

    from app.extensions import db

    db.session.refresh(target)
    assert target.check_password("BrandNewPass123")
    assert not target.check_password("OldPassword123")

    client.get("/auth/logout")
    resp = login(client, "pwtarget@example.com", "BrandNewPass123")
    assert resp.status_code == 302
    assert "/customer" in resp.headers["Location"]


def test_admin_password_reset_rejects_weak_password(client, make_user):
    make_user(email="pwadmin2@example.com", password="Password123", account_type=AccountType.ADMIN, roles=["Super Admin"])
    target = make_user(email="pwtarget2@example.com", password="OldPassword123")
    login(client, "pwadmin2@example.com", "Password123")

    resp = client.post(
        f"/admin/users/{target.id}",
        data={"action": "set_password", "new_password": "weak", "confirm_password": "weak"},
    )
    assert resp.status_code == 200
    assert b"at least 10 characters" in resp.data

    from app.extensions import db

    db.session.refresh(target)
    assert target.check_password("OldPassword123")


def test_non_admin_staff_cannot_reset_password(client, make_user):
    make_user(email="supportonly3@example.com", password="Password123", account_type=AccountType.STAFF, roles=["Support"])
    target = make_user(email="pwtarget3@example.com", password="OldPassword123")
    login(client, "supportonly3@example.com", "Password123")

    resp = client.post(
        f"/admin/users/{target.id}",
        data={"action": "set_password", "new_password": "BrandNewPass123", "confirm_password": "BrandNewPass123"},
    )
    assert resp.status_code == 403
