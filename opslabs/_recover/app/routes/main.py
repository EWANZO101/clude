from flask import Blueprint, render_template
from flask_login import current_user
from ..models import Company

main_bp = Blueprint("main", __name__)


@main_bp.route("/")
def index():
    companies = Company.query.filter_by(is_active=True).all()
    return render_template("index.html", companies=companies)


@main_bp.route("/about")
def about():
    return render_template("about.html")
