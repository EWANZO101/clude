from flask import Blueprint, render_template, redirect, url_for
from flask_login import login_required, current_user
from app.accounting.engine import trial_balance

dashboard_bp = Blueprint("dashboard", __name__, template_folder="../templates/dashboard")


@dashboard_bp.route("/")
@login_required
def index():
    business = current_user.current_business()
    if business is None:
        return redirect(url_for("businesses.new_business"))

    rows = trial_balance(business.id)
    from app.models.accounting import ASSET, LIABILITY, REVENUE, EXPENSE, COGS

    total_assets = sum(b for a, b in rows if a.account_type == ASSET)
    total_liabilities = sum(b for a, b in rows if a.account_type == LIABILITY)
    total_revenue = sum(b for a, b in rows if a.account_type == REVENUE)
    total_expenses = sum(b for a, b in rows if a.account_type in (EXPENSE, COGS))
    profit = total_revenue - total_expenses

    return render_template(
        "dashboard/index.html",
        business=business,
        total_assets=total_assets,
        total_liabilities=total_liabilities,
        total_revenue=total_revenue,
        total_expenses=total_expenses,
        profit=profit,
    )
