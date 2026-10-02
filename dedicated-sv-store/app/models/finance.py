import enum
import random
import string

from app.extensions import db
from app.models.base import TimestampMixin, utcnow


class InvoiceStatus(str, enum.Enum):
    DRAFT = "draft"
    ISSUED = "issued"
    PENDING = "pending"
    PAID = "paid"
    PARTIALLY_PAID = "partially_paid"
    OVERDUE = "overdue"
    CANCELLED = "cancelled"
    REFUNDED = "refunded"


class PaymentTransactionStatus(str, enum.Enum):
    PENDING = "pending"
    COMPLETED = "completed"
    FAILED = "failed"
    REFUNDED = "refunded"


class PaymentTransactionType(str, enum.Enum):
    CHARGE = "charge"
    REFUND = "refund"


class DiscountType(str, enum.Enum):
    PERCENT = "percent"
    FIXED = "fixed"


def _generate_invoice_number():
    return "INV-" + "".join(random.choices(string.digits, k=8))


class Invoice(db.Model, TimestampMixin):
    __tablename__ = "invoices"

    id = db.Column(db.Integer, primary_key=True)
    invoice_number = db.Column(db.String(20), unique=True, default=_generate_invoice_number, nullable=False)
    user_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False)
    order_id = db.Column(db.Integer, db.ForeignKey("orders.id"))

    billing_name = db.Column(db.String(255))
    billing_address_line1 = db.Column(db.String(255))
    billing_address_line2 = db.Column(db.String(255))
    billing_city = db.Column(db.String(100))
    billing_region = db.Column(db.String(100))
    billing_postal_code = db.Column(db.String(20))
    billing_country = db.Column(db.String(2))

    subtotal = db.Column(db.Numeric(10, 2), default=0, nullable=False)
    tax_rate = db.Column(db.Numeric(5, 2), default=0, nullable=False)
    tax_amount = db.Column(db.Numeric(10, 2), default=0, nullable=False)
    discount_amount = db.Column(db.Numeric(10, 2), default=0, nullable=False)
    shipping_amount = db.Column(db.Numeric(10, 2), default=0, nullable=False)
    total = db.Column(db.Numeric(10, 2), default=0, nullable=False)
    currency = db.Column(db.String(3), default="GBP", nullable=False)

    status = db.Column(db.Enum(InvoiceStatus, name="invoice_status"), default=InvoiceStatus.ISSUED, nullable=False)
    due_date = db.Column(db.Date)
    issued_at = db.Column(db.DateTime(timezone=True), default=utcnow)
    paid_at = db.Column(db.DateTime(timezone=True))

    user = db.relationship("User")
    order = db.relationship("Order")
    items = db.relationship("InvoiceItem", back_populates="invoice", cascade="all, delete-orphan")
    payments = db.relationship("Payment", back_populates="invoice", cascade="all, delete-orphan")

    def __repr__(self):
        return f"<Invoice {self.invoice_number}>"

    @property
    def amount_paid(self):
        return sum(
            (p.amount for p in self.payments if p.status == PaymentStatus.COMPLETED),
            start=0,
        )

    @property
    def balance_due(self):
        return (self.total or 0) - (self.amount_paid or 0)


class InvoiceItem(db.Model):
    __tablename__ = "invoice_items"

    id = db.Column(db.Integer, primary_key=True)
    invoice_id = db.Column(db.Integer, db.ForeignKey("invoices.id"), nullable=False)
    description = db.Column(db.String(255), nullable=False)
    quantity = db.Column(db.Integer, default=1, nullable=False)
    unit_price = db.Column(db.Numeric(10, 2), default=0, nullable=False)
    line_total = db.Column(db.Numeric(10, 2), default=0, nullable=False)

    invoice = db.relationship("Invoice", back_populates="items")


class PaymentStatus(str, enum.Enum):
    PENDING = "pending"
    COMPLETED = "completed"
    FAILED = "failed"
    REFUNDED = "refunded"


