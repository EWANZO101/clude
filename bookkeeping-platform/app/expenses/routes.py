from datetime import datetime, date
from decimal import Decimal
from flask import Blueprint, render_template, request, redirect, url_for, flash, jsonify
from flask_login import login_required, current_user
from app.extensions import db
from app.models.party import Supplier
from app.models.accounting import Account, EXPENSE, ASSET
from app.models.expense import Expense
from app.accounting.engine import post_journal_entry, UnbalancedEntryError, InvalidLineError
from app.businesses.decorators import require_current_business, require_permission
from app.accounting.categorization import suggest_category_for_business

expenses_bp = Blueprint("expenses", __name__, template_folder="../templates/expenses")


@expenses_bp.route("/")
@login_required
@require_current_business
@require_permission("view")
def list_expenses(business):
    expenses = Expense.query.filter_by(business_id=business.id).order_by(Expense.expense_date.desc()).all()
    return render_template("expenses/list.html", expenses=expenses)


@expenses_bp.route("/new", methods=["GET", "POST"])
@login_required
@require_current_business
@require_permission("create")
def new_expense(business):
    suppliers = Supplier.query.filter_by(business_id=business.id, is_archived=False).order_by(Supplier.name).all()
    expense_accounts = Account.query.filter_by(business_id=business.id, account_type=EXPENSE, is_archived=False).all()
    asset_accounts = Account.query.filter_by(business_id=business.id, account_type=ASSET, is_archived=False).all()

    if request.method == "POST":
        description = request.form.get("description", "").strip()
        amount = Decimal(request.form.get("amount") or "0")
        expense_account_id = request.form.get("expense_account_id")
        paid_from_account_id = request.form.get("paid_from_account_id")
        expense_date_str = request.form.get("expense_date")

        if not description or amount <= 0 or not expense_account_id or not paid_from_account_id:
            flash("Description, a positive amount, and both accounts are required.", "error")
            return render_template("expenses/new.html", suppliers=suppliers, expense_accounts=expense_accounts, asset_accounts=asset_accounts)

        expense_date = datetime.strptime(expense_date_str, "%Y-%m-%d").date() if expense_date_str else date.today()

        try:
            entry = post_journal_entry(
                business_id=business.id,
                entry_date=expense_date,
                lines=[
                    {"account_id": expense_account_id, "debit": amount},
                    {"account_id": paid_from_account_id, "credit": amount},
                ],
                description=description,
                source_type="expense",
                created_by_id=current_user.id,
            )
        except (UnbalancedEntryError, InvalidLineError) as e:
            flash(f"Could not record expense: {e}", "error")
            return render_template("expenses/new.html", suppliers=suppliers, expense_accounts=expense_accounts, asset_accounts=asset_accounts)

        expense = Expense(
            business_id=business.id,
            supplier_id=request.form.get("supplier_id") or None,
            expense_date=expense_date,
            description=description,
            amount=amount,
            expense_account_id=expense_account_id,
            paid_from_account_id=paid_from_account_id,
            is_reimbursable=bool(request.form.get("is_reimbursable")),
            journal_entry_id=entry.id,
        )
        db.session.add(expense)
        db.session.commit()
        flash("Expense recorded and posted to the ledger.", "success")
        return redirect(url_for("expenses.list_expenses"))

    return render_template("expenses/new.html", suppliers=suppliers, expense_accounts=expense_accounts, asset_accounts=asset_accounts)

@expenses_bp.route("/suggest-category", methods=["POST"])
@login_required
@require_current_business
@require_permission("view")
def suggest_category(business):
    """Returns suggestions only — never creates or modifies an expense. The
    user must explicitly pick a suggestion (or ignore it) in the form."""
    description = (request.get_json(silent=True) or {}).get("description", "")
    suggestions = suggest_category_for_business(description, business)
    return jsonify({
        "suggestions": [
            {"account_id": s["account"].id, "account_name": s["account"].name, "confidence": s["confidence"], "reason": s["reason"]}
            for s in suggestions
        ]
    })

