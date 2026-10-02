import uuid

from app.payments.providers.base import PaymentProvider, PaymentResult


class MockPaymentProvider(PaymentProvider):
    """Instant-success provider for development, demos and tests. No real
    money moves; it exists purely to exercise the charge/refund flow through
    the same interface a real gateway adapter would use."""

    name = "mock"

    def charge(self, amount, currency, metadata=None):
        reference = f"mock_ch_{uuid.uuid4().hex[:16]}"
        return PaymentResult(
            success=True,
            provider_reference=reference,
            raw={"amount": str(amount), "currency": currency, "metadata": metadata or {}},
        )

    def refund(self, provider_reference, amount):
        reference = f"mock_re_{uuid.uuid4().hex[:16]}"
        return PaymentResult(success=True, provider_reference=reference, raw={"amount": str(amount)})
