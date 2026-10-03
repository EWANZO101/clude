import zipfile
import io
from decimal import Decimal
from datetime import date
from app.extensions import db
from app.models.business import Business, Membership, ROLE_OWNER
from app.models.accounting import create_default_chart_of_accounts, Account
from app.models.party import Customer
from app.models.invoice import Invoice, InvoiceLine, STATUS_SENT


def _setup_business_and_login(db, client):
    from app.models.user import User

    user = User(email="export@example.com", full_name="Export Tester")
    user.set_password("password123456")
    db.session.add(user)
    db.session.flush()

    biz = Business(name="Export Co", base_currency="USD")
    db.session.add(biz)
    db.session.flush()
    create_default_chart_of_accounts(biz)
    db.session.add(Membership(user_id=user.id, business_id=biz.id, role=ROLE_OWNER))
    user.current_business_id = biz.id
    db.session.commit()

    client.post("/auth/login", data={"email": "export@example.com", "password": "password123456"})
    return biz


def test_csv_export_returns_header_and_rows(app, db, client):
    biz = _setup_business_and_login(db, client)
    customer = Customer(business_id=biz.id, name="Exportable Customer", email="ex@example.com")
    db.session.add(customer)
    db.session.commit()

    resp = client.get("/export/customers.csv")
    assert resp.status_code == 200
    assert resp.mimetype == "text/csv"
    text = resp.get_data(as_text=True)
    assert "name" in text.splitlines()[0]
    assert "Exportable Customer" in text


def test_download_everything_contains_manifest_and_csvs(app, db, client):
    biz = _setup_business_and_login(db, client)
    resp = client.get("/export/download-everything")
    assert resp.status_code == 200
    assert resp.mimetype == "application/zip"

    zf = zipfile.ZipFile(io.BytesIO(resp.data))
    names = zf.namelist()
    assert "manifest.json" in names
    assert "data/customers.csv" in names
    assert "data/chart_of_accounts.csv" in names


def test_search_finds_customer_and_invoice(app, db, client):
    biz = _setup_business_and_login(db, client)
    customer = Customer(business_id=biz.id, name="Findable Customer Inc")
    db.session.add(customer)
    db.session.flush()
    revenue = Account.query.filter_by(business_id=biz.id, code="4000").first()
    invoice = Invoice(business_id=biz.id, customer_id=customer.id, invoice_number="FIND-001", issue_date=date.today(), status=STATUS_SENT)
    db.session.add(invoice)
    db.session.flush()
    db.session.add(InvoiceLine(invoice_id=invoice.id, account_id=revenue.id, description="Work", quantity=1, unit_price=Decimal("10.00")))
    db.session.commit()

    resp = client.get("/search/?q=Findable")
    assert resp.status_code == 200
    assert b"Findable Customer Inc" in resp.data

    resp = client.get("/search/?q=FIND-001")
    assert b"FIND-001" in resp.data
