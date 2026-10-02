import uuid
from datetime import datetime, date, timedelta
from app.extensions import db

FREQUENCY_DAILY = "daily"
FREQUENCY_WEEKLY = "weekly"
FREQUENCY_MONTHLY = "monthly"
FREQUENCIES = [FREQUENCY_DAILY, FREQUENCY_WEEKLY, FREQUENCY_MONTHLY]


def gen_uuid():
    return str(uuid.uuid4())


def _advance_date(d, frequency):
    if frequency == FREQUENCY_DAILY:
        return d + timedelta(days=1)
    if frequency == FREQUENCY_WEEKLY:
        return d + timedelta(weeks=1)
    if frequency == FREQUENCY_MONTHLY:
        # Simple month rollover without extra dependencies.
        month = d.month + 1
        year = d.year + (1 if month > 12 else 0)
        month = 1 if month > 12 else month
        day = min(d.day, 28)  # avoid Feb-30 style overflow
        return date(year, month, day)
    raise ValueError(f"Unknown frequency: {frequency}")


class RecurringExpense(db.Model):
    """A template that generates a real, ledger-posted Expense each time
    it's due — through the exact same accounting engine as a manually
    entered expense. Nothing about a generated expense is 'lighter-weight'
    or less auditable than one a person typed in by hand."""

    __tablename__ = "recurring_expenses"

    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    business_id = db.Column(db.String(36), db.ForeignKey("businesses.id"), nullable=False)

    description = db.Column(db.String(500), nullable=False)
    amount = db.Column(db.Numeric(14, 2), nullable=False)
    expense_account_id = db.Column(db.String(36), db.ForeignKey("accounts.id"), nullable=False)
    paid_from_account_id = db.Column(db.String(36), db.ForeignKey("accounts.id"), nullable=False)
    supplier_id = db.Column(db.String(36), db.ForeignKey("suppliers.id"), nullable=True)

    frequency = db.Column(db.String(20), nullable=False, default=FREQUENCY_MONTHLY)
    start_date = db.Column(db.Date, nullable=False, default=date.today)
    end_date = db.Column(db.Date, nullable=True)
    next_run_date = db.Column(db.Date, nullable=False)
    is_active = db.Column(db.Boolean, default=True, nullable=False)

    created_by_id = db.Column(db.String(36), db.ForeignKey("users.id"), nullable=True)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    expense_account = db.relationship("Account", foreign_keys=[expense_account_id])
    paid_from_account = db.relationship("Account", foreign_keys=[paid_from_account_id])
    supplier = db.relationship("Supplier")

    def is_due(self, as_of=None):
        as_of = as_of or date.today()
        if not self.is_active:
            return False
        if self.end_date and as_of > self.end_date:
            return False
        return self.next_run_date <= as_of

    def advance(self):
        self.next_run_date = _advance_date(self.next_run_date, self.frequency)
        if self.end_date and self.next_run_date > self.end_date:
            self.is_active = False
