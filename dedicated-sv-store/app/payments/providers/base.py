from dataclasses import dataclass, field
from typing import Optional


@dataclass
class PaymentResult:
    success: bool
    provider_reference: Optional[str] = None
    error: Optional[str] = None
    raw: dict = field(default_factory=dict)


class PaymentProvider:
    """Base interface every payment provider adapter must implement.

    The rest of the app (checkout, refunds, webhooks) is written against
    this interface only, so swapping or adding a real provider (Stripe,
    Adyen, ...) never touches order/invoice logic — see MockPaymentProvider
    for the reference implementation used in dev/test.
    """

    name = "base"

    def charge(self, amount, currency, metadata=None) -> PaymentResult:
        raise NotImplementedError

    def refund(self, provider_reference, amount) -> PaymentResult:
        raise NotImplementedError
