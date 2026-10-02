"""Calculations for budgets, safe balance, forecast, recurring payment
detection and money-saving suggestions. Kept separate from routes.py so the
logic is independently testable.
"""
import re
from collections import defaultdict
from datetime import date, timedelta

from dateutil.relativedelta import relativedelta

from app.extensions import db
from .models import (
    FinanceTransaction, FinanceBudget, FinanceBill, FinanceSubscription,
    FinanceRecurringPayment, FinancePlannedPurchase, FinanceSettings, FinanceAccount,
    FinanceMonthlyPlanItem, FinanceDebt,
)


def month_bounds(for_date=None):
    d = for_date or date.today()
    start = d.replace(day=1)
    end = (start + relativedelta(months=1)) - timedelta(days=1)
    return start, end


def get_or_create_settings(user_id):
    settings = FinanceSettings.query.filter_by(user_id=user_id).first()
    if not settings:
        settings = FinanceSettings(user_id=user_id)
        db.session.add(settings)
        db.session.commit()
    return settings


# ---- Budgets ----

def budget_status(user_id, budget, for_date=None):
    start, end = month_bounds(for_date)
    spent = db.session.query(db.func.coalesce(db.func.sum(FinanceTransaction.amount_minor), 0)).filter(
        FinanceTransaction.user_id == user_id,
        FinanceTransaction.category_id == budget.category_id,
        FinanceTransaction.date >= start, FinanceTransaction.date <= end,
        FinanceTransaction.amount_minor < 0,
        FinanceTransaction.ignored == False,  # noqa: E712
    ).scalar()
    spent_minor = abs(spent or 0)
    remaining = budget.amount_minor - spent_minor
    pct_used = round(spent_minor / budget.amount_minor * 100) if budget.amount_minor else 0

    days_in_month = (end - start).days + 1
    days_elapsed = min((date.today() - start).days + 1, days_in_month)
    days_elapsed = max(days_elapsed, 1)
    daily_rate = spent_minor / days_elapsed
    forecast_minor = round(daily_rate * days_in_month)

    return {
        "spent_minor": spent_minor, "remaining_minor": remaining, "pct_used": pct_used,
        "forecast_minor": forecast_minor, "over_warning": pct_used >= budget.warning_threshold_pct,
        "over_budget": spent_minor > budget.amount_minor,
    }


# ---- Safe balance / planned purchases ----

def safe_discretionary_money(user_id):
    settings = get_or_create_settings(user_id)
    accounts = FinanceAccount.query.filter_by(user_id=user_id, active=True).all()
    current_money = sum(a.balance_minor for a in accounts)

    today = date.today()
    horizon = today + relativedelta(months=1)

    upcoming_bills = FinanceBill.query.filter(
        FinanceBill.user_id == user_id, FinanceBill.active == True,  # noqa: E712
        FinanceBill.next_due_date.isnot(None), FinanceBill.next_due_date <= horizon,
    ).all()
    upcoming_bills_minor = sum(b.amount_minor for b in upcoming_bills)

    upcoming_subs = FinanceSubscription.query.filter(
        FinanceSubscription.user_id == user_id, FinanceSubscription.status == "active",
        FinanceSubscription.next_payment_date.isnot(None), FinanceSubscription.next_payment_date <= horizon,
    ).all()
    upcoming_subs_minor = sum(s.amount_minor for s in upcoming_subs)

    planned_purchases = FinancePlannedPurchase.query.filter_by(user_id=user_id, purchased=False).all()
    planned_minor = sum(p.total_price_minor for p in planned_purchases)

    active_debts = FinanceDebt.query.filter_by(user_id=user_id, settled=False).all()
    debt_payments_minor = sum(d.monthly_equivalent_minor for d in active_debts)

    safe_minor = (
        current_money - upcoming_bills_minor - upcoming_subs_minor
        - planned_minor - debt_payments_minor - settings.minimum_safe_balance_minor
    )

    return {
        "current_money_minor": current_money,
        "upcoming_bills_minor": upcoming_bills_minor,
        "upcoming_subscriptions_minor": upcoming_subs_minor,
        "planned_purchases_minor": planned_minor,
        "debt_payments_minor": debt_payments_minor,
        "minimum_safe_balance_minor": settings.minimum_safe_balance_minor,
        "safe_discretionary_minor": safe_minor,
    }


