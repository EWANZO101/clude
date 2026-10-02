"""Credit ledger operations. Two rules, always:

1. CompanyCreditAccount.balance is NEVER assigned directly — only ever updated by the
   atomic conditional UPDATE here, in the same transaction as the CreditLedger insert
   that explains the change. That's what keeps the cached balance and the audit trail
   from drifting apart.
2. Every grant/reset that could plausibly be delivered more than once (renewals,
   webhook-driven grants) must pass a stable `source_event_id` so the
   (company_id, source_type, source_event_id) unique constraint on CreditLedger can
   catch a duplicate before it double-grants. Manual admin actions and usage-spend
   don't repeat, so a random token is fine for them — the constraint just becomes
   bookkeeping.

None of these functions commit — they only flush (so a bad insert raises immediately,
not silently at some later unrelated commit) and leave the transaction open. That's
deliberate: a webhook handler calls these as ONE step among several (create a
subscription row, THEN grant its first period's credits, say) and the whole thing must
land or roll back together. Callers commit; on IntegrityError (a real duplicate — the
unique constraint fired), the caller should roll back and treat it as already-done,
not as a failure.
"""
import uuid

from ..extensions import db
from ..models import CompanyCreditAccount, CreditLedger, CreditUsageRule


class InsufficientCredits(Exception):
    pass


def _get_or_create_account(company_id):
    account = db.session.get(CompanyCreditAccount, company_id)
    if not account:
        account = CompanyCreditAccount(company_id=company_id, balance=0)
        db.session.add(account)
        db.session.flush()
    return account


def grant(company_id, amount, reason, source_type, source_event_id=None):
    """Add credits (renewal, purchase, manual top-up, bonus). Returns the new balance.
    Caller commits; an IntegrityError on flush means this exact
    (company, source_type, source_event_id) was already recorded — roll back and treat
    as a no-op, don't re-raise as a failure."""
    if amount <= 0:
        raise ValueError('grant() amount must be positive — use spend() instead')

    source_event_id = source_event_id or uuid.uuid4().hex
    _get_or_create_account(company_id)

    # Atomic increment (balance = balance + amount, done in SQL, not read-then-write
    # in Python) — same reasoning as spend()'s conditional decrement below, just
    # without a WHERE guard since grants can't fail on balance.
    result = db.session.execute(
        db.update(CompanyCreditAccount)
        .where(CompanyCreditAccount.company_id == company_id)
        .values(balance=CompanyCreditAccount.balance + amount)
        .returning(CompanyCreditAccount.balance)
    )
    new_balance = result.scalar_one()

    db.session.add(CreditLedger(
        company_id=company_id, delta=amount, reason=reason, balance_after=new_balance,
        source_type=source_type, source_event_id=source_event_id,
    ))
    db.session.flush()
    return new_balance


def reset_to(company_id, target, reason, source_type, source_event_id=None):
    """Set the balance to an exact value — used for renewal resets (non-rollover
    credits: whatever was left over from the previous period is discarded, matching
    "credits reset monthly/yearly"), not for grants/spends. Overwrites unconditionally
    (a renewal reset should win over a concurrent spend, not race with it), but the
    (company_id, source_type, source_event_id) unique constraint still makes a specific
    renewal idempotent — see module docstring for how callers should handle that."""
    if target < 0:
        raise ValueError('reset_to() target must be >= 0')

    _get_or_create_account(company_id)
    source_event_id = source_event_id or uuid.uuid4().hex

    prior = db.session.query(CompanyCreditAccount.balance).filter_by(company_id=company_id).scalar() or 0

    result = db.session.execute(
        db.update(CompanyCreditAccount)
        .where(CompanyCreditAccount.company_id == company_id)
        .values(balance=target)
        .returning(CompanyCreditAccount.balance)
    )
    new_balance = result.scalar_one()

    db.session.add(CreditLedger(
        company_id=company_id, delta=new_balance - prior, reason=reason, balance_after=new_balance,
        source_type=source_type, source_event_id=source_event_id,
    ))
    db.session.flush()
    return new_balance


def spend(company_id, amount, reason, source_type='usage', source_event_id=None):
    """Atomically deduct credits. Raises InsufficientCredits without changing anything
    if the balance is too low — no explicit row lock needed, the conditional UPDATE's
    WHERE clause is the guard (Postgres MVCC handles the rest). This one really can fail
    as a normal, expected outcome (not just a duplicate-delivery edge case), so it's a
    dedicated exception rather than relying on IntegrityError."""
    if amount <= 0:
        raise ValueError('spend() amount must be positive')

    _get_or_create_account(company_id)
    source_event_id = source_event_id or uuid.uuid4().hex

    result = db.session.execute(
        db.update(CompanyCreditAccount)
        .where(CompanyCreditAccount.company_id == company_id,
               CompanyCreditAccount.balance >= amount)
        .values(balance=CompanyCreditAccount.balance - amount)
        .returning(CompanyCreditAccount.balance)
    )
    row = result.first()
    if row is None:
        raise InsufficientCredits(f'company {company_id} has insufficient credits for {amount}')

    new_balance = row[0]
    db.session.add(CreditLedger(
        company_id=company_id, delta=-amount, reason=reason, balance_after=new_balance,
        source_type=source_type, source_event_id=source_event_id,
    ))
    db.session.flush()
    return new_balance


def spend_for_feature(company_id, feature_key, reason=None):
    """Look up the cost from CreditUsageRule (default 1 if no rule is configured for
    this feature) and spend it. Returns the new balance."""
    rule = CreditUsageRule.query.filter_by(feature_key=feature_key).first()
    cost = rule.credits_cost if rule else 1
    return spend(company_id, cost, reason or f'used feature: {feature_key}',
                 source_type='usage')