class Payment(db.Model, TimestampMixin):
    __tablename__ = "payments"

    id = db.Column(db.Integer, primary_key=True)
    invoice_id = db.Column(db.Integer, db.ForeignKey("invoices.id"), nullable=False)
    user_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False)
    amount = db.Column(db.Numeric(10, 2), nullable=False)
    currency = db.Column(db.String(3), default="GBP", nullable=False)
    provider = db.Column(db.String(50), nullable=False)
    provider_reference = db.Column(db.String(255))
    status = db.Column(db.Enum(PaymentStatus, name="payment_status"), default=PaymentStatus.PENDING, nullable=False)
    completed_at = db.Column(db.DateTime(timezone=True))
    refunded_at = db.Column(db.DateTime(timezone=True))

    invoice = db.relationship("Invoice", back_populates="payments")
    user = db.relationship("User")
    transactions = db.relationship("PaymentTransaction", back_populates="payment", cascade="all, delete-orphan")

    def __repr__(self):
        return f"<Payment {self.id} {self.status.value}>"


class PaymentTransaction(db.Model):
    __tablename__ = "payment_transactions"

    id = db.Column(db.Integer, primary_key=True)
    payment_id = db.Column(db.Integer, db.ForeignKey("payments.id"), nullable=False)
    transaction_type = db.Column(db.Enum(PaymentTransactionType, name="payment_transaction_type"), nullable=False)
    provider_transaction_id = db.Column(db.String(255))
    amount = db.Column(db.Numeric(10, 2), nullable=False)
    status = db.Column(
        db.Enum(PaymentTransactionStatus, name="payment_transaction_status"),
        default=PaymentTransactionStatus.PENDING,
        nullable=False,
    )
    raw_response = db.Column(db.JSON, default=dict)
    created_at = db.Column(db.DateTime(timezone=True), default=utcnow, nullable=False)

    payment = db.relationship("Payment", back_populates="transactions")


class Coupon(db.Model, TimestampMixin):
    __tablename__ = "coupons"

    id = db.Column(db.Integer, primary_key=True)
    code = db.Column(db.String(50), unique=True, nullable=False, index=True)
    description = db.Column(db.String(255))
    discount_type = db.Column(db.Enum(DiscountType, name="coupon_discount_type"), nullable=False)
    value = db.Column(db.Numeric(10, 2), nullable=False)
    max_uses = db.Column(db.Integer)
    used_count = db.Column(db.Integer, default=0, nullable=False)
    valid_from = db.Column(db.DateTime(timezone=True))
    valid_until = db.Column(db.DateTime(timezone=True))
    is_active = db.Column(db.Boolean, default=True, nullable=False)

    def is_valid(self):
        now = utcnow()
        if not self.is_active:
            return False
        if self.valid_from and now < self.valid_from:
            return False
        if self.valid_until and now > self.valid_until:
            return False
        if self.max_uses is not None and self.used_count >= self.max_uses:
            return False
        return True

    def compute_discount(self, subtotal):
        from decimal import Decimal

        subtotal = Decimal(str(subtotal))
        if self.discount_type == DiscountType.PERCENT:
            return subtotal * (Decimal(str(self.value)) / 100)
        return min(Decimal(str(self.value)), subtotal)


class Discount(db.Model):
    """Records a coupon actually applied to an order, for reporting/audit."""

    __tablename__ = "discounts"

    id = db.Column(db.Integer, primary_key=True)
    order_id = db.Column(db.Integer, db.ForeignKey("orders.id"), nullable=False)
    coupon_id = db.Column(db.Integer, db.ForeignKey("coupons.id"), nullable=False)
    amount = db.Column(db.Numeric(10, 2), nullable=False)
    created_at = db.Column(db.DateTime(timezone=True), default=utcnow, nullable=False)

    order = db.relationship("Order")
    coupon = db.relationship("Coupon")


class SellerPayout(db.Model, TimestampMixin):
    __tablename__ = "seller_payouts"

    id = db.Column(db.Integer, primary_key=True)
    seller_id = db.Column(db.Integer, db.ForeignKey("seller_profiles.id"), nullable=False)
    order_id = db.Column(db.Integer, db.ForeignKey("orders.id"), nullable=False)
    gross_amount = db.Column(db.Numeric(10, 2), nullable=False)
    commission_amount = db.Column(db.Numeric(10, 2), nullable=False)
    net_amount = db.Column(db.Numeric(10, 2), nullable=False)
    status = db.Column(db.String(20), default="pending", nullable=False)
    paid_at = db.Column(db.DateTime(timezone=True))

    seller = db.relationship("SellerProfile")
    order = db.relationship("Order")

    __table_args__ = (db.UniqueConstraint("order_id", name="uq_seller_payout_order"),)
