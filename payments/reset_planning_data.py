"""
Scoped reset: clears "monthly payments"-style finance planning data (bills,
subscriptions, recurring payments, debts + their schedules, budgets, savings
goals, planned purchases, monthly plan items) plus fuel and checklist data,
while leaving the connected bank account/connection, actual transaction
history, categories/category rules, merchant links, and settings untouched.

This is a narrower, purpose-built alternative to wipe_app_data.py (which
also deletes finance_accounts/finance_bank_connections -- i.e. disconnects
the bank -- and finance_transactions, neither of which is wanted here).

ALWAYS back up the db file first:
    cp /root/payments/app.db /root/payments/app.db.bak-$(date +%s)

Run from the project root:
    cd /root/payments && source .venv/bin/activate
    python reset_planning_data.py           # live run
    DATABASE_URL=sqlite:///path/to/copy.db python reset_planning_data.py   # dry run against a copy
"""
from app import create_app
from app.extensions import db
from sqlalchemy import text

app = create_app()

# Order matters: children before parents.
TABLES_TO_CLEAR = [
    # finance "monthly payments" / planning data
    "finance_debt_payments",
    "finance_debts",
    "finance_bills",
    "finance_subscriptions",
    "finance_recurring_payments",
    "finance_budgets",
    "finance_savings_goals",
    "finance_planned_purchases",
    "finance_monthly_plan_items",
    # fuel
    "fuel_entries",
    "fuel_vehicles",
    # checklist
    "checklist_task_tags",
    "checklist_tags",
    "checklist_tasks",
    "checklist_lists",
]

KEPT = [
    "finance_accounts", "finance_bank_connections", "finance_transactions",
    "finance_categories", "finance_category_rules", "finance_settings",
    "finance_import_batches", "merchant_transaction_links", "merchant_user_mappings",
    "users", "notifications",
]

with app.app_context():
    total = 0
    for table in TABLES_TO_CLEAR:
        result = db.session.execute(text(f"DELETE FROM {table}"))
        print(f"{table}: {result.rowcount} rows deleted")
        total += result.rowcount or 0

    db.session.commit()
    print(f"\nDone. {total} total rows deleted.")
    print("Left untouched: " + ", ".join(KEPT))
