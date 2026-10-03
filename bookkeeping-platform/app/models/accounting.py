import uuid
from datetime import datetime
from app.extensions import db

ASSET = "asset"
LIABILITY = "liability"
EQUITY = "equity"
REVENUE = "revenue"
COGS = "cogs"
EXPENSE = "expense"

ACCOUNT_TYPES = [ASSET, LIABILITY, EQUITY, REVENUE, COGS, EXPENSE]

# Which side increases the balance of each account type.
DEBIT_INCREASES = {ASSET, EXPENSE, COGS}
CREDIT_INCREASES = {LIABILITY, EQUITY, REVENUE}


def gen_uuid():
    return str(uuid.uuid4())


class Account(db.Model):
    """A single account in a business's chart of accounts."""

    __tablename__ = "accounts"
    __table_args__ = (
        db.UniqueConstraint("business_id", "code", name="uq_business_account_code"),
    )

    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    business_id = db.Column(db.String(36), db.ForeignKey("businesses.id"), nullable=False)
    parent_id = db.Column(db.String(36), db.ForeignKey("accounts.id"), nullable=True)

    code = db.Column(db.String(20), nullable=False)
    name = db.Column(db.String(255), nullable=False)
    account_type = db.Column(db.String(20), nullable=False)
    description = db.Column(db.Text, nullable=True)
    is_archived = db.Column(db.Boolean, default=False, nullable=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    business = db.relationship("Business", back_populates="accounts")
    children = db.relationship("Account", backref=db.backref("parent", remote_side=[id]))
    lines = db.relationship("JournalLine", back_populates="account")

    def balance(self):
        """Computed balance in the account's natural direction (never negative
        by convention; a debit-normal account with credit balance shows negative)."""
        total_debit = sum(l.debit for l in self.lines if not l.journal_entry.is_void)
        total_credit = sum(l.credit for l in self.lines if not l.journal_entry.is_void)
        if self.account_type in DEBIT_INCREASES:
            return total_debit - total_credit
        return total_credit - total_debit

    def __repr__(self):
        return f"<Account {self.code} {self.name}>"


DEFAULT_CHART_OF_ACCOUNTS = [
    ("1000", "Cash and Bank", ASSET),
    ("1100", "Accounts Receivable", ASSET),
    ("1500", "Fixed Assets", ASSET),
    ("2000", "Accounts Payable", LIABILITY),
    ("2100", "Loans Payable", LIABILITY),
    ("2200", "Tax Payable", LIABILITY),
    ("3000", "Owner's Equity", EQUITY),
    ("3900", "Retained Earnings", EQUITY),
    ("4000", "Sales Revenue", REVENUE),
    ("5000", "Cost of Goods Sold", COGS),
    ("6000", "General Expenses", EXPENSE),
    ("6100", "Payroll Expenses", EXPENSE),
    ("6200", "Bank Fees", EXPENSE),
]


def create_default_chart_of_accounts(business):
    for code, name, acct_type in DEFAULT_CHART_OF_ACCOUNTS:
        db.session.add(Account(business_id=business.id, code=code, name=name, account_type=acct_type))


class JournalEntry(db.Model):
    """A balanced, atomic accounting event. Every transaction in the system
    (invoice, expense, transfer, manual entry, ...) is ultimately recorded as
    one of these, made up of >=2 JournalLines whose debits equal credits."""

    __tablename__ = "journal_entries"

    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    business_id = db.Column(db.String(36), db.ForeignKey("businesses.id"), nullable=False)

    entry_date = db.Column(db.Date, nullable=False)
    posting_date = db.Column(db.DateTime, default=datetime.utcnow)
    reference = db.Column(db.String(100), nullable=True)
    description = db.Column(db.Text, nullable=True)
    source_type = db.Column(db.String(50), nullable=False, default="manual")  # invoice/expense/manual/...
    source_id = db.Column(db.String(36), nullable=True)

    is_void = db.Column(db.Boolean, default=False, nullable=False)
    is_reconciled = db.Column(db.Boolean, default=False, nullable=False)

    created_by_id = db.Column(db.String(36), db.ForeignKey("users.id"), nullable=True)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    business = db.relationship("Business", back_populates="journal_entries")
    lines = db.relationship("JournalLine", back_populates="journal_entry", cascade="all, delete-orphan")

    def total_debit(self):
        return sum(l.debit for l in self.lines)

    def total_credit(self):
        return sum(l.credit for l in self.lines)

    def is_balanced(self):
        return round(self.total_debit() - self.total_credit(), 2) == 0

    def __repr__(self):
        return f"<JournalEntry {self.id} {self.entry_date}>"


class JournalLine(db.Model):
    __tablename__ = "journal_lines"

    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    journal_entry_id = db.Column(db.String(36), db.ForeignKey("journal_entries.id"), nullable=False)
    account_id = db.Column(db.String(36), db.ForeignKey("accounts.id"), nullable=False)

    debit = db.Column(db.Numeric(14, 2), default=0, nullable=False)
    credit = db.Column(db.Numeric(14, 2), default=0, nullable=False)
    memo = db.Column(db.String(255), nullable=True)

    journal_entry = db.relationship("JournalEntry", back_populates="lines")
    account = db.relationship("Account", back_populates="lines")
