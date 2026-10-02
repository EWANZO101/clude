from decimal import Decimal
from datetime import date, timedelta
from app.extensions import db
from app.models.business import Business, Membership, ROLE_OWNER
from app.models.accounting import create_default_chart_of_accounts, Account
from app.models.party import Customer
from app.models.invoice import Invoice, InvoiceLine, STATUS_SENT
from app.accounting.categorization import suggest_category_for_business
from app.models.invitation import Invitation, STATUS_PENDING


def _setup_business():
    biz = Business(name="Advanced Co", base_currency="USD")
    db.session.add(biz)
    db.session.flush()
    create_default_chart_of_accounts(biz)
    db.session.commit()
    return biz


def test_aged_receivables_buckets_by_due_date(app, db, client):
    from app.models.user import User

    biz = _setup_business()
    user = User(email="aged@example.com", full_name="Aged Tester")
    user.set_password("password123456")
    db.session.add(user)
    db.session.flush()
    db.session.add(Membership(user_id=user.id, business_id=biz.id, role=ROLE_OWNER))
    user.current_business_id = biz.id
    db.session.commit()

    customer = Customer(business_id=biz.id, name="Overdue Customer")
    db.session.add(customer)
    db.session.flush()
    revenue = Account.query.filter_by(business_id=biz.id, code="4000").first()

    overdue_invoice = Invoice(
        business_id=biz.id, customer_id=customer.id, invoice_number="INV-OLD",
        issue_date=date.today() - timedelta(days=50), due_date=date.today() - timedelta(days=40),
        status=STATUS_SENT,
    )
    db.session.add(overdue_invoice)
    db.session.flush()
    db.session.add(InvoiceLine(invoice_id=overdue_invoice.id, account_id=revenue.id, description="Old work", quantity=1, unit_price=Decimal("400.00")))
    db.session.commit()

    client.post("/auth/login", data={"email": "aged@example.com", "password": "password123456"})
    resp = client.get("/accounting/reports/aged-receivables")
    assert resp.status_code == 200
    assert b"31-60" in resp.data


def test_categorization_suggestion_never_writes_to_db(app, db):
    biz = _setup_business()
    suggestions = suggest_category_for_business("AWS hosting charges for December", biz)
    assert len(suggestions) >= 1
    assert suggestions[0]["account"].code == "6000"
    # Confirm it's purely advisory: no Expense row was created as a side effect.
    from app.models.expense import Expense
    assert Expense.query.filter_by(business_id=biz.id).count() == 0


def test_invitation_accept_creates_membership(app, db, client):
    from app.models.user import User

    biz = _setup_business()
    owner = User(email="owner@example.com", full_name="Owner")
    owner.set_password("password123456")
    accountant = User(email="accountant@example.com", full_name="Accountant")
    accountant.set_password("password123456")
    db.session.add_all([owner, accountant])
    db.session.flush()
    db.session.add(Membership(user_id=owner.id, business_id=biz.id, role=ROLE_OWNER))
    db.session.commit()

    invite = Invitation(business_id=biz.id, invited_by_id=owner.id, email="accountant@example.com", role="accountant")
    db.session.add(invite)
    db.session.commit()

    client.post("/auth/login", data={"email": "accountant@example.com", "password": "password123456"})
    resp = client.get(f"/businesses/invitations/{invite.token}/accept", follow_redirects=True)
    assert resp.status_code == 200

    assert accountant.role_in(biz) == "accountant"
    db.session.refresh(invite)
    assert invite.status == "accepted"


def test_cash_flow_forecast_route_loads(app, db, client):
    from app.models.user import User

    biz = _setup_business()
    user = User(email="cf@example.com", full_name="CF Tester")
    user.set_password("password123456")
    db.session.add(user)
    db.session.flush()
    db.session.add(Membership(user_id=user.id, business_id=biz.id, role=ROLE_OWNER))
    user.current_business_id = biz.id
    db.session.commit()

    client.post("/auth/login", data={"email": "cf@example.com", "password": "password123456"})
    resp = client.get("/accounting/reports/cash-flow-forecast")
    assert resp.status_code == 200
