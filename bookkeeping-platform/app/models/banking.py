import uuid
from datetime import datetime
from app.extensions import db

STATUS_UNMATCHED = "unmatched"
STATUS_MATCHED = "matched"
STATUS_IGNORED = "ignored"


def gen_uuid():
    return str(uuid.uuid4())


class ImportedBankTransaction(db.Model):
    """A single row imported from a bank/credit-card statement (CSV today;
    an Open Banking feed in a later phase would populate the same table).
    Positive amount = money in, negative = money out. Never edited in place
    once matched — matching links it to the journal entry that resulted."""

    __tablename__ = "imported_bank_transactions"

    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    business_id = db.Column(db.String(36), db.ForeignKey("businesses.id"), nullable=False)
    bank_account_id = db.Column(db.String(36), db.ForeignKey("accounts.id"), nullable=False)

    transaction_date = db.Column(db.Date, nullable=False)
    description = db.Column(db.String(500), nullable=False)
    amount = db.Column(db.Numeric(14, 2), nullable=False)

    status = db.Column(db.String(20), nullable=False, default=STATUS_UNMATCHED)
    matched_journal_entry_id = db.Column(db.String(36), db.ForeignKey("journal_entries.id"), nullable=True)

    import_batch_id = db.Column(db.String(36), nullable=True)
    raw_row = db.Column(db.Text, nullable=True)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    bank_account = db.relationship("Account")
