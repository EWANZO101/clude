import csv
import io


def _to_csv(fieldnames, rows):
    buf = io.StringIO()
    writer = csv.DictWriter(buf, fieldnames=fieldnames)
    writer.writeheader()
    for row in rows:
        writer.writerow(row)
    return buf.getvalue()


def export_customers(business):
    from app.models.party import Customer
    customers = Customer.query.filter_by(business_id=business.id).all()
    fields = ["id", "name", "email", "phone", "address", "tax_number", "outstanding_balance", "created_at"]
    rows = [{
        "id": c.id, "name": c.name, "email": c.email or "", "phone": c.phone or "",
        "address": (c.address or "").replace("\n", " "), "tax_number": c.tax_number or "",
        "outstanding_balance": str(c.outstanding_balance()), "created_at": c.created_at,
    } for c in customers]
    return "customers.csv", _to_csv(fields, rows)


def export_suppliers(business):
    from app.models.party import Supplier
    suppliers = Supplier.query.filter_by(business_id=business.id).all()
    fields = ["id", "name", "email", "phone", "address", "tax_number", "outstanding_balance", "created_at"]
    rows = [{
        "id": s.id, "name": s.name, "email": s.email or "", "phone": s.phone or "",
        "address": (s.address or "").replace("\n", " "), "tax_number": s.tax_number or "",
        "outstanding_balance": str(s.outstanding_balance()), "created_at": s.created_at,
    } for s in suppliers]
    return "suppliers.csv", _to_csv(fields, rows)


def export_invoices(business):
    from app.models.invoice import Invoice
    invoices = Invoice.query.filter_by(business_id=business.id).all()
    fields = ["id", "invoice_number", "customer", "issue_date", "due_date", "status", "currency", "subtotal", "tax_total", "total", "paid_total", "balance_due"]
    rows = [{
        "id": i.id, "invoice_number": i.invoice_number, "customer": i.customer.name,
        "issue_date": i.issue_date, "due_date": i.due_date or "", "status": i.status, "currency": i.currency,
        "subtotal": str(i.subtotal()), "tax_total": str(i.tax_total()), "total": str(i.total()),
        "paid_total": str(i.paid_total()), "balance_due": str(i.balance_due()),
    } for i in invoices]
    return "invoices.csv", _to_csv(fields, rows)


def export_bills(business):
    from app.models.bill import Bill
    bills = Bill.query.filter_by(business_id=business.id).all()
    fields = ["id", "bill_number", "supplier", "issue_date", "due_date", "status", "total", "paid_total", "balance_due"]
    rows = [{
        "id": b.id, "bill_number": b.bill_number or "", "supplier": b.supplier.name,
        "issue_date": b.issue_date, "due_date": b.due_date or "", "status": b.status,
        "total": str(b.total()), "paid_total": str(b.paid_total()), "balance_due": str(b.balance_due()),
    } for b in bills]
    return "bills.csv", _to_csv(fields, rows)


def export_expenses(business):
    from app.models.expense import Expense
    expenses = Expense.query.filter_by(business_id=business.id).all()
    fields = ["id", "expense_date", "description", "amount", "expense_account", "paid_from_account", "supplier", "is_reimbursable"]
    rows = [{
        "id": e.id, "expense_date": e.expense_date, "description": e.description, "amount": str(e.amount),
        "expense_account": e.expense_account.name, "paid_from_account": e.paid_from_account.name,
        "supplier": e.supplier.name if e.supplier else "", "is_reimbursable": e.is_reimbursable,
    } for e in expenses]
    return "expenses.csv", _to_csv(fields, rows)


def export_chart_of_accounts(business):
    from app.models.accounting import Account
    accounts = Account.query.filter_by(business_id=business.id).all()
    fields = ["id", "code", "name", "account_type", "balance", "is_archived"]
    rows = [{
        "id": a.id, "code": a.code, "name": a.name, "account_type": a.account_type,
        "balance": str(a.balance()), "is_archived": a.is_archived,
    } for a in accounts]
    return "chart_of_accounts.csv", _to_csv(fields, rows)


def export_journal_entries(business):
    from app.models.accounting import JournalEntry
    entries = JournalEntry.query.filter_by(business_id=business.id).order_by(JournalEntry.entry_date).all()
    fields = ["id", "entry_date", "description", "source_type", "is_void", "account_code", "account_name", "debit", "credit"]
    rows = []
    for e in entries:
        for line in e.lines:
            rows.append({
                "id": e.id, "entry_date": e.entry_date, "description": e.description or "",
                "source_type": e.source_type, "is_void": e.is_void,
                "account_code": line.account.code, "account_name": line.account.name,
                "debit": str(line.debit), "credit": str(line.credit),
            })
    return "journal_entries.csv", _to_csv(fields, rows)


ALL_EXPORTERS = [
    export_customers, export_suppliers, export_invoices, export_bills,
    export_expenses, export_chart_of_accounts, export_journal_entries,
]
