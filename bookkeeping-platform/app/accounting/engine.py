"""The accounting engine: the ONLY supported way to post financial records.

Rule: journal entries are never created directly against the DB session by
route/business logic. Everything goes through `post_journal_entry` so that
double-entry balance is enforced in one place, and through `void_journal_entry`
so reconciled/void state changes are auditable, never silent deletes.
"""
from datetime import date
from decimal import Decimal, InvalidOperation
from app.extensions import db
from app.models.accounting import JournalEntry, JournalLine, Account
from app.models.audit import record_audit


class UnbalancedEntryError(Exception):
    pass


class InvalidLineError(Exception):
    pass


def post_journal_entry(
    business_id,
    entry_date,
    lines,
    description=None,
    reference=None,
    source_type="manual",
    source_id=None,
    created_by_id=None,
):
    """Create and persist a balanced journal entry.

    `lines` is a list of dicts: {"account_id": str, "debit": Decimal|float,
    "credit": Decimal|float, "memo": str (optional)}.

    Raises UnbalancedEntryError if total debits != total credits.
    Raises InvalidLineError if a line references an unknown/foreign account,
    is negative, or has both a debit and credit on the same line.
    """
    if len(lines) < 2:
        raise InvalidLineError("A journal entry needs at least two lines.")

    total_debit = Decimal("0")
    total_credit = Decimal("0")
    prepared = []

    for raw in lines:
        try:
            debit = Decimal(str(raw.get("debit", 0) or 0))
            credit = Decimal(str(raw.get("credit", 0) or 0))
        except InvalidOperation:
            raise InvalidLineError("Debit/credit must be numeric.")

        if debit < 0 or credit < 0:
            raise InvalidLineError("Debit/credit amounts cannot be negative.")
        if debit > 0 and credit > 0:
            raise InvalidLineError("A single line cannot have both a debit and a credit.")
        if debit == 0 and credit == 0:
            raise InvalidLineError("A line must have a nonzero debit or credit.")

        account = Account.query.get(raw["account_id"])
        if account is None or account.business_id != business_id:
            raise InvalidLineError("Line references an account outside this business.")

        total_debit += debit
        total_credit += credit
        prepared.append((account, debit, credit, raw.get("memo")))

    if round(total_debit - total_credit, 2) != 0:
        raise UnbalancedEntryError(
            f"Entry does not balance: debits={total_debit} credits={total_credit}"
        )

    entry = JournalEntry(
        business_id=business_id,
        entry_date=entry_date or date.today(),
        description=description,
        reference=reference,
        source_type=source_type,
        source_id=source_id,
        created_by_id=created_by_id,
    )
    db.session.add(entry)
    db.session.flush()  # get entry.id

    for account, debit, credit, memo in prepared:
        db.session.add(
            JournalLine(
                journal_entry_id=entry.id,
                account_id=account.id,
                debit=debit,
                credit=credit,
                memo=memo,
            )
        )

    record_audit(
        business_id=business_id,
        action="journal_entry.posted",
        entity_type="JournalEntry",
        entity_id=entry.id,
        new_value={
            "entry_date": str(entry.entry_date),
            "description": description,
            "source_type": source_type,
            "lines": [
                {"account_id": a.id, "debit": str(d), "credit": str(c)}
                for a, d, c, _m in prepared
            ],
        },
        user_id=created_by_id,
    )
    db.session.commit()
    return entry


def void_journal_entry(entry, reason=None):
    """Marks an entry void rather than deleting it. History is preserved."""
    if entry.is_void:
        return entry
    previous_state = {"is_void": False, "description": entry.description}
    entry.is_void = True
    if reason:
        entry.description = f"{entry.description or ''} [VOIDED: {reason}]".strip()
    record_audit(
        business_id=entry.business_id,
        action="journal_entry.voided",
        entity_type="JournalEntry",
        entity_id=entry.id,
        previous_value=previous_state,
        new_value={"is_void": True, "reason": reason},
    )
    db.session.commit()
    return entry


def trial_balance(business_id):
    """Returns a list of (account, balance) for every non-archived account."""
    accounts = Account.query.filter_by(business_id=business_id, is_archived=False).order_by(Account.code).all()
    return [(a, a.balance()) for a in accounts]
