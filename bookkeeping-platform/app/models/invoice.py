import uuid
from datetime import datetime
from decimal import Decimal
from app.extensions import db

STATUS_DRAFT = "draft"
STATUS_SENT = "sent"
STATUS_PARTIALLY_PAID = "partially_paid"
STATUS_PAID = "paid"
STATUS_OVERDUE = "overdue"
STATUS_VOID = "void"

INVOICE_STATUSES = [STATUS_DRAFT, STATUS_SENT, STATUS_PARTIALLY_PAID, STATUS_PAID, STATUS_OVERDUE, STATUS_VOID]


def gen_uuid():
    return str(uuid.uuid4())


class Invoice(db.Model):
    __tablename__ = "invoices"

    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    business_id = db.Column(db.String(36), db.ForeignKey("businesses.id"), nullable=False)
    customer_id = db.Column(db.String(36), db.ForeignKey("customers.id"), nullable=False)

    invoice_number = db.Column(db.String(50), nullable=False)
    issue_date = db.Column(db.Date, nullable=False)
    due_date = db.Column(db.Date, nullable=True)
    status = db.Column(db.String(20), nullable=False, default=STATUS_DRAFT)
    currency = db.Column(db.String(3), nullable=False, default="USD")
    notes = db.Column(db.Text, nullable=True)

    journal_entry_id = db.Column(db.String(36), db.ForeignKey("journal_entries.id"), nullable=True)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    customer = db.relationship("Customer", back_populates="invoices")
    lines = db.relationship("InvoiceLine", back_populates="invoice", cascade="all, delete-orphan")
    payments = db.relationship("Payment", back_populates="invoice", cascade="all, delete-orphan")

    def subtotal(self):
        return sum((l.quantity * l.unit_price for l in self.lines), Decimal("0"))

    def tax_total(self):
        return sum((l.quantity * l.unit_price * (l.tax_rate / 100) for l in self.lines), Decimal("0"))

    def total(self):
        return self.subtotal() + self.tax_total()

    def paid_total(self):
        return sum((p.amount for p in self.payments), Decimal("0"))

    def balance_due(self):
        if self.status in ("draft", "void"):
            return Decimal("0")
        return self.total() - self.paid_total()

    def __repr__(self):
        return f"<Invoice {self.invoice_number}>"


class InvoiceLine(db.Model):
    __tablename__ = "invoice_lines"

    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    invoice_id = db.Column(db.String(36), db.ForeignKey("invoices.id"), nullable=False)
    account_id = db.Column(db.String(36), db.ForeignKey("accounts.id"), nullable=False)  # revenue account

    description = db.Column(db.String(500), nullable=False)
    quantity = db.Column(db.Numeric(14, 2), nullable=False, default=1)
    unit_price = db.Column(db.Numeric(14, 2), nullable=False, default=0)
    tax_rate = db.Column(db.Numeric(5, 2), nullable=False, default=0)  # percent

    invoice = db.relationship("Invoice", back_populates="lines")
    account = db.relationship("Account")


class Payment(db.Model):
    """A payment received against an invoice, or made against a bill.
    Exactly one of invoice_id / bill_id is set."""

    __tablename__ = "payments"

    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    business_id = db.Column(db.String(36), db.ForeignKey("businesses.id"), nullable=False)
    invoice_id = db.Column(db.String(36), db.ForeignKey("invoices.id"), nullable=True)
    bill_id = db.Column(db.String(36), db.ForeignKey("bills.id"), nullable=True)

    payment_date = db.Column(db.Date, nullable=False)
    amount = db.Column(db.Numeric(14, 2), nullable=False)
    deposit_account_id = db.Column(db.String(36), db.ForeignKey("accounts.id"), nullable=False)
    notes = db.Column(db.String(500), nullable=True)

    journal_entry_id = db.Column(db.String(36), db.ForeignKey("journal_entries.id"), nullable=True)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    invoice = db.relationship("Invoice", back_populates="payments")
    bill = db.relationship("Bill", back_populates="payments")
    deposit_account = db.relationship("Account")
