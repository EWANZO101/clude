"""Merchant spending statistics. Reads FinanceTransaction from the finance
module (a sibling installed module) via MerchantTransactionLink, which
records which transaction matched which merchant. If the finance module
isn't installed, these functions degrade to empty results rather than
raising, so the merchant directory still works standalone.
"""
from datetime import date, timedelta

from dateutil.relativedelta import relativedelta

from app.extensions import db
from .models import MerchantTransactionLink, Merchant


def _finance_transaction_model():
    try:
        import importlib
        from app.core.modules.models import ModuleRecord
        finance_record = ModuleRecord.query.filter_by(id="finance", status="enabled").first()
        if not finance_record:
            return None
        return importlib.import_module("finance.models").FinanceTransaction
    except Exception:
        return None


def _linked_transactions(user_id, merchant_id=None, start=None, end=None):
    FinanceTransaction = _finance_transaction_model()
    if FinanceTransaction is None:
        return []

    query = db.session.query(FinanceTransaction).join(
        MerchantTransactionLink, MerchantTransactionLink.transaction_id == FinanceTransaction.id
    ).filter(MerchantTransactionLink.user_id == user_id, FinanceTransaction.ignored == False)  # noqa: E712

    if merchant_id:
        query = query.filter(MerchantTransactionLink.merchant_id == merchant_id)
    if start:
        query = query.filter(FinanceTransaction.date >= start)
    if end:
        query = query.filter(FinanceTransaction.date <= end)
    try:
        return query.all()
    except Exception:
        db.session.rollback()
        return []


def merchant_spending_summary(user_id, merchant_id):
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
        txns = _linked_transactions(user_id, merchant_id, start, end)
        spent = sum(abs(t.amount_minor) for t in txns if t.amount_minor < 0)
        summary[key] = spent

    all_txns = _linked_transactions(user_id, merchant_id)
    spending_txns = [t for t in all_txns if t.amount_minor < 0]
    summary["transaction_count"] = len(spending_txns)
    summary["average_minor"] = round(sum(abs(t.amount_minor) for t in spending_txns) / len(spending_txns)) if spending_txns else 0
    summary["largest_minor"] = max((abs(t.amount_minor) for t in spending_txns), default=0)
    summary["most_recent"] = max((t.date for t in all_txns), default=None)
    return summary


def merchant_monthly_history(user_id, merchant_id, months=12):
    today = date.today()
    history = []
    for i in range(months - 1, -1, -1):
        month_date = today - relativedelta(months=i)
        start = month_date.replace(day=1)
        end = (start + relativedelta(months=1)) - timedelta(days=1)
        txns = _linked_transactions(user_id, merchant_id, start, end)
        spent = sum(abs(t.amount_minor) for t in txns if t.amount_minor < 0)
        history.append({"label": month_date.strftime("%b %Y"), "spent_minor": spent})
    max_spend = max((h["spent_minor"] for h in history), default=1) or 1
    for h in history:
        h["bar_pct"] = round(h["spent_minor"] / max_spend * 100)
    return history


def top_merchants(user_id, period="this_month", limit=10):
    today = date.today()
    ranges = {
        "this_week": today - timedelta(days=today.weekday()),
        "this_month": today.replace(day=1),
        "last_month": None,  # handled separately
        "this_year": today.replace(month=1, day=1),
        "all_time": None,
    }

    if period == "last_month":
        first_of_this_month = today.replace(day=1)
        end = first_of_this_month - timedelta(days=1)
        start = end.replace(day=1)
    elif period == "all_time":
        start, end = None, None
    else:
        start = ranges.get(period, today.replace(day=1))
        end = today

    FinanceTransaction = _finance_transaction_model()
    if FinanceTransaction is None:
        return []

    query = db.session.query(
        MerchantTransactionLink.merchant_id,
        db.func.sum(db.func.abs(FinanceTransaction.amount_minor)).label("total"),
        db.func.count(FinanceTransaction.id).label("count"),
    ).join(
        FinanceTransaction, MerchantTransactionLink.transaction_id == FinanceTransaction.id
    ).filter(
        MerchantTransactionLink.user_id == user_id,
        FinanceTransaction.amount_minor < 0,
        FinanceTransaction.ignored == False,  # noqa: E712
    )
    if start:
        query = query.filter(FinanceTransaction.date >= start)
    if end:
        query = query.filter(FinanceTransaction.date <= end)

    try:
        rows = query.group_by(MerchantTransactionLink.merchant_id).order_by(db.desc("total")).limit(limit).all()
    except Exception:
        db.session.rollback()
        return []

    results = []
    for merchant_id, total, count in rows:
        merchant = db.session.get(Merchant, merchant_id)
        if merchant:
            results.append({"merchant": merchant, "total_minor": total, "transaction_count": count})
    return results