# ---- Debts ----

def total_debt_owed(user_id):
    """Sum of everything still owed across all active (not settled) debts --
    the headline number for the debts page."""
    active_debts = FinanceDebt.query.filter_by(user_id=user_id, settled=False).all()
    return sum(d.remaining_minor for d in active_debts)


# ---- Monthly planning ----

def monthly_plan_impact(user_id, month):
    """month: a date, normalised internally to the 1st of that month.

    Answers two things: (1) how much is left after everything already
    committed (bills/subscriptions/other planned purchases, via
    safe_discretionary_money) AND this month\'s specific planned spends, and
    (2) whether any recurring payment actually paid in the last 2 months
    (i.e. a real, active commitment -- not just detected-but-unconfirmed)
    would no longer be affordable once this month\'s planned spending is
    accounted for.
    """
    month_start = month.replace(day=1)

    items = FinanceMonthlyPlanItem.query.filter_by(user_id=user_id, month=month_start).order_by(
        FinanceMonthlyPlanItem.created_at
    ).all()
    planned_total_minor = sum(i.amount_minor for i in items)

    safe = safe_discretionary_money(user_id)
    remaining_after_plan_minor = safe["safe_discretionary_minor"] - planned_total_minor

    two_months_ago = date.today() - relativedelta(months=2)
    active_recurring = FinanceRecurringPayment.query.filter(
        FinanceRecurringPayment.user_id == user_id,
        FinanceRecurringPayment.status == "confirmed",
        FinanceRecurringPayment.last_payment_date.isnot(None),
        FinanceRecurringPayment.last_payment_date >= two_months_ago,
    ).all()

    at_risk = []
    for r in active_recurring:
        if remaining_after_plan_minor < r.amount_minor:
            at_risk.append({
                "name": r.display_name or r.merchant_key,
                "amount_minor": r.amount_minor,
                "shortfall_minor": r.amount_minor - remaining_after_plan_minor,
                "next_payment_date": r.next_payment_date,
            })

    return {
        "month": month_start,
        "items": items,
        "planned_total_minor": planned_total_minor,
        "safe_before_plan_minor": safe["safe_discretionary_minor"],
        "remaining_after_plan_minor": remaining_after_plan_minor,
        "at_risk_recurring": at_risk,
    }


# ---- Financial forecast ----

def financial_forecast(user_id):
    start, end = month_bounds()
    accounts = FinanceAccount.query.filter_by(user_id=user_id, active=True).all()
    current_balance = sum(a.balance_minor for a in accounts)

    spent_so_far = db.session.query(db.func.coalesce(db.func.sum(FinanceTransaction.amount_minor), 0)).filter(
        FinanceTransaction.user_id == user_id, FinanceTransaction.date >= start,
        FinanceTransaction.date <= date.today(), FinanceTransaction.amount_minor < 0,
        FinanceTransaction.ignored == False,  # noqa: E712
    ).scalar() or 0

    income_so_far = db.session.query(db.func.coalesce(db.func.sum(FinanceTransaction.amount_minor), 0)).filter(
        FinanceTransaction.user_id == user_id, FinanceTransaction.date >= start,
        FinanceTransaction.date <= date.today(), FinanceTransaction.amount_minor > 0,
        FinanceTransaction.ignored == False,  # noqa: E712
    ).scalar() or 0

    days_in_month = (end - start).days + 1
    days_elapsed = max((date.today() - start).days + 1, 1)

    projected_spending = round(abs(spent_so_far) / days_elapsed * days_in_month)
    projected_income = round(income_so_far / days_elapsed * days_in_month)

    upcoming_bills = db.session.query(db.func.coalesce(db.func.sum(FinanceBill.amount_minor), 0)).filter(
        FinanceBill.user_id == user_id, FinanceBill.active == True,  # noqa: E712
        FinanceBill.next_due_date.isnot(None), FinanceBill.next_due_date <= end,
    ).scalar() or 0

    projected_end_of_month_balance = current_balance - projected_spending + projected_income

    return {
        "current_balance_minor": current_balance,
        "projected_spending_minor": projected_spending,
        "projected_income_minor": projected_income,
        "projected_savings_minor": projected_income - projected_spending,
        "upcoming_bills_minor": upcoming_bills,
        "projected_end_of_month_balance_minor": projected_end_of_month_balance,
        "based_on": (
            f"{days_elapsed} of {days_in_month} days this month, projected forward at the "
            "same daily rate, plus known upcoming bills."
        ),
    }


