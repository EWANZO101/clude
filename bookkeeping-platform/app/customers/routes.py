from flask import Blueprint, render_template, request, redirect, url_for, flash
from flask_login import login_required
from app.extensions import db
from app.models.party import Customer
from app.businesses.decorators import require_current_business, require_permission

customers_bp = Blueprint("customers", __name__, template_folder="../templates/customers")


@customers_bp.route("/")
@login_required
@require_current_business
@require_permission("view")
def list_customers(business):
    customers = Customer.query.filter_by(business_id=business.id, is_archived=False).order_by(Customer.name).all()
    return render_template("customers/list.html", customers=customers)


@customers_bp.route("/new", methods=["GET", "POST"])
@login_required
@require_current_business
@require_permission("create")
def new_customer(business):
    if request.method == "POST":
        name = request.form.get("name", "").strip()
        if not name:
            flash("Customer name is required.", "error")
            return render_template("customers/new.html")
        db.session.add(Customer(
            business_id=business.id,
            name=name,
            email=request.form.get("email") or None,
            phone=request.form.get("phone") or None,
            address=request.form.get("address") or None,
            tax_number=request.form.get("tax_number") or None,
        ))
        db.session.commit()
        flash("Customer added.", "success")
        return redirect(url_for("customers.list_customers"))
    return render_template("customers/new.html")


@customers_bp.route("/<customer_id>")
@login_required
@require_current_business
@require_permission("view")
def view_customer(business, customer_id):
    customer = Customer.query.filter_by(id=customer_id, business_id=business.id).first_or_404()
    return render_template("customers/view.html", customer=customer)
