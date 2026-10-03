import uuid
from datetime import datetime
from decimal import Decimal
from app.extensions import db

STATUS_DRAFT = "draft"
STATUS_OPEN = "open"
STATUS_PARTIALLY_PAID = "partially_paid"
STATUS_PAID = "paid"
STATUS_OVERDUE = "overdue"
STATUS_VOID = "void"

BILL_STATUSES = [STATUS_DRAFT, STATUS_OPEN, STATUS_PARTIALLY_PAID, STATUS_PAID, STATUS_OVERDUE, STATUS_VOID]


def gen_uuid():
    return str(uuid.uuid4())


class Bill(db.Model):
    __tablename__ = "bills"

    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    business_id = db.Column(db.String(36), db.ForeignKey("businesses.id"), nullable=False)
    supplier_id = db.Column(db.String(36), db.ForeignKey("suppliers.id"), nullable=False)

    bill_number = db.Column(db.String(50), nullable=True)
    issue_date = db.Column(db.Date, nullable=False)
    due_date = db.Column(db.Date, nullable=True)
    status = db.Column(db.String(20), nullable=False, default=STATUS_DRAFT)
    notes = db.Column(db.Text, nullable=True)

    journal_entry_id = db.Column(db.String(36), db.ForeignKey("journal_entries.id"), nullable=True)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    supplier = db.relationship("Supplier", back_populates="bills")
    lines = db.relationship("BillLine", back_populates="bill", cascade="all, delete-orphan")
    payments = db.relationship("Payment", back_populates="bill", cascade="all, delete-orphan")

    def total(self):
        return sum((l.amount for l in self.lines), Decimal("0"))

    def paid_total(self):
        return sum((p.amount for p in self.payments), Decimal("0"))

    def balance_due(self):
        if self.status in ("draft", "void"):
            return Decimal("0")
        return self.total() - self.paid_total()


class BillLine(db.Model):
    __tablename__ = "bill_lines"

    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    bill_id = db.Column(db.String(36), db.ForeignKey("bills.id"), nullable=False)
    account_id = db.Column(db.String(36), db.ForeignKey("accounts.id"), nullable=False)  # expense account

    description = db.Column(db.String(500), nullable=False)
    amount = db.Column(db.Numeric(14, 2), nullable=False, default=0)

    bill = db.relationship("Bill", back_populates="lines")
    account = db.relationship("Account")
