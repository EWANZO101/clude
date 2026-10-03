"""Self-audit / integrity checks. Read-only: this module NEVER modifies
financial records to make a check pass. It only observes and reports."""
from decimal import Decimal
from app.extensions import db
from app.models.accounting import JournalEntry, Account
from app.models.invoice import Invoice, STATUS_DRAFT as INV_DRAFT, STATUS_VOID as INV_VOID
from app.models.bill import Bill, STATUS_DRAFT as BILL_DRAFT, STATUS_VOID as BILL_VOID
from app.models.integrity import IntegrityCheckRun, IntegrityIssue, SEVERITY_HIGH, SEVERITY_MEDIUM, SEVERITY_LOW


def _add_issue(run, check_name, severity, what, why, action, entity_type=None, entity_id=None):
    db.session.add(IntegrityIssue(
        run_id=run.id, check_name=check_name, severity=severity,
        entity_type=entity_type, entity_id=entity_id,
        what_happened=what, why_it_matters=why, recommended_action=action,
    ))


def run_integrity_check(business_id=None):
    """Runs all checks for one business (or, if business_id is None, across
    every business) and persists an IntegrityCheckRun with its issues."""
    from datetime import datetime

    run = IntegrityCheckRun(business_id=business_id)
    db.session.add(run)
    db.session.flush()

    entries_query = JournalEntry.query.filter_by(is_void=False)
    if business_id:
        entries_query = entries_query.filter_by(business_id=business_id)

    # Check 1: unbalanced journal entries (should be impossible via the
    # engine, but a direct DB edit or a bug elsewhere could produce one —
    # this is the safety net).
    for entry in entries_query.all():
        if not entry.is_balanced():
            _add_issue(
                run, "unbalanced_journal_entry", SEVERITY_HIGH,
                what=f"Journal entry {entry.id} has debits ({entry.total_debit()}) "
                     f"not equal to credits ({entry.total_credit()}).",
                why="Every posted entry must balance for the ledger to be trustworthy. "
                    "An unbalanced entry means the books are not accurate.",
                action="Review the entry's lines and correct or void it through the "
                       "accounting engine; do not edit ledger rows directly.",
                entity_type="JournalEntry", entity_id=entry.id,
            )

    # Check 2: invoices marked as sent/paid but with no linked journal entry.
    invoices_query = Invoice.query.filter(Invoice.status.notin_([INV_DRAFT, INV_VOID]))
    if business_id:
        invoices_query = invoices_query.filter_by(business_id=business_id)
    for inv in invoices_query.all():
        if not inv.journal_entry_id:
            _add_issue(
                run, "invoice_missing_journal_entry", SEVERITY_HIGH,
                what=f"Invoice {inv.invoice_number} has status '{inv.status}' but no linked journal entry.",
                why="A sent invoice that never hit the ledger means revenue is understated.",
                action="Re-post the invoice through the accounting engine.",
                entity_type="Invoice", entity_id=inv.id,
            )

    # Check 3: bills marked open/paid but with no linked journal entry.
    bills_query = Bill.query.filter(Bill.status.notin_([BILL_DRAFT, BILL_VOID]))
    if business_id:
        bills_query = bills_query.filter_by(business_id=business_id)
    for bill in bills_query.all():
        if not bill.journal_entry_id:
            _add_issue(
                run, "bill_missing_journal_entry", SEVERITY_HIGH,
                what=f"Bill {bill.bill_number or bill.id[:8]} has status '{bill.status}' but no linked journal entry.",
                why="An approved bill that never hit the ledger means liabilities are understated.",
                action="Re-post the bill through the accounting engine.",
                entity_type="Bill", entity_id=bill.id,
            )

    # Check 4: invoices where recorded payments exceed the invoice total.
    for inv in invoices_query.all():
        if inv.paid_total() > inv.total():
            _add_issue(
                run, "invoice_overpaid", SEVERITY_MEDIUM,
                what=f"Invoice {inv.invoice_number} has payments ({inv.paid_total()}) exceeding its total ({inv.total()}).",
                why="This usually indicates a data entry error or a refund that wasn't recorded properly.",
                action="Review the invoice's payment history and record a refund/credit if appropriate.",
                entity_type="Invoice", entity_id=inv.id,
            )

    # Check 5: accounts with no code or duplicate codes within a business (defensive; DB constraint should prevent this).
    accounts_query = Account.query.filter_by(is_archived=False)
    if business_id:
        accounts_query = accounts_query.filter_by(business_id=business_id)
    seen = {}
    for acct in accounts_query.all():
        key = (acct.business_id, acct.code)
        if key in seen:
            _add_issue(
                run, "duplicate_account_code", SEVERITY_LOW,
                what=f"Accounts '{seen[key]}' and '{acct.name}' share code {acct.code}.",
                why="Duplicate codes make the chart of accounts ambiguous in reports and imports.",
                action="Assign a unique code to one of the accounts.",
                entity_type="Account", entity_id=acct.id,
            )
        seen[key] = acct.name

    run.issue_count = IntegrityIssue.query.filter_by(run_id=run.id).count()
    run.finished_at = datetime.utcnow()
    db.session.commit()
    return run