# ---- Recurring payment detection ----

def _normalise_merchant_key(description):
    text = (description or "").lower()
    text = re.sub(r"\d{4,}", "", text)  # strip long reference numbers
    text = re.sub(r"[^a-z0-9 ]", " ", text)
    text = re.sub(r"\s+", " ", text).strip()
    return text[:100]


def detect_recurring_payments(user_id, lookback_months=6):
    """Groups spending transactions by normalised description + amount; if the
    same pair appears in at least 2 distinct months, records/updates a
    FinanceRecurringPayment suggestion at status='detected' (unless the user
    already confirmed or ignored it)."""
    since = date.today() - relativedelta(months=lookback_months)
    transactions = FinanceTransaction.query.filter(
        FinanceTransaction.user_id == user_id, FinanceTransaction.date >= since,
        FinanceTransaction.amount_minor < 0, FinanceTransaction.ignored == False,  # noqa: E712
    ).all()

    groups = defaultdict(list)
    for txn in transactions:
        key = (_normalise_merchant_key(txn.clean_description or txn.raw_description), txn.amount_minor)
        groups[key].append(txn)

    found = []
    for (merchant_key, amount_minor), txns in groups.items():
        months = {(t.date.year, t.date.month) for t in txns}
        if len(months) < 2 or not merchant_key:
            continue

        txns.sort(key=lambda t: t.date)
        last_txn = txns[-1]
        next_date = last_txn.date + relativedelta(months=1)

        existing = FinanceRecurringPayment.query.filter_by(
            user_id=user_id, merchant_key=merchant_key, amount_minor=amount_minor
        ).first()
        if existing:
            if existing.status not in ("ignored", "cancelled"):
                existing.last_payment_date = last_txn.date
                existing.next_payment_date = next_date
        else:
            existing = FinanceRecurringPayment(
                user_id=user_id, merchant_key=merchant_key,
                display_name=last_txn.clean_description or last_txn.raw_description,
                amount_minor=amount_minor, last_payment_date=last_txn.date,
                next_payment_date=next_date, category_id=last_txn.category_id,
            )
            db.session.add(existing)
        found.append(existing)

    db.session.commit()
    return found


# ---- Money-saving suggestions ----

