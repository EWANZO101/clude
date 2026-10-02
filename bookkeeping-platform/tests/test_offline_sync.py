import uuid
from decimal import Decimal
from app.models.business import Business, Membership, ROLE_OWNER
from app.models.accounting import create_default_chart_of_accounts, Account
from app.models.expense import Expense
from app.extensions import db


def _setup_business_and_login(app, db, client):
    from app.models.user import User

    user = User(email="offline@example.com", full_name="Offline User")
    user.set_password("password123456")
    db.session.add(user)
    db.session.flush()

    biz = Business(name="Offline Co", base_currency="USD")
    db.session.add(biz)
    db.session.flush()
    create_default_chart_of_accounts(biz)
    db.session.add(Membership(user_id=user.id, business_id=biz.id, role=ROLE_OWNER))
    user.current_business_id = biz.id
    db.session.commit()

    client.post("/auth/login", data={"email": "offline@example.com", "password": "password123456"})
    return biz


def test_sync_creates_expense_from_queued_item(app, db, client):
    biz = _setup_business_and_login(app, db, client)
    expense_acc = Account.query.filter_by(business_id=biz.id, code="6000").first()
    cash = Account.query.filter_by(business_id=biz.id, code="1000").first()
    client_uuid = str(uuid.uuid4())

    resp = client.post("/sync/expenses", json={"items": [{
        "client_uuid": client_uuid,
        "description": "Taxi (queued offline)",
        "amount": "42.50",
        "expense_date": "2026-01-15",
        "expense_account_id": expense_acc.id,
        "paid_from_account_id": cash.id,
    }]})
    assert resp.status_code == 200
    data = resp.get_json()
    assert data["results"][0]["status"] == "created"

    expense = Expense.query.filter_by(business_id=biz.id, client_uuid=client_uuid).first()
    assert expense is not None
    assert expense.amount == Decimal("42.50")
    assert cash.balance() == Decimal("-42.50")


def test_sync_is_idempotent_for_retried_client_uuid(app, db, client):
    """Simulates a device retrying a sync after a dropped response, or two
    devices flushing the same queued item — the server must not double-post."""
    biz = _setup_business_and_login(app, db, client)
    expense_acc = Account.query.filter_by(business_id=biz.id, code="6000").first()
    cash = Account.query.filter_by(business_id=biz.id, code="1000").first()
    client_uuid = str(uuid.uuid4())
    item = {
        "client_uuid": client_uuid,
        "description": "Hotel (queued offline)",
        "amount": "100.00",
        "expense_date": "2026-01-16",
        "expense_account_id": expense_acc.id,
        "paid_from_account_id": cash.id,
    }

    resp1 = client.post("/sync/expenses", json={"items": [item]})
    resp2 = client.post("/sync/expenses", json={"items": [item]})  # retry with the SAME client_uuid

    assert resp1.get_json()["results"][0]["status"] == "created"
    assert resp2.get_json()["results"][0]["status"] == "duplicate"

    matching = Expense.query.filter_by(business_id=biz.id, client_uuid=client_uuid).all()
    assert len(matching) == 1  # not duplicated
    assert cash.balance() == Decimal("-100.00")  # not double-deducted


def test_ping_requires_login(client):
    resp = client.get("/sync/ping")
    assert resp.status_code in (302, 401)  # redirected to login, not a bare 200
