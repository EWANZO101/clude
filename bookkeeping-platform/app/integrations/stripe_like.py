"""A Stripe-shaped webhook handler, generic enough to model any card
processor's 'payment succeeded' event. Verifies a shared secret (stand-in
for Stripe's signature verification) so the endpoint can't be used to
fabricate payments, then records the payment through the SAME code path the
UI uses (app/invoices/services.record_invoice_payment) — an integration
never gets a separate, unaudited way to touch the ledger."""
from app.models.business import Business
from app.models.invoice import Invoice
from app.invoices.services import record_invoice_payment, InvoicePaymentError


class WebhookError(Exception):
    pass


def handle_payment_succeeded_event(payload):
    business_id = payload.get("business_id")
    invoice_id = payload.get("invoice_id")
    amount = payload.get("amount")
    deposit_account_code = payload.get("deposit_account_code", "1000")  # default: Cash and Bank

    if not business_id or not invoice_id or amount is None:
        raise WebhookError("Payload must include business_id, invoice_id, and amount.")

    business = Business.query.get(business_id)
    if business is None:
        raise WebhookError(f"Unknown business_id {business_id}.")

    invoice = Invoice.query.filter_by(id=invoice_id, business_id=business_id).first()
    if invoice is None:
        raise WebhookError(f"Unknown invoice_id {invoice_id} for this business.")

    from app.models.accounting import Account
    deposit_account = Account.query.filter_by(business_id=business_id, code=deposit_account_code).first()
    if deposit_account is None:
        raise WebhookError(f"No account with code {deposit_account_code} for this business.")

    try:
        payment = record_invoice_payment(
            business=business, invoice=invoice, amount=amount,
            deposit_account_id=deposit_account.id, source_type="stripe_webhook",
        )
    except InvoicePaymentError as e:
        raise WebhookError(str(e))

    return {"payment_id": payment.id, "invoice_id": invoice.id, "new_status": invoice.status}
