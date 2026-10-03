"""Pulls real numbers into dashboard widget cards, per widget_key.

Each resolver returns a dict: {"value": "<big number text>", "subtitle": "<small text>"}
or None if it can't produce a value (module not installed/enabled, or the
resolver hit an error) — the template falls back to the original placeholder
in that case, so a broken/missing module never breaks the whole dashboard.
"""
import logging

from app.core.modules.models import ModuleRecord
from app.core.notifications.models import Notification

logger = logging.getLogger(__name__)


def _module_enabled(module_id):
    record = ModuleRecord.query.get(module_id)
    return bool(record and record.status == "enabled")


def _finance_bits(user_id):
    """Lazily imports the finance module (only valid once it's on sys.path,
    which the module loader guarantees by app-startup time) and returns the
    shared pieces several finance widgets need, computed once."""
    from finance import calculations as calc
    from finance.money import format_money
    from finance.models import FinanceAccount

    settings = calc.get_or_create_settings(user_id)
    currency = "GBP"
    account = FinanceAccount.query.filter_by(user_id=user_id, active=True).first()
    if account and account.currency:
        currency = account.currency
    return calc, format_money, currency, settings


def widget_current_balance(user_id):
    calc, format_money, currency, _ = _finance_bits(user_id)
    forecast = calc.financial_forecast(user_id)
    return {
        "value": format_money(forecast["current_balance_minor"], currency),
        "subtitle": "Across all active accounts",
    }


def widget_available_money(user_id):
    calc, format_money, currency, _ = _finance_bits(user_id)
    safe = calc.safe_discretionary_money(user_id)
    return {
        "value": format_money(safe["safe_discretionary_minor"], currency),
        "subtitle": "After bills, subscriptions and your safe balance",
    }


def widget_monthly_income(user_id):
    calc, format_money, currency, _ = _finance_bits(user_id)
    forecast = calc.financial_forecast(user_id)
    return {
        "value": format_money(forecast["projected_income_minor"], currency),
        "subtitle": "Projected this month",
    }


def widget_monthly_spending(user_id):
    calc, format_money, currency, _ = _finance_bits(user_id)
    forecast = calc.financial_forecast(user_id)
    return {
        "value": format_money(forecast["projected_spending_minor"], currency),
        "subtitle": "Projected this month",
    }


def widget_upcoming_bills(user_id):
    calc, format_money, currency, _ = _finance_bits(user_id)
    safe = calc.safe_discretionary_money(user_id)
    return {
        "value": format_money(safe["upcoming_bills_minor"], currency),
        "subtitle": "Due within 30 days",
    }


def widget_budgets(user_id):
    from finance.models import FinanceBudget

    budgets = FinanceBudget.query.filter_by(user_id=user_id).all()
    if not budgets:
        return {"value": "0", "subtitle": "No budgets set up yet"}

    calc, _, _, _ = _finance_bits(user_id)
    over = sum(1 for b in budgets if calc.budget_status(user_id, b)["over_budget"])
    return {
        "value": str(len(budgets)),
        "subtitle": f"{over} over budget" if over else "All on track this month",
    }


def widget_recent_transactions(user_id):
    from finance.models import FinanceTransaction

    count = FinanceTransaction.query.filter_by(user_id=user_id, ignored=False).count()
    return {"value": str(count), "subtitle": "Total transactions logged"}


def widget_checklist_progress(user_id):
    from checklist.models import ChecklistList

    lists = ChecklistList.query.filter_by(user_id=user_id, archived=False).all()
    if not lists:
        return {"value": "—", "subtitle": "No active checklists"}
    avg = round(sum(l.progress for l in lists) / len(lists))
    return {"value": f"{avg}%", "subtitle": f"Across {len(lists)} active checklist(s)"}


def widget_notifications(user_id):
    unread = Notification.query.filter_by(user_id=user_id, read=False).count()
    return {"value": str(unread), "subtitle": "Unread"}


def widget_spending_chart(user_id):
    from finance.models import FinanceTransaction
    from finance.money import format_money
    from finance import calculations as calc
    from app.extensions import db

    start, end = calc.month_bounds()
    top = (
        db.session.query(
            FinanceTransaction.category_id,
            db.func.sum(FinanceTransaction.amount_minor).label("total"),
        )
        .filter(
            FinanceTransaction.user_id == user_id,
            FinanceTransaction.date >= start, FinanceTransaction.date <= end,
            FinanceTransaction.amount_minor < 0, FinanceTransaction.ignored == False,  # noqa: E712
        )
        .group_by(FinanceTransaction.category_id)
        .order_by(db.asc("total"))
        .first()
    )
    if not top:
        return {"value": "—", "subtitle": "No spending logged this month"}

    from finance.models import FinanceCategory
    category = FinanceCategory.query.get(top.category_id) if top.category_id else None
    _, _, currency, _ = _finance_bits(user_id)
    return {
        "value": format_money(abs(top.total), currency),
        "subtitle": f"Top category this month: {category.name if category else 'Uncategorised'}",
    }


# widget_key -> (resolver, required module_id or None if always available)
WIDGET_RESOLVERS = {
    "current_balance": (widget_current_balance, "finance"),
    "available_money": (widget_available_money, "finance"),
    "monthly_income": (widget_monthly_income, "finance"),
    "monthly_spending": (widget_monthly_spending, "finance"),
    "upcoming_bills": (widget_upcoming_bills, "finance"),
    "budgets": (widget_budgets, "finance"),
    "recent_transactions": (widget_recent_transactions, "finance"),
    "checklist_progress": (widget_checklist_progress, "checklist"),
    "notifications": (widget_notifications, None),
    "spending_chart": (widget_spending_chart, "finance"),
}


def resolve_widget(widget_key, user_id):
    """Returns {"value", "subtitle"} or None to keep the placeholder."""
    entry = WIDGET_RESOLVERS.get(widget_key)
    if not entry:
        return None
    resolver, required_module = entry
    if required_module and not _module_enabled(required_module):
        return None
    try:
        return resolver(user_id)
    except Exception:
        logger.exception("Dashboard widget '%s' failed to resolve for user %s", widget_key, user_id)
        return None
