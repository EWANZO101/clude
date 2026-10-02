"""Turns due RecurringExpense templates into real, ledger-posted Expense
records — through app.accounting.engine.post_journal_entry, same as a
manually entered expense. Nothing here bypasses double-entry."""
from datetime import date
from app.extensions import db
from app.models.expense import Expense
from app.models.recurring import RecurringExpense
from app.accounting.engine import post_journal_entry


def process_recurring_expenses_for_business(business_id, created_by_id=None, as_of=None):
    as_of = as_of or date.today()
    due_items = RecurringExpense.query.filter_by(business_id=business_id, is_active=True).all()
    created = []

    for item in due_items:
        # A template can be overdue by more than one cycle (e.g. the app
        # was down); generate one expense per missed cycle, in order,
        # rather than silently skipping ahead.
        while item.is_due(as_of):
            entry = post_journal_entry(
                business_id=business_id,
                entry_date=item.next_run_date,
                lines=[
                    {"account_id": item.expense_account_id, "debit": item.amount},
                    {"account_id": item.paid_from_account_id, "credit": item.amount},
                ],
                description=f"{item.description} (recurring)",
                source_type="recurring_expense",
                source_id=item.id,
                created_by_id=created_by_id,
            )
            expense = Expense(
                business_id=business_id,
                supplier_id=item.supplier_id,
                expense_date=item.next_run_date,
                description=f"{item.description} (recurring)",
                amount=item.amount,
                expense_account_id=item.expense_account_id,
                paid_from_account_id=item.paid_from_account_id,
                journal_entry_id=entry.id,
                recurring_expense_id=item.id,
            )
            db.session.add(expense)
            created.append(expense)
            item.advance()
            db.session.commit()

    return created


def process_all_recurring_expenses(as_of=None):
    from app.models.business import Business
    total_created = []
    for business in Business.query.filter_by(is_archived=False).all():
        total_created.extend(process_recurring_expenses_for_business(business.id, as_of=as_of))
    return total_created
