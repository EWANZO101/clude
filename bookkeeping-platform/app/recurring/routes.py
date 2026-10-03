from datetime import datetime, date
from decimal import Decimal
from flask import Blueprint, render_template, request, redirect, url_for, flash
from flask_login import login_required, current_user
from app.extensions import db
from app.models.party import Supplier
from app.models.accounting import Account, EXPENSE, ASSET
from app.models.recurring import RecurringExpense, FREQUENCIES
from app.businesses.decorators import require_current_business, require_permission
from app.recurring.processor import process_recurring_expenses_for_business

recurring_bp = Blueprint("recurring", __name__, template_folder="../templates/recurring")


@recurring_bp.route("/expenses")
@login_required
@require_current_business
@require_permission("view")
def list_recurring_expenses(business):
    items = RecurringExpense.query.filter_by(business_id=business.id).order_by(RecurringExpense.created_at.desc()).all()
    return render_template("recurring/list.html", items=items)


@recurring_bp.route("/expenses/new", methods=["GET", "POST"])
@login_required
@require_current_business
@require_permission("create")
def new_recurring_expense(business):
    suppliers = Supplier.query.filter_by(business_id=business.id, is_archived=False).order_by(Supplier.name).all()
    expense_accounts = Account.query.filter_by(business_id=business.id, account_type=EXPENSE, is_archived=False).all()
    asset_accounts = Account.query.filter_by(business_id=business.id, account_type=ASSET, is_archived=False).all()

    if request.method == "POST":
        description = request.form.get("description", "").strip()
        amount = Decimal(request.form.get("amount") or "0")
        frequency = request.form.get("frequency", "monthly")
        start_date_str = request.form.get("start_date")
        end_date_str = request.form.get("end_date")

        if not description or amount <= 0 or frequency not in FREQUENCIES:
            flash("Description, a positive amount, and a valid frequency are required.", "error")
            return render_template("recurring/new.html", suppliers=suppliers, expense_accounts=expense_accounts, asset_accounts=asset_accounts, frequencies=FREQUENCIES)

        start_date = datetime.strptime(start_date_str, "%Y-%m-%d").date() if start_date_str else date.today()
        end_date = datetime.strptime(end_date_str, "%Y-%m-%d").date() if end_date_str else None

        item = RecurringExpense(
            business_id=business.id,
            description=description,
            amount=amount,
            expense_account_id=request.form.get("expense_account_id"),
            paid_from_account_id=request.form.get("paid_from_account_id"),
            supplier_id=request.form.get("supplier_id") or None,
            frequency=frequency,
            start_date=start_date,
            end_date=end_date,
            next_run_date=start_date,
            created_by_id=current_user.id,
        )
        db.session.add(item)
        db.session.commit()
        flash("Recurring expense created.", "success")
        return redirect(url_for("recurring.list_recurring_expenses"))

    return render_template("recurring/new.html", suppliers=suppliers, expense_accounts=expense_accounts, asset_accounts=asset_accounts, frequencies=FREQUENCIES)


@recurring_bp.route("/expenses/<item_id>/toggle", methods=["POST"])
@login_required
@require_current_business
@require_permission("edit")
def toggle_recurring_expense(business, item_id):
    item = RecurringExpense.query.filter_by(id=item_id, business_id=business.id).first_or_404()
    item.is_active = not item.is_active
    db.session.commit()
    flash(f"Recurring expense {'activated' if item.is_active else 'paused'}.", "success")
    return redirect(url_for("recurring.list_recurring_expenses"))


@recurring_bp.route("/expenses/run-due-now", methods=["POST"])
@login_required
@require_current_business
@require_permission("create")
def run_due_now(business):
    created = process_recurring_expenses_for_business(business.id, created_by_id=current_user.id)
    flash(f"Generated {len(created)} expense(s) from due recurring templates.", "success")
    return redirect(url_for("recurring.list_recurring_expenses"))
