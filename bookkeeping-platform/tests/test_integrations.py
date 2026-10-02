import io
from decimal import Decimal
from datetime import date
from app.extensions import db
from app.models.business import Business
from app.models.accounting import create_default_chart_of_accounts, Account
from app.models.party import Customer
from app.models.invoice import Invoice, InvoiceLine, STATUS_SENT
from app.models.integration import IntegrationConfig, IntegrationLog
from app.models.banking import ImportedBankTransaction, STATUS_UNMATCHED
from app.integrations.dispatcher import run_integration
from app.integrations.bank_csv import import_bank_csv, BankCsvError
from app.integrations.stripe_like import handle_payment_succeeded_event, WebhookError


def _setup_business():
    biz = Business(name="Integration Co", base_currency="USD")
    db.session.add(biz)
    db.session.flush()
    create_default_chart_of_accounts(biz)
    db.session.commit()
    return biz


def test_dispatcher_isolates_a_failing_integration(app, db):
    biz = _setup_business()

    def boom():
        raise RuntimeError("provider is down")

    success, result = run_integration("bank_csv", biz.id, "import", boom)
    assert success is False
    assert "provider is down" in result

    log = IntegrationLog.query.filter_by(business_id=biz.id, provider="bank_csv").first()
    assert log.status == "failure"

    # Confirm the failure did NOT corrupt the session / break subsequent DB use.
    assert Account.query.filter_by(business_id=biz.id).count() > 0


def test_bank_csv_import_creates_unmatched_transactions(app, db):
    biz = _setup_business()
    cash = Account.query.filter_by(business_id=biz.id, code="1000").first()

    csv_content = "date,description,amount\n2026-01-05,Client payment,500.00\n2026-01-06,Office rent,-1200.00\n"
    stream = io.BytesIO(csv_content.encode("utf-8"))

    result = import_bank_csv(biz.id, cash.id, stream)
    assert result["imported_count"] == 2

    txns = ImportedBankTransaction.query.filter_by(business_id=biz.id, status=STATUS_UNMATCHED).all()
    assert len(txns) == 2


def test_bank_csv_import_rejects_malformed_csv():
    stream = io.BytesIO(b"not,the,right,columns\n1,2,3,4\n")
    try:
        import_bank_csv("fake-business-id", "fake-account-id", stream)
        assert False, "expected BankCsvError"
    except BankCsvError:
        pass


def test_stripe_webhook_records_payment_via_shared_service(app, db):
    biz = _setup_business()
    customer = Customer(business_id=biz.id, name="Acme")
    db.session.add(customer)
    db.session.flush()
    revenue = Account.query.filter_by(business_id=biz.id, code="4000").first()

    invoice = Invoice(business_id=biz.id, customer_id=customer.id, invoice_number="INV-9", issue_date=date.today(), status=STATUS_SENT)
    db.session.add(invoice)
    db.session.flush()
    db.session.add(InvoiceLine(invoice_id=invoice.id, account_id=revenue.id, description="Work", quantity=1, unit_price=Decimal("300.00")))
    db.session.commit()

    result = handle_payment_succeeded_event({
        "business_id": biz.id, "invoice_id": invoice.id, "amount": "300.00",
    })
    assert result["new_status"] == "paid"
    assert invoice.balance_due() == Decimal("0.00")


def test_stripe_webhook_endpoint_requires_correct_secret(app, db, client):
    biz = _setup_business()
    config = IntegrationConfig(business_id=biz.id, provider="stripe", is_enabled=True, secret="correct-secret")
    db.session.add(config)
    db.session.commit()

    resp = client.post("/integrations/stripe/webhook", json={
        "business_id": biz.id, "invoice_id": "doesnt-matter", "amount": "10.00",
    }, headers={"X-Webhook-Secret": "wrong-secret"})
    assert resp.status_code == 401