def money_saving_suggestions(user_id):
    """Lightweight, clearly-labelled suggestions based on month-on-month and
    3-month-average comparisons. Not guaranteed financial advice."""
    this_start, this_end = month_bounds()
    last_start, last_end = month_bounds(this_start - timedelta(days=1))

    def spend_in_range(start, end):
        return abs(db.session.query(db.func.coalesce(db.func.sum(FinanceTransaction.amount_minor), 0)).filter(
            FinanceTransaction.user_id == user_id, FinanceTransaction.date >= start,
            FinanceTransaction.date <= end, FinanceTransaction.amount_minor < 0,
            FinanceTransaction.ignored == False,  # noqa: E712
        ).scalar() or 0)

    this_month_spend = spend_in_range(this_start, date.today())
    last_month_spend = spend_in_range(last_start, last_end)

    suggestions = []
    if last_month_spend and this_month_spend > last_month_spend * 1.15:
        increase_pct = round((this_month_spend / last_month_spend - 1) * 100)
        suggestions.append({
            "title": "Spending is up compared to last month",
            "detail": f"You've spent about {increase_pct}% more so far this month than last month.",
        })

    subs_total = db.session.query(db.func.coalesce(db.func.sum(FinanceSubscription.amount_minor), 0)).filter_by(
        user_id=user_id, status="active"
    ).scalar() or 0
    if subs_total > 0:
        suggestions.append({
            "title": "Active subscriptions",
            "detail": f"You have active subscriptions totalling {subs_total / 100:.2f}/month — worth a quick review.",
        })

    return suggestions


# ---- Everything due, and missed-payment detection ----

def everything_due(user_id):
    bills = FinanceBill.query.filter_by(user_id=user_id, active=True).order_by(
        FinanceBill.next_due_date
    ).all()
    subscriptions = FinanceSubscription.query.filter_by(user_id=user_id, status="active").order_by(
        FinanceSubscription.next_payment_date
    ).all()
    debts = FinanceDebt.query.filter_by(user_id=user_id, settled=False).order_by(
        FinanceDebt.next_payment_date
    ).all()

    total_next_payments_minor = (
        sum(b.amount_minor for b in bills)
        + sum(s.amount_minor for s in subscriptions)
        + sum(d.monthly_payment_minor for d in debts)
    )

    safe = safe_discretionary_money(user_id)

    return {
        "bills": bills,
        "subscriptions": subscriptions,
        "debts": debts,
        "total_next_payments_minor": total_next_payments_minor,
        "left_after_everything_minor": safe["safe_discretionary_minor"],
    }


def missed_payments(user_id, grace_days=3, amount_tolerance_pct=10):
    today = date.today()
    cutoff = today - timedelta(days=grace_days)
    results = []

    def _has_matching_transaction(expected_amount_minor, due_date):
        window_start = due_date - timedelta(days=7)
        window_end = min(today, due_date + timedelta(days=14))
        low = expected_amount_minor * (1 - amount_tolerance_pct / 100)
        high = expected_amount_minor * (1 + amount_tolerance_pct / 100)
        match = FinanceTransaction.query.filter(
            FinanceTransaction.user_id == user_id,
            FinanceTransaction.date >= window_start, FinanceTransaction.date <= window_end,
            FinanceTransaction.amount_minor < 0,
            FinanceTransaction.ignored == False,
            db.func.abs(FinanceTransaction.amount_minor) >= low,
            db.func.abs(FinanceTransaction.amount_minor) <= high,
        ).first()
        return match is not None

    bills = FinanceBill.query.filter_by(user_id=user_id, active=True).filter(
        FinanceBill.next_due_date.isnot(None), FinanceBill.next_due_date <= cutoff,
    ).all()
    for b in bills:
        if not _has_matching_transaction(b.amount_minor, b.next_due_date):
            results.append({
                "kind": "bill", "name": b.name, "amount_minor": b.amount_minor,
                "due_date": b.next_due_date, "days_overdue": (today - b.next_due_date).days,
            })

    subs = FinanceSubscription.query.filter_by(user_id=user_id, status="active").filter(
        FinanceSubscription.next_payment_date.isnot(None), FinanceSubscription.next_payment_date <= cutoff,
    ).all()
    for s in subs:
        if not _has_matching_transaction(s.amount_minor, s.next_payment_date):
            results.append({
                "kind": "subscription", "name": s.name, "amount_minor": s.amount_minor,
                "due_date": s.next_payment_date, "days_overdue": (today - s.next_payment_date).days,
            })

    results.sort(key=lambda r: r["due_date"])
    return results
