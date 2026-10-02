from flask import Blueprint, render_template, redirect, url_for
from flask_login import login_required, current_user

bp = Blueprint("dashboard", __name__)


@bp.route("/")
@login_required
def index():
    companies = current_user.companies()
    # A Client Portal user (belongs to exactly one company, not platform staff
    # juggling several) lands straight on that company's Instances page —
    # the company picker below only earns its keep once there's a real choice
    # to make.
    if len(companies) == 1 and not current_user.is_platform_admin:
        return redirect(url_for("instances.list_instances", company_id=companies[0].public_id))
    return render_template("dashboard/index.html", companies=companies)
