"""Daily checks that turn ledger state into notifications: invoices past
due get flagged 'overdue' (status transition, not a silent write — it's the
same status the UI already understands), and bills due soon get a
heads-up before they're actually late."""
from datetime import date, timedelta
from app.extensions import db
from app.models.business import Business
from app.models.invoice import Invoice, STATUS_SENT, STATUS_PARTIALLY_PAID, STATUS_OVERDUE
from app.models.bill import Bill, STATUS_OPEN, STATUS_PARTIALLY_PAID as BILL_PARTIALLY_PAID
from app.models.notification import TYPE_OVERDUE_INVOICE, TYPE_UPCOMING_BILL
from app.notifications.service import notify_business_admins

UPCOMING_BILL_WINDOW_DAYS = 3


def check_overdue_invoices(business_id, as_of=None):
    as_of = as_of or date.today()
    invoices = Invoice.query.filter(
        Invoice.business_id == business_id,
        Invoice.status.in_([STATUS_SENT, STATUS_PARTIALLY_PAID]),
        Invoice.due_date.isnot(None),
        Invoice.due_date < as_of,
    ).all()

    flagged = []
    for inv in invoices:
        inv.status = STATUS_OVERDUE
        notify_business_admins(
            business_id, TYPE_OVERDUE_INVOICE,
            title=f"Invoice {inv.invoice_number} is overdue",
            message=f"Invoice {inv.invoice_number} for {inv.customer.name} was due {inv.due_date} "
                    f"and has a balance of {inv.balance_due()}.",
            link=f"/invoices/{inv.id}",
        )
        flagged.append(inv)
    db.session.commit()
    return flagged


def check_upcoming_bills(business_id, as_of=None):
    as_of = as_of or date.today()
    window_end = as_of + timedelta(days=UPCOMING_BILL_WINDOW_DAYS)
    bills = Bill.query.filter(
        Bill.business_id == business_id,
        Bill.status.in_([STATUS_OPEN, BILL_PARTIALLY_PAID]),
        Bill.due_date.isnot(None),
        Bill.due_date >= as_of,
        Bill.due_date <= window_end,
    ).all()

    notified = []
    for bill in bills:
        notify_business_admins(
            business_id, TYPE_UPCOMING_BILL,
            title=f"Bill {bill.bill_number or bill.id[:8]} due soon",
            message=f"Bill from {bill.supplier.name} for {bill.balance_due()} is due {bill.due_date}.",
            link=f"/bills/{bill.id}",
        )
        notified.append(bill)
    return notified


def run_daily_checks_for_all_businesses(as_of=None):
    for business in Business.query.filter_by(is_archived=False).all():
        check_overdue_invoices(business.id, as_of=as_of)
        check_upcoming_bills(business.id, as_of=as_of)
