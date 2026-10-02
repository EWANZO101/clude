import uuid
from datetime import datetime
from app.extensions import db


def gen_uuid():
    return str(uuid.uuid4())


class Expense(db.Model):
    """A standalone, already-paid expense (as opposed to a Bill, which
    represents money owed to a supplier and may be paid later)."""

    __tablename__ = "expenses"
    __table_args__ = (
        db.UniqueConstraint("business_id", "client_uuid", name="uq_expense_business_client_uuid"),
    )

    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    business_id = db.Column(db.String(36), db.ForeignKey("businesses.id"), nullable=False)
    supplier_id = db.Column(db.String(36), db.ForeignKey("suppliers.id"), nullable=True)
    # Set by offline clients when the record is first created (before it
    # ever reaches the server). Lets the sync endpoint recognise a retried
    # or multi-device-duplicated sync attempt instead of double-posting it.
    client_uuid = db.Column(db.String(64), nullable=True)
    # Set when this expense was generated automatically by a
    # RecurringExpense template, rather than entered by hand.
    recurring_expense_id = db.Column(db.String(36), db.ForeignKey("recurring_expenses.id"), nullable=True)

    expense_date = db.Column(db.Date, nullable=False)
    description = db.Column(db.String(500), nullable=False)
    amount = db.Column(db.Numeric(14, 2), nullable=False)
    expense_account_id = db.Column(db.String(36), db.ForeignKey("accounts.id"), nullable=False)
    paid_from_account_id = db.Column(db.String(36), db.ForeignKey("accounts.id"), nullable=False)
    is_reimbursable = db.Column(db.Boolean, default=False, nullable=False)
    is_recurring = db.Column(db.Boolean, default=False, nullable=False)

    journal_entry_id = db.Column(db.String(36), db.ForeignKey("journal_entries.id"), nullable=True)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    supplier = db.relationship("Supplier")
    expense_account = db.relationship("Account", foreign_keys=[expense_account_id])
    paid_from_account = db.relationship("Account", foreign_keys=[paid_from_account_id])
