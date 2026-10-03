from datetime import date, datetime
from decimal import Decimal
from flask import Blueprint, render_template, request, redirect, url_for, flash
from flask_login import login_required, current_user
from app.models.accounting import Account
from app.accounting.engine import post_journal_entry, UnbalancedEntryError, InvalidLineError, trial_balance
from app.businesses.decorators import require_current_business, require_permission

accounting_bp = Blueprint("accounting", __name__, template_folder="../templates/accounting")


@accounting_bp.route("/chart-of-accounts")
@login_required
@require_current_business
@require_permission("view")
def chart_of_accounts(business):
    accounts = Account.query.filter_by(business_id=business.id, is_archived=False).order_by(Account.code).all()
    return render_template("accounting/chart_of_accounts.html", accounts=accounts)


@accounting_bp.route("/journal/new", methods=["GET", "POST"])
@login_required
@require_current_business
@require_permission("create")
def new_journal_entry(business):
    accounts = Account.query.filter_by(business_id=business.id, is_archived=False).order_by(Account.code).all()

    if request.method == "POST":
        entry_date_str = request.form.get("entry_date")
        description = request.form.get("description")
        try:
            entry_date = datetime.strptime(entry_date_str, "%Y-%m-%d").date() if entry_date_str else date.today()
        except ValueError:
            flash("Invalid date.", "error")
            return render_template("accounting/new_journal_entry.html", accounts=accounts)

        line_account_ids = request.form.getlist("account_id")
        line_debits = request.form.getlist("debit")
        line_credits = request.form.getlist("credit")

        lines = []
        for acc_id, debit, credit in zip(line_account_ids, line_debits, line_credits):
            if not acc_id:
                continue
            lines.append({
                "account_id": acc_id,
                "debit": Decimal(debit) if debit else 0,
                "credit": Decimal(credit) if credit else 0,
            })

        try:
            post_journal_entry(
                business_id=business.id,
                entry_date=entry_date,
                lines=lines,
                description=description,
                source_type="manual",
                created_by_id=current_user.id,
            )
        except (UnbalancedEntryError, InvalidLineError) as e:
            flash(str(e), "error")
            return render_template("accounting/new_journal_entry.html", accounts=accounts)

        flash("Journal entry posted.", "success")
        return redirect(url_for("accounting.chart_of_accounts"))

    return render_template("accounting/new_journal_entry.html", accounts=accounts)


@accounting_bp.route("/reports/trial-balance")
@login_required
@require_current_business
@require_permission("view")
def report_trial_balance(business):
    rows = trial_balance(business.id)
    total_debit = sum(b for a, b in rows if b >= 0)
    total_credit = sum(-b for a, b in rows if b < 0)
    return render_template(
        "accounting/trial_balance.html", rows=rows, total_debit=total_debit, total_credit=total_credit
    )

@accounting_bp.route("/reports/profit-and-loss")
@login_required
@require_current_business
@require_permission("view")
def report_profit_and_loss(business):
    from app.models.accounting import REVENUE, EXPENSE, COGS
    rows = trial_balance(business.id)
    revenue_rows = [(a, b) for a, b in rows if a.account_type == REVENUE]
    cogs_rows = [(a, b) for a, b in rows if a.account_type == COGS]
    expense_rows = [(a, b) for a, b in rows if a.account_type == EXPENSE]

    total_revenue = sum(b for a, b in revenue_rows)
    total_cogs = sum(b for a, b in cogs_rows)
    total_expenses = sum(b for a, b in expense_rows)
    gross_profit = total_revenue - total_cogs
    net_profit = gross_profit - total_expenses

    return render_template(
        "accounting/profit_and_loss.html",
        revenue_rows=revenue_rows, cogs_rows=cogs_rows, expense_rows=expense_rows,
        total_revenue=total_revenue, total_cogs=total_cogs, total_expenses=total_expenses,
        gross_profit=gross_profit, net_profit=net_profit,
    )


@accounting_bp.route("/reports/balance-sheet")
@login_required
@require_current_business
@require_permission("view")
def report_balance_sheet(business):
    from app.models.accounting import ASSET, LIABILITY, EQUITY
    rows = trial_balance(business.id)
    asset_rows = [(a, b) for a, b in rows if a.account_type == ASSET]
    liability_rows = [(a, b) for a, b in rows if a.account_type == LIABILITY]
    equity_rows = [(a, b) for a, b in rows if a.account_type == EQUITY]

    total_assets = sum(b for a, b in asset_rows)
    total_liabilities = sum(b for a, b in liability_rows)
    total_equity = sum(b for a, b in equity_rows)

    return render_template(
        "accounting/balance_sheet.html",
        asset_rows=asset_rows, liability_rows=liability_rows, equity_rows=equity_rows,
        total_assets=total_assets, total_liabilities=total_liabilities, total_equity=total_equity,
    )

