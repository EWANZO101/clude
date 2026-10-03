from datetime import datetime, date
from decimal import Decimal
from flask import Blueprint, render_template, request, redirect, url_for, flash
from flask_login import login_required, current_user
from app.extensions import db
from app.models.party import Supplier
from app.models.accounting import Account, EXPENSE, ASSET
from app.models.bill import Bill, BillLine, STATUS_DRAFT, STATUS_OPEN, STATUS_PAID, STATUS_PARTIALLY_PAID
from app.models.invoice import Payment
from app.accounting.engine import post_journal_entry, UnbalancedEntryError, InvalidLineError
from app.businesses.decorators import require_current_business, require_permission

bills_bp = Blueprint("bills", __name__, template_folder="../templates/bills")


def _payable_account(business):
    return Account.query.filter_by(business_id=business.id, code="2000").first()


@bills_bp.route("/")
@login_required
@require_current_business
@require_permission("view")
def list_bills(business):
    bills = Bill.query.filter_by(business_id=business.id).order_by(Bill.issue_date.desc()).all()
    return render_template("bills/list.html", bills=bills)


@bills_bp.route("/new", methods=["GET", "POST"])
@login_required
@require_current_business
@require_permission("create")
def new_bill(business):
    suppliers = Supplier.query.filter_by(business_id=business.id, is_archived=False).order_by(Supplier.name).all()
    expense_accounts = Account.query.filter_by(business_id=business.id, account_type=EXPENSE, is_archived=False).all()

    if request.method == "POST":
        supplier_id = request.form.get("supplier_id")
        if not supplier_id:
            flash("Supplier is required.", "error")
            return render_template("bills/new.html", suppliers=suppliers, expense_accounts=expense_accounts)

        issue_date_str = request.form.get("issue_date")
        due_date_str = request.form.get("due_date")
        bill = Bill(
            business_id=business.id,
            supplier_id=supplier_id,
            bill_number=request.form.get("bill_number") or None,
            issue_date=datetime.strptime(issue_date_str, "%Y-%m-%d").date() if issue_date_str else date.today(),
            due_date=datetime.strptime(due_date_str, "%Y-%m-%d").date() if due_date_str else None,
            status=STATUS_DRAFT,
        )
        db.session.add(bill)
        db.session.flush()

        descriptions = request.form.getlist("line_description")
        amounts = request.form.getlist("line_amount")
        account_ids = request.form.getlist("line_account_id")
        for desc, amt, acc_id in zip(descriptions, amounts, account_ids):
            if not desc:
                continue
            db.session.add(BillLine(bill_id=bill.id, account_id=acc_id, description=desc, amount=Decimal(amt or "0")))

        db.session.commit()
        flash("Bill created as draft.", "success")
        return redirect(url_for("bills.view_bill", bill_id=bill.id))

    return render_template("bills/new.html", suppliers=suppliers, expense_accounts=expense_accounts)


@bills_bp.route("/<bill_id>")
@login_required
@require_current_business
@require_permission("view")
def view_bill(business, bill_id):
    bill = Bill.query.filter_by(id=bill_id, business_id=business.id).first_or_404()
    accounts = Account.query.filter_by(business_id=business.id, account_type=ASSET, is_archived=False).all()
    return render_template("bills/view.html", bill=bill, accounts=accounts)


@bills_bp.route("/<bill_id>/approve", methods=["POST"])
@login_required
@require_current_business
@require_permission("edit")
def approve_bill(business, bill_id):
    bill = Bill.query.filter_by(id=bill_id, business_id=business.id).first_or_404()
    if bill.status != STATUS_DRAFT:
        flash("Only draft bills can be approved.", "error")
        return redirect(url_for("bills.view_bill", bill_id=bill.id))

    payable = _payable_account(business)
    lines = [{"account_id": payable.id, "credit": bill.total()}]
    for line in bill.lines:
        lines.append({"account_id": line.account_id, "debit": line.amount})

    try:
        entry = post_journal_entry(
            business_id=business.id,
            entry_date=bill.issue_date,
            lines=lines,
            description=f"Bill {bill.bill_number or bill.id[:8]}",
            source_type="bill",
            source_id=bill.id,
            created_by_id=current_user.id,
        )
    except (UnbalancedEntryError, InvalidLineError) as e:
        flash(f"Could not approve bill: {e}", "error")
        return redirect(url_for("bills.view_bill", bill_id=bill.id))

    bill.journal_entry_id = entry.id
    bill.status = STATUS_OPEN
    db.session.commit()
    flash("Bill approved and posted to the ledger.", "success")
    return redirect(url_for("bills.view_bill", bill_id=bill.id))


@bills_bp.route("/<bill_id>/record-payment", methods=["POST"])
@login_required
@require_current_business
@require_permission("edit")
def record_bill_payment(business, bill_id):
    bill = Bill.query.filter_by(id=bill_id, business_id=business.id).first_or_404()
    if bill.status not in (STATUS_OPEN, STATUS_PARTIALLY_PAID, "overdue"):
        flash("This bill cannot receive payments in its current status.", "error")
        return redirect(url_for("bills.view_bill", bill_id=bill.id))

    amount = Decimal(request.form.get("amount") or "0")
    paid_from_account_id = request.form.get("paid_from_account_id")
    payment_date_str = request.form.get("payment_date")

    if amount <= 0 or amount > bill.balance_due():
        flash("Payment amount must be positive and not exceed the balance due.", "error")
        return redirect(url_for("bills.view_bill", bill_id=bill.id))

    payable = _payable_account(business)
    try:
        entry = post_journal_entry(
            business_id=business.id,
            entry_date=datetime.strptime(payment_date_str, "%Y-%m-%d").date() if payment_date_str else date.today(),
            lines=[
                {"account_id": payable.id, "debit": amount},
                {"account_id": paid_from_account_id, "credit": amount},
            ],
            description=f"Payment for bill {bill.bill_number or bill.id[:8]}",
            source_type="bill_payment",
            source_id=bill.id,
            created_by_id=current_user.id,
        )
    except (UnbalancedEntryError, InvalidLineError) as e:
        flash(f"Could not record payment: {e}", "error")
        return redirect(url_for("bills.view_bill", bill_id=bill.id))

    payment = Payment(
        business_id=business.id,
        bill_id=bill.id,
        payment_date=entry.entry_date,
        amount=amount,
        deposit_account_id=paid_from_account_id,
        journal_entry_id=entry.id,
    )
    db.session.add(payment)
    bill.status = STATUS_PAID if bill.balance_due() - amount <= 0 else STATUS_PARTIALLY_PAID
    db.session.commit()
    flash("Payment recorded.", "success")
    return redirect(url_for("bills.view_bill", bill_id=bill.id))
