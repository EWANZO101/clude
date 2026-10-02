from datetime import date
from decimal import Decimal
from app.extensions import db
from app.models.accounting import Account
from app.models.invoice import Invoice, Payment, STATUS_PAID, STATUS_PARTIALLY_PAID
from app.accounting.engine import post_journal_entry


class InvoicePaymentError(Exception):
    pass


def record_invoice_payment(business, invoice, amount, deposit_account_id, payment_date=None, created_by_id=None, source_type="payment"):
    if invoice.business_id != business.id:
        raise InvoicePaymentError("Invoice does not belong to this business.")
    if invoice.status not in ("sent", "partially_paid", "overdue"):
        raise InvoicePaymentError(f"Invoice cannot receive payments in status '{invoice.status}'.")

    amount = Decimal(str(amount))
    if amount <= 0 or amount > invoice.balance_due():
        raise InvoicePaymentError("Payment amount must be positive and not exceed the balance due.")

    receivable = Account.query.filter_by(business_id=business.id, code="1100").first()
    entry = post_journal_entry(
        business_id=business.id,
        entry_date=payment_date or date.today(),
        lines=[
            {"account_id": deposit_account_id, "debit": amount},
            {"account_id": receivable.id, "credit": amount},
        ],
        description=f"Payment for invoice {invoice.invoice_number}",
        source_type=source_type,
        source_id=invoice.id,
        created_by_id=created_by_id,
    )

    payment = Payment(
        business_id=business.id,
        invoice_id=invoice.id,
        payment_date=entry.entry_date,
        amount=amount,
        deposit_account_id=deposit_account_id,
        journal_entry_id=entry.id,
    )
    db.session.add(payment)
    invoice.status = STATUS_PAID if invoice.balance_due() - amount <= 0 else STATUS_PARTIALLY_PAID
    db.session.commit()
    return payment
