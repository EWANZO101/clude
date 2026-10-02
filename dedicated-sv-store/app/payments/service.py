from flask import current_app

from app.extensions import db
from app.models.base import utcnow
from app.models.finance import (
    Invoice,
    InvoiceStatus,
    Payment,
    PaymentStatus,
    PaymentTransaction,
    PaymentTransactionType,
    PaymentTransactionStatus,
)
from app.models.order import Order, OrderStatus, OrderPaymentStatus
from app.payments.providers.mock import MockPaymentProvider
from app.utils.helpers import log_audit
from app.utils.notifications import notify


def get_provider():
    name = current_app.config.get("PAYMENT_PROVIDER", "mock")
    providers = {"mock": MockPaymentProvider}
    provider_cls = providers.get(name, MockPaymentProvider)
    return provider_cls()


def charge_invoice(invoice: Invoice, user):
    """Charges the outstanding balance on an invoice. Returns the Payment row."""
    provider = get_provider()
    amount = invoice.balance_due

    payment = Payment(
        invoice_id=invoice.id, user_id=user.id, amount=amount, currency=invoice.currency,
        provider=provider.name, status=PaymentStatus.PENDING,
    )
    db.session.add(payment)
    db.session.flush()

    result = provider.charge(amount, invoice.currency, metadata={"invoice_id": invoice.id})

    db.session.add(
        PaymentTransaction(
            payment_id=payment.id,
            transaction_type=PaymentTransactionType.CHARGE,
            provider_transaction_id=result.provider_reference,
            amount=amount,
            status=PaymentTransactionStatus.COMPLETED if result.success else PaymentTransactionStatus.FAILED,
            raw_response=result.raw,
        )
    )

    if result.success:
        payment.status = PaymentStatus.COMPLETED
        payment.provider_reference = result.provider_reference
        payment.completed_at = utcnow()

        invoice.status = InvoiceStatus.PAID
        invoice.paid_at = utcnow()

        if invoice.order:
            invoice.order.payment_status = OrderPaymentStatus.PAID
            invoice.order.set_status(OrderStatus.PAID, note="Payment received")
            _record_seller_payout(invoice.order)

        notify(
            invoice.user_id, "invoice.paid", "Payment received",
            body=f"Your payment for invoice {invoice.invoice_number} was successful.",
            link=f"/customer/invoices/{invoice.id}",
        )
        log_audit("payment.completed", "Invoice", invoice.id, None, {"amount": str(amount)})

        from app.api.v1.webhooks import dispatch_webhook

        dispatch_webhook("invoice.paid", {"invoice_id": invoice.id, "invoice_number": invoice.invoice_number})
        if invoice.order:
            dispatch_webhook("order.paid", {"order_id": invoice.order.id, "order_number": invoice.order.order_number})
    else:
        payment.status = PaymentStatus.FAILED
        log_audit("payment.failed", "Invoice", invoice.id, None, {"error": result.error})

    db.session.commit()
    return payment


def refund_payment(payment: Payment, admin_user):
    provider = get_provider()
    result = provider.refund(payment.provider_reference, payment.amount)

    db.session.add(
        PaymentTransaction(
            payment_id=payment.id,
            transaction_type=PaymentTransactionType.REFUND,
            provider_transaction_id=result.provider_reference,
            amount=payment.amount,
            status=PaymentTransactionStatus.COMPLETED if result.success else PaymentTransactionStatus.FAILED,
            raw_response=result.raw,
        )
    )

    if result.success:
        payment.status = PaymentStatus.REFUNDED
        payment.refunded_at = utcnow()
        payment.invoice.status = InvoiceStatus.REFUNDED
        if payment.invoice.order:
            payment.invoice.order.payment_status = OrderPaymentStatus.REFUNDED
            payment.invoice.order.set_status(OrderStatus.REFUNDED, changed_by_id=admin_user.id, note="Refunded by admin")
        log_audit("payment.refunded", "Payment", payment.id, None, {"amount": str(payment.amount)})

    db.session.commit()
    return result.success


def _record_seller_payout(order: Order):
    from app.models.finance import SellerPayout
    from app.models.seller import SellerProfile
    from decimal import Decimal

    if order.seller_id is None:
        return
    if SellerPayout.query.filter_by(order_id=order.id).first():
        return

    seller = db.session.get(SellerProfile, order.seller_id)
    commission_percent = Decimal(str(seller.commission_percent_override)) if seller.commission_percent_override else Decimal(
        str(current_app.config.get("PLATFORM_COMMISSION_PERCENT", 10))
    )
    gross = Decimal(str(order.subtotal))
    commission = gross * (commission_percent / 100)
    net = gross - commission

    db.session.add(
        SellerPayout(
            seller_id=seller.id, order_id=order.id, gross_amount=gross,
            commission_amount=commission, net_amount=net, status="pending",
        )
    )
