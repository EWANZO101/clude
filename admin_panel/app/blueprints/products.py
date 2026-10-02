"""Platform-admin management of the Products catalog and the queue of
companies requesting access to one. See models.py's Product/
CompanyProductAccess/company_has_product for the actual access-control
model this administers — this blueprint is purely the UI over it.
"""
import re
from datetime import datetime

from flask import Blueprint, render_template, redirect, url_for, request, flash, abort
from flask_login import login_required, current_user

from app.extensions import db
from app.models import Product, CompanyProductAccess, PRODUCT_ACCESS_STATUSES, log_action
from app.platform_auth import platform_admin_required

bp = Blueprint("products", __name__, url_prefix="/admin/products")


def _slugify(name: str) -> str:
    base = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-") or "product"
    slug = base
    n = 1
    while Product.query.filter_by(slug=slug).first() is not None:
        n += 1
        slug = f"{base}-{n}"
    return slug


@bp.route("/")
@login_required
@platform_admin_required
def list_products():
    products = Product.query.order_by(Product.created_at.desc()).all()
    counts = {
        p.id: {
            status: CompanyProductAccess.query.filter_by(product_id=p.id, status=status).count()
            for status in PRODUCT_ACCESS_STATUSES
        }
        for p in products
    }
    pending_total = CompanyProductAccess.query.filter_by(status="pending").count()
    return render_template("platform/products.html", products=products, counts=counts, pending_total=pending_total)


@bp.route("/new", methods=["GET", "POST"])
@login_required
@platform_admin_required
def new_product():
    if request.method == "POST":
        name = request.form.get("name", "").strip()
        description = request.form.get("description", "").strip()
        if not name:
            flash("Product name is required.", "danger")
            return render_template("platform/product_new.html", name=name, description=description)

        product = Product(name=name, slug=_slugify(name), description=description or None)
        db.session.add(product)
        log_action(None, current_user, "product_created", name)
        db.session.commit()
        flash(f"Product '{product.name}' created.", "success")
        return redirect(url_for("products.list_products"))

    return render_template("platform/product_new.html")


@bp.route("/<product_id>/toggle-active", methods=["POST"])
@login_required
@platform_admin_required
def toggle_active(product_id):
    product = Product.query.filter_by(public_id=product_id).first()
    if product is None:
        abort(404)
    product.is_active = not product.is_active
    log_action(None, current_user, "product_" + ("activated" if product.is_active else "deactivated"), product.name)
    db.session.commit()
    flash(
        f"'{product.name}' is now " + ("active." if product.is_active else "inactive — hidden from new requests, existing access unaffected."),
        "success",
    )
    return redirect(url_for("products.list_products"))


@bp.route("/requests")
@login_required
@platform_admin_required
def list_requests():
    all_requests = CompanyProductAccess.query.order_by(CompanyProductAccess.requested_at.desc()).all()
    request_groups = {"all": all_requests}
    for status in PRODUCT_ACCESS_STATUSES:
        request_groups[status] = [r for r in all_requests if r.status == status]
    request_counts = {key: len(rows) for key, rows in request_groups.items()}
    return render_template(
        "platform/product_requests.html",
        request_groups=request_groups, request_counts=request_counts,
    )


@bp.route("/requests/<int:access_id>/decide", methods=["POST"])
@login_required
@platform_admin_required
def decide_request(access_id):
    access = CompanyProductAccess.query.get_or_404(access_id)
    decision = request.form.get("decision", "").strip()
    if decision not in ("approved", "rejected"):
        abort(400)

    access.status = decision
    access.decided_by_id = current_user.id
    access.decided_at = datetime.utcnow()
    access.decision_note = (request.form.get("decision_note") or "").strip() or None
    log_action(access.company, current_user, f"product_request_{decision}", access.product.name)
    db.session.commit()
    flash(f"{access.product.name} access for {access.company.name}: {decision}.", "success")
    return redirect(url_for("products.list_requests"))