def _age_bucket(days_overdue):
    if days_overdue <= 0:
        return "current"
    if days_overdue <= 30:
        return "1-30"
    if days_overdue <= 60:
        return "31-60"
    if days_overdue <= 90:
        return "61-90"
    return "90+"


@accounting_bp.route("/reports/aged-receivables")
@login_required
@require_current_business
@require_permission("view")
def report_aged_receivables(business):
    from datetime import date
    from app.models.invoice import Invoice

    today = date.today()
    invoices = Invoice.query.filter_by(business_id=business.id).filter(
        Invoice.status.in_(["sent", "partially_paid", "overdue"])
    ).all()

    buckets = {"current": [], "1-30": [], "31-60": [], "61-90": [], "90+": []}
    for inv in invoices:
        if inv.balance_due() <= 0:
            continue
        due = inv.due_date or inv.issue_date
        days_overdue = (today - due).days
        buckets[_age_bucket(days_overdue)].append(inv)

    totals = {k: sum(i.balance_due() for i in v) for k, v in buckets.items()}
    grand_total = sum(totals.values())
    return render_template("accounting/aged_receivables.html", buckets=buckets, totals=totals, grand_total=grand_total)


@accounting_bp.route("/reports/aged-payables")
@login_required
@require_current_business
@require_permission("view")
def report_aged_payables(business):
    from datetime import date
    from app.models.bill import Bill

    today = date.today()
    bills = Bill.query.filter_by(business_id=business.id).filter(
        Bill.status.in_(["open", "partially_paid", "overdue"])
    ).all()

    buckets = {"current": [], "1-30": [], "31-60": [], "61-90": [], "90+": []}
    for bill in bills:
        if bill.balance_due() <= 0:
            continue
        due = bill.due_date or bill.issue_date
        days_overdue = (today - due).days
        buckets[_age_bucket(days_overdue)].append(bill)

    totals = {k: sum(b.balance_due() for b in v) for k, v in buckets.items()}
    grand_total = sum(totals.values())
    return render_template("accounting/aged_payables.html", buckets=buckets, totals=totals, grand_total=grand_total)


@accounting_bp.route("/reports/cash-flow-forecast")
@login_required
@require_current_business
@require_permission("view")
def report_cash_flow_forecast(business):
    """A deliberately simple, transparent forecast: projects the next 90
    days of cash position from (a) today's cash balance, (b) invoices
    expected to be collected by their due date, and (c) bills expected to
    be paid by their due date. This is a planning aid, not a prediction
    engine — no machine learning, no hidden assumptions, every number in
    the chart traces back to a real invoice or bill."""
    from datetime import date, timedelta
    from app.models.invoice import Invoice
    from app.models.bill import Bill
    from app.models.accounting import Account

    cash_accounts = Account.query.filter_by(business_id=business.id, code="1000").first()
    starting_cash = cash_accounts.balance() if cash_accounts else 0

    today = date.today()
    horizon_end = today + timedelta(days=90)

    inflows = Invoice.query.filter_by(business_id=business.id).filter(
        Invoice.status.in_(["sent", "partially_paid", "overdue"])
    ).all()
    outflows = Bill.query.filter_by(business_id=business.id).filter(
        Bill.status.in_(["open", "partially_paid", "overdue"])
    ).all()

    weekly_points = []
    running = starting_cash
    cursor = today
    while cursor <= horizon_end:
        week_end = cursor + timedelta(days=7)
        expected_in = sum(
            i.balance_due() for i in inflows
            if i.due_date and cursor <= i.due_date < week_end
        )
        expected_out = sum(
            b.balance_due() for b in outflows
            if b.due_date and cursor <= b.due_date < week_end
        )
        running = running + expected_in - expected_out
        weekly_points.append({"week_of": cursor, "expected_in": expected_in, "expected_out": expected_out, "projected_cash": running})
        cursor = week_end

    return render_template(
        "accounting/cash_flow_forecast.html",
        starting_cash=starting_cash, weekly_points=weekly_points,
    )

