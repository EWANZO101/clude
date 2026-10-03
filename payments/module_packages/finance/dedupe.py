"""Cross-source duplicate transaction detection and removal.

`dedupe_hash` (CSV import, see csv_import.py) and `external_transaction_id`
(bank sync, see routes.py:_import_monzo_transactions) each prevent duplicates
*within their own import path* -- reliably. Neither catches the same
real-world purchase entered once via a CSV import and once via bank sync
(or manually, then imported again): the two paths compute unrelated keys, so
nothing today notices they're the same payment. That cross-source case is
what this module targets.

IMPORTANT safety constraint, found by testing this against a real account
before it ever ran for real: two `bank_sync` transactions must NEVER be
merged with each other, even when they share an account/date/amount. Each
carries a distinct, provider-issued `external_transaction_id` -- by
definition two different ids are two different real ledger events, not a
duplicate -- and Monzo pot transfers/round-ups routinely produce several
genuinely separate transactions with the exact same amount on the exact same
day. A same-account/date/amount match is only treated as a candidate
duplicate when at least one side is NOT bank-synced (i.e. could plausibly be
the same payment entered twice via two different paths), and even then only
when the descriptions are a close match -- otherwise it's left flagged for a
human to look at rather than auto-deleted.
"""
import re

from app.core.events.bus import emit
from app.extensions import db
from .models import FinanceTransaction


def _normalize(text):
    return re.sub(r"\s+", " ", (text or "").strip().lower())


def _same_payment(a, b):
    """Would a reasonable person call these the same real payment? Exact
    normalized match, or one description contains the other (CSV exports
    routinely truncate/pad merchant names compared to a bank's own copy)."""
    na, nb = _normalize(a.clean_description or a.raw_description), _normalize(b.clean_description or b.raw_description)
    if not na or not nb:
        return False
    return na == nb or na in nb or nb in na


def find_and_remove_duplicates(user_id):
    """Scans a user's transactions for cross-source duplicates and deletes
    the extras, keeping one row per real payment. Returns a report:
      removed: [{id, date, description, amount_minor, source, kept_id}, ...]
      flagged: [{account_id, date, amount_minor, count, reason}, ...] --
        groups that collided on account/date/amount but weren't safe to
        auto-resolve, left for manual review.
    """
    txns = (
        FinanceTransaction.query
        .filter_by(user_id=user_id)
        .filter(FinanceTransaction.parent_transaction_id.is_(None))  # splits are children, not standalone dupes
        .order_by(FinanceTransaction.created_at.asc())
        .all()
    )

    groups = {}
    for t in txns:
        groups.setdefault((t.account_id, t.date, t.amount_minor), []).append(t)

    removed = []
    flagged = []

    for (account_id, txn_date, amount_minor), members in groups.items():
        if len(members) < 2:
            continue

        # Two (or more) real, distinct Monzo transactions can share an
        # account/date/amount (pot transfers, round-ups) -- their own
        # external_transaction_id already proves they're not duplicates, so
        # a bank_sync-only group is never touched.
        if all(m.import_source == "bank_sync" for m in members):
            continue

        if any(m.splits for m in members):
            flagged.append({
                "account_id": account_id, "date": txn_date.isoformat(),
                "amount_minor": amount_minor, "count": len(members), "reason": "involves a split",
            })
            continue

        # A bank-synced row is the authoritative copy when one exists;
        # otherwise keep whichever arrived first.
        keeper = next((m for m in members if m.import_source == "bank_sync"), members[0])
        others = [m for m in members if m is not keeper]

        # Only remove members whose description actually matches the
        # keeper's -- an unrelated transaction that merely happens to share
        # the account/date/amount must never be auto-deleted.
        to_remove = [m for m in others if _same_payment(m, keeper)]
        to_flag = [m for m in others if m not in to_remove]

        if to_flag:
            flagged.append({
                "account_id": account_id, "date": txn_date.isoformat(),
                "amount_minor": amount_minor, "count": len(to_flag) + 1, "reason": "description doesn't match closely enough",
            })

        for m in to_remove:
            removed.append({
                "id": m.id, "date": m.date.isoformat(),
                "description": m.clean_description or m.raw_description,
                "amount_minor": m.amount_minor, "source": m.import_source, "kept_id": keeper.id,
            })
            # Merchant links and fuel-entry back-references are loose (non-FK)
            # refs to a transaction id -- other modules clean up their own
            # tables in response to this event rather than being imported
            # directly (same loose-coupling pattern the event bus is for
            # elsewhere in this app).
            emit("transaction.deleted", user_id=user_id, transaction_id=m.id, superseded_by=keeper.id)
            db.session.delete(m)

    db.session.commit()
    return {"removed": removed, "flagged": flagged}
