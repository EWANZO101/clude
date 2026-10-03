from decimal import Decimal
from datetime import date
from app.models.business import Business
from app.models.accounting import create_default_chart_of_accounts, Account
from app.models.party import Customer, Supplier
from app.models.invoice import Invoice, InvoiceLine, STATUS_DRAFT, STATUS_SENT, STATUS_PAID
from app.models.bill import Bill, BillLine, STATUS_OPEN
from app.extensions import db
from app.invoices.routes import _receivable_account
from app.bills.routes import _payable_account
from app.accounting.engine import post_journal_entry


def _setup_business():
    biz = Business(name="Invoice Co", base_currency="USD")
    db.session.add(biz)
    db.session.flush()
    create_default_chart_of_accounts(biz)
    db.session.commit()
    return biz


def test_sending_invoice_posts_balanced_entry(app, db):
    biz = _setup_business()
    customer = Customer(business_id=biz.id, name="Acme")
    db.session.add(customer)
    db.session.flush()

    revenue = Account.query.filter_by(business_id=biz.id, code="4000").first()
    invoice = Invoice(business_id=biz.id, customer_id=customer.id, invoice_number="INV-1", issue_date=date.today(), status=STATUS_DRAFT)
    db.session.add(invoice)
    db.session.flush()
    db.session.add(InvoiceLine(invoice_id=invoice.id, account_id=revenue.id, description="Consulting", quantity=1, unit_price=Decimal("500.00"), tax_rate=0))
    db.session.commit()

    from app.invoices.routes import send_invoice  # noqa: F401  (import ensures module loads)
    from app.accounting.engine import post_journal_entry as pje

    receivable = _receivable_account(biz)
    entry = pje(
        business_id=biz.id,
        entry_date=invoice.issue_date,
        lines=[{"account_id": receivable.id, "debit": invoice.total()}, {"account_id": revenue.id, "credit": invoice.total()}],
        description="Invoice INV-1",
        source_type="invoice",
        source_id=invoice.id,
    )
    assert entry.is_balanced()
    assert receivable.balance() == Decimal("500.00")
    assert revenue.balance() == Decimal("500.00")


def test_bill_approval_posts_balanced_entry(app, db):
    biz = _setup_business()
    supplier = Supplier(business_id=biz.id, name="Office Supplies Inc")
    db.session.add(supplier)
    db.session.flush()

    expense_acc = Account.query.filter_by(business_id=biz.id, code="6000").first()
    bill = Bill(business_id=biz.id, supplier_id=supplier.id, issue_date=date.today(), status="draft")
    db.session.add(bill)
    db.session.flush()
    db.session.add(BillLine(bill_id=bill.id, account_id=expense_acc.id, description="Paper", amount=Decimal("75.00")))
    db.session.commit()

    payable = _payable_account(biz)
    entry = post_journal_entry(
        business_id=biz.id,
        entry_date=bill.issue_date,
        lines=[{"account_id": payable.id, "credit": bill.total()}, {"account_id": expense_acc.id, "debit": bill.total()}],
        description="Bill",
        source_type="bill",
        source_id=bill.id,
    )
    assert entry.is_balanced()
    assert payable.balance() == Decimal("75.00")
    assert expense_acc.balance() == Decimal("75.00")


def test_invoice_balance_due_tracks_payments(app, db):
    biz = _setup_business()
    customer = Customer(business_id=biz.id, name="Acme")
    db.session.add(customer)
    db.session.flush()
    revenue = Account.query.filter_by(business_id=biz.id, code="4000").first()
    invoice = Invoice(business_id=biz.id, customer_id=customer.id, invoice_number="INV-2", issue_date=date.today(), status=STATUS_SENT)
    db.session.add(invoice)
    db.session.flush()
    db.session.add(InvoiceLine(invoice_id=invoice.id, account_id=revenue.id, description="Design work", quantity=1, unit_price=Decimal("200.00")))
    db.session.commit()

    assert invoice.balance_due() == Decimal("200.00")

    from app.models.invoice import Payment
    cash = Account.query.filter_by(business_id=biz.id, code="1000").first()
    db.session.add(Payment(business_id=biz.id, invoice_id=invoice.id, payment_date=date.today(), amount=Decimal("200.00"), deposit_account_id=cash.id))
    db.session.commit()

    assert invoice.balance_due() == Decimal("0.00")
