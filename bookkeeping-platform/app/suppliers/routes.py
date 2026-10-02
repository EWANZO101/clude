from flask import Blueprint, render_template, request, redirect, url_for, flash
from flask_login import login_required
from app.extensions import db
from app.models.party import Supplier
from app.businesses.decorators import require_current_business, require_permission

suppliers_bp = Blueprint("suppliers", __name__, template_folder="../templates/suppliers")


@suppliers_bp.route("/")
@login_required
@require_current_business
@require_permission("view")
def list_suppliers(business):
    suppliers = Supplier.query.filter_by(business_id=business.id, is_archived=False).order_by(Supplier.name).all()
    return render_template("suppliers/list.html", suppliers=suppliers)


@suppliers_bp.route("/new", methods=["GET", "POST"])
@login_required
@require_current_business
@require_permission("create")
def new_supplier(business):
    if request.method == "POST":
        name = request.form.get("name", "").strip()
        if not name:
            flash("Supplier name is required.", "error")
            return render_template("suppliers/new.html")
        db.session.add(Supplier(
            business_id=business.id,
            name=name,
            email=request.form.get("email") or None,
            phone=request.form.get("phone") or None,
            address=request.form.get("address") or None,
            tax_number=request.form.get("tax_number") or None,
        ))
        db.session.commit()
        flash("Supplier added.", "success")
        return redirect(url_for("suppliers.list_suppliers"))
    return render_template("suppliers/new.html")


@suppliers_bp.route("/<supplier_id>")
@login_required
@require_current_business
@require_permission("view")
def view_supplier(business, supplier_id):
    supplier = Supplier.query.filter_by(id=supplier_id, business_id=business.id).first_or_404()
    return render_template("suppliers/view.html", supplier=supplier)
