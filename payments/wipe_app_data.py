"""
Wipes all per-user app data (finance, checklist, fuel, merchant links,
notifications) while keeping user accounts/logins and shared reference
data (system default finance categories, merchant company/brand directory)
intact.

Run from the project root:
    cd /root/payments
    source .venv/bin/activate
    python /tmp/wipe_app_data.py

ALWAYS back up the db file first:
    cp /root/payments/app.db /root/payments/app.db.bak-$(date +%s)
"""
from app import create_app
from app.extensions import db
from sqlalchemy import text

app = create_app()

# Order matters where foreign keys point child -> parent; deleting children
# first avoids relying on cascade behaviour that may not be configured.
TABLES_TO_CLEAR = [
    # finance — per-user
    "finance_recurring_payments",
    "finance_planned_purchases",
    "finance_savings_goals",
    "finance_subscriptions",
    "finance_bills",
    "finance_budgets",
    "finance_import_batches",
    "finance_transactions",
    "finance_category_rules",
    "finance_accounts",
    "finance_bank_connections",
    "finance_settings",
    # checklist — per-user
    "checklist_task_tags",
    "checklist_tags",
    "checklist_tasks",
    "checklist_lists",
    # merchant — only the per-user link tables, NOT the shared company/brand directory
    "merchant_transaction_links",
    "merchant_user_mappings",
    # fuel — per-user
    "fuel_entries",
    "fuel_vehicles",
    # notifications — generated app data
    "notifications",
]

# finance_categories has user_id nullable — null rows are system defaults,
# shared across all users, and must survive. Only user-created ones go.
CONDITIONAL_DELETES = [
    ("finance_categories", "user_id IS NOT NULL"),
]

with app.app_context():
    total = 0
    for table in TABLES_TO_CLEAR:
        result = db.session.execute(text(f"DELETE FROM {table}"))
        print(f"{table}: {result.rowcount} rows deleted")
        total += result.rowcount or 0

    for table, condition in CONDITIONAL_DELETES:
        result = db.session.execute(text(f"DELETE FROM {table} WHERE {condition}"))
        print(f"{table} (where {condition}): {result.rowcount} rows deleted")
        total += result.rowcount or 0

    db.session.commit()
    print(f"\nDone. {total} total rows deleted. Users, sessions, module install "
          f"status, and shared reference data were left untouched.")
