from decimal import Decimal
from datetime import date, timedelta
from app.extensions import db
from app.models.business import Business, Membership, ROLE_OWNER
from app.models.accounting import create_default_chart_of_accounts, Account
from app.models.party import Customer, Supplier
from app.models.invoice import Invoice, InvoiceLine, STATUS_SENT
from app.models.bill import Bill, BillLine, STATUS_OPEN
from app.models.recurring import RecurringExpense
from app.models.notification import Notification
from app.models.expense import Expense
from app.recurring.processor import process_recurring_expenses_for_business
from app.accounting.scheduled_checks import check_overdue_invoices, check_upcoming_bills


def _setup_business_with_owner():
    from app.models.user import User

    biz = Business(name="Notify Co", base_currency="USD")
    db.session.add(biz)
    db.session.flush()
    create_default_chart_of_accounts(biz)

    owner = User(email="owner-notify@example.com", full_name="Owner")
    owner.set_password("password123456")
    db.session.add(owner)
    db.session.flush()
    db.session.add(Membership(user_id=owner.id, business_id=biz.id, role=ROLE_OWNER))
    db.session.commit()
    return biz, owner


def test_overdue_invoice_check_flags_status_and_notifies(app, db):
    biz, owner = _setup_business_with_owner()
    customer = Customer(business_id=biz.id, name="Late Payer")
    db.session.add(customer)
    db.session.flush()
    revenue = Account.query.filter_by(business_id=biz.id, code="4000").first()

    invoice = Invoice(
        business_id=biz.id, customer_id=customer.id, invoice_number="INV-LATE",
        issue_date=date.today() - timedelta(days=20), due_date=date.today() - timedelta(days=5),
        status=STATUS_SENT,
    )
    db.session.add(invoice)
    db.session.flush()
    db.session.add(InvoiceLine(invoice_id=invoice.id, account_id=revenue.id, description="Work", quantity=1, unit_price=Decimal("100.00")))
    db.session.commit()

    flagged = check_overdue_invoices(biz.id)
    assert len(flagged) == 1
    assert invoice.status == "overdue"

    notifs = Notification.query.filter_by(user_id=owner.id, business_id=biz.id).all()
    assert len(notifs) == 1
    assert notifs[0].type == "overdue_invoice"


def test_upcoming_bill_check_notifies_within_window(app, db):
    biz, owner = _setup_business_with_owner()
    supplier = Supplier(business_id=biz.id, name="Soon Due Supplier")
    db.session.add(supplier)
    db.session.flush()
    expense_acc = Account.query.filter_by(business_id=biz.id, code="6000").first()

    bill = Bill(business_id=biz.id, supplier_id=supplier.id, issue_date=date.today(), due_date=date.today() + timedelta(days=2), status=STATUS_OPEN)
    db.session.add(bill)
    db.session.flush()
    db.session.add(BillLine(bill_id=bill.id, account_id=expense_acc.id, description="Rent", amount=Decimal("500.00")))
    db.session.commit()

    notified = check_upcoming_bills(biz.id)
    assert len(notified) == 1

    notifs = Notification.query.filter_by(user_id=owner.id, type="upcoming_bill").all()
    assert len(notifs) == 1


def test_recurring_expense_generates_ledger_posted_expense(app, db):
    biz, owner = _setup_business_with_owner()
    expense_acc = Account.query.filter_by(business_id=biz.id, code="6000").first()
    cash = Account.query.filter_by(business_id=biz.id, code="1000").first()

    template = RecurringExpense(
        business_id=biz.id, description="Monthly hosting", amount=Decimal("50.00"),
        expense_account_id=expense_acc.id, paid_from_account_id=cash.id,
        frequency="monthly", start_date=date.today() - timedelta(days=1), next_run_date=date.today() - timedelta(days=1),
    )
    db.session.add(template)
    db.session.commit()

    created = process_recurring_expenses_for_business(biz.id)
    assert len(created) == 1
    assert created[0].recurring_expense_id == template.id
    assert cash.balance() == Decimal("-50.00")

    expenses = Expense.query.filter_by(business_id=biz.id, recurring_expense_id=template.id).all()
    assert len(expenses) == 1

    # Running again immediately should NOT generate a second expense —
    # next_run_date has already advanced past today.
    created_again = process_recurring_expenses_for_business(biz.id)
    assert len(created_again) == 0


def test_notification_preference_suppresses_notification(app, db):
    from app.models.notification import NotificationPreference
    from app.notifications.service import notify_user

    biz, owner = _setup_business_with_owner()
    pref = NotificationPreference(user_id=owner.id, notify_overdue_invoices=False)
    db.session.add(pref)
    db.session.commit()

    result = notify_user(owner.id, "overdue_invoice", "Should be suppressed", "test", business_id=biz.id)
    assert result is None
    assert Notification.query.filter_by(user_id=owner.id).count() == 0
