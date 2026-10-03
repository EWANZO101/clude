"""Fuel spending statistics sourced from bank transactions that the
merchant module has matched to a fuel-station merchant (Shell/BP/Esso/etc,
already seeded in the merchant module with merchant_type='fuel_station' —
see module_packages/merchant/seed_data.py). This is the "recognition"
half of the spec requirement: we don't re-implement merchant matching
here, we reuse it via the same loose-coupling pattern the merchant module
uses to reach into finance (best-effort imports, degrade to empty on any
failure so this module works standalone if finance/merchant aren't
installed).
"""
import re
from datetime import date, timedelta

from dateutil.relativedelta import relativedelta

from app.extensions import db


def _finance_transaction_model():
    try:
        import importlib
        from app.core.modules.models import ModuleRecord
        if not ModuleRecord.query.filter_by(id="finance", status="enabled").first():
            return None
        return importlib.import_module("finance.models").FinanceTransaction
    except Exception:
        return None


def _merchant_models():
    try:
        import importlib
        from app.core.modules.models import ModuleRecord
        if not ModuleRecord.query.filter_by(id="merchant", status="enabled").first():
            return None, None
        mod = importlib.import_module("merchant.models")
        return mod.Merchant, mod.MerchantTransactionLink
    except Exception:
        return None, None


def _fuel_transactions(user_id, start=None, end=None):
    FinanceTransaction = _finance_transaction_model()
    Merchant, MerchantTransactionLink = _merchant_models()
    if not FinanceTransaction or not Merchant or not MerchantTransactionLink:
        return []

    query = db.session.query(FinanceTransaction).join(
        MerchantTransactionLink, MerchantTransactionLink.transaction_id == FinanceTransaction.id
    ).join(
        Merchant, Merchant.id == MerchantTransactionLink.merchant_id
    ).filter(
        MerchantTransactionLink.user_id == user_id,
        Merchant.merchant_type == "fuel_station",
        FinanceTransaction.ignored == False,  # noqa: E712
        FinanceTransaction.amount_minor < 0,
    )
    if start:
        query = query.filter(FinanceTransaction.date >= start)
    if end:
        query = query.filter(FinanceTransaction.date <= end)
    try:
        return query.all()
    except Exception:
        db.session.rollback()
        return []


def fuel_spending_summary(user_id):
    today = date.today()
    ranges = {
        "today": (today, today),
        "this_week": (today - timedelta(days=today.weekday()), today),
        "this_month": (today.replace(day=1), today),
        "this_year": (today.replace(month=1, day=1), today),
        "all_time": (None, None),
    }
    summary = {}
    for key, (start, end) in ranges.items():
        txns = _fuel_transactions(user_id, start, end)
        summary[key] = sum(abs(t.amount_minor) for t in txns)
    return summary


def available():
    """Whether fuel-station recognition can run at all (finance + merchant installed)."""
    return _finance_transaction_model() is not None and _merchant_models()[0] is not None


# ---- Keyword-based fuel-purchase detection ----
#
# The merchant module's alias matching classifies a description against
# ONE merchant record, first-substring-wins in seed order. Supermarkets
# (Asda, Tesco, Sainsbury's, Morrisons...) are seeded as grocery retailers,
# so a forecourt purchase like "DP ASDA FUEL MANCHESTER" matches the ASDA
# grocery alias before it'd ever reach a fuel-specific one -- merchant_type
# comes back "retailer", and _fuel_transactions() above never sees it. This
# is a second, independent detection path that looks at the raw transaction
# description directly for fuel-station brand names and generic fuel/petrol
# wording, so it catches supermarket forecourts and any other UK fuel
# station regardless of how the merchant module classified the parent
# merchant. Deliberately separate from matching.py rather than a change to
# its priority order, since re-ordering that pipeline could shift matching
# behaviour for every other module that depends on it.
UK_FUEL_KEYWORDS = [
    "ESSO", "SHELL", " BP ", "BP FUEL", "TEXACO", "GULF", "MURCO",
    "APPLEGREEN", "MOTO SERVICES", "MOTO MOTORWAY", "JET GARAGE",
    "ASDA FUEL", "ASDA PETROL", "TESCO FUEL", "TESCO PETROL",
    "SAINSBURYS FUEL", "SAINSBURYS PETROL", "MORRISONS FUEL",
    "MORRISONS PETROL", "COSTCO FUEL", "M&S FUEL",
]
UK_FUEL_WORD_PATTERN = re.compile(r"\b(FUEL|PETROL|DIESEL)\b")


def _looks_like_fuel(description):
    text = (description or "").upper()
    if any(kw in text for kw in UK_FUEL_KEYWORDS):
        return True
    return bool(UK_FUEL_WORD_PATTERN.search(text))


def detect_fuel_purchases(user_id, default_vehicle_id, lookback_months=12):
    """Scans the user's spending transactions for anything that looks like a
    UK fuel-station purchase and creates a FuelEntry for each one not
    already linked (matched by FinanceTransaction.id in FuelEntry.transaction_id,
    so this is safe to call on every page load -- already-imported ones are
    skipped). litres/odometer are left blank since a bank line never
    contains them; vehicle_summary() already excludes odometer-less entries
    from MPG/cost-per-mile while still counting their cost and (zero)
    litres, so this can't skew those averages, only the totals it's
    supposed to feed. Returns the count of entries created. No-ops
    (returns 0) if finance isn't installed or the user has no vehicle yet.
    """
    FinanceTransaction = _finance_transaction_model()
    if not FinanceTransaction or not default_vehicle_id:
        return 0

    from .models import FuelEntry

    since = date.today() - relativedelta(months=lookback_months)
    candidates = FinanceTransaction.query.filter(
        FinanceTransaction.user_id == user_id,
        FinanceTransaction.date >= since,
        FinanceTransaction.amount_minor < 0,
        FinanceTransaction.ignored == False,  # noqa: E712
    ).all()

    already_linked = {
        t for (t,) in db.session.query(FuelEntry.transaction_id).filter(
            FuelEntry.user_id == user_id, FuelEntry.transaction_id.isnot(None),
        ).all()
    }

    created = 0
    for txn in candidates:
        if txn.id in already_linked:
            continue
        description = txn.clean_description or txn.raw_description or ""
        if not _looks_like_fuel(description):
            continue

        db.session.add(FuelEntry(
            user_id=user_id, vehicle_id=default_vehicle_id, date=txn.date,
            odometer=None, litres=None, cost_minor=abs(txn.amount_minor),
            full_tank=False,  # unknown from a bank line -- excluded from MPG calc either way
            transaction_id=txn.id,
            notes=f"Auto-detected from bank transaction: {description}",
        ))
        created += 1

    if created:
        db.session.commit()
    return created
