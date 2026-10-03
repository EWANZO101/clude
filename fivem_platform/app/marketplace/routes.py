from flask import render_template, request, redirect, url_for, flash
from flask_login import login_required, current_user

from app.marketplace import marketplace_bp
from app.extensions import db
from app.models.developer import Product


@marketplace_bp.route("/marketplace")
def browse():
    q = request.args.get("q", "").strip()
    query = Product.query.filter_by(marketplace_listed=True, is_active=True)
    if q:
        like = f"%{q}%"
        query = query.filter(Product.name.ilike(like))
    products = query.order_by(Product.created_at.desc()).all()
    return render_template("marketplace/browse.html", products=products, q=q)


@marketplace_bp.route("/marketplace/<product_id>")
def product_page(product_id):
    product = Product.query.filter_by(
        product_id=product_id, marketplace_listed=True, is_active=True
    ).first_or_404()
    return render_template("marketplace/product_page.html", product=product)


# ---------------------------------------------------- developer-side toggle
@marketplace_bp.route("/developer/products/<product_id>/marketplace", methods=["GET", "POST"])
@login_required
def manage_listing(product_id):
    from app.developer.routes import get_workspace_developer_id
    from flask import g

    workspace_id = get_workspace_developer_id(current_user)
    if workspace_id is None:
        flash("You need a developer account for that.", "error")
        return redirect(url_for("developer.overview"))
    if workspace_id != current_user.id:
        flash("Only the workspace owner can manage the marketplace listing.", "error")
        return redirect(url_for("developer.overview"))
    g.workspace_developer_id = workspace_id

    product = Product.query.filter_by(product_id=product_id, developer_id=workspace_id).first_or_404()

    if request.method == "POST":
        listed = request.form.get("marketplace_listed") == "on"
        purchase_url = request.form.get("purchase_url", "").strip()

        if listed and not purchase_url:
            flash("Add a purchase link before listing on the marketplace - customers need somewhere to actually buy it.", "error")
            return render_template("marketplace/manage_listing.html", product=product)

        if purchase_url and not (purchase_url.startswith("http://") or purchase_url.startswith("https://")):
            flash("Purchase link needs to start with http:// or https://", "error")
            return render_template("marketplace/manage_listing.html", product=product)

        product.marketplace_listed = listed
        product.purchase_url = purchase_url or None

        from app.developer.routes import log_activity
        log_activity(
            workspace_id,
            "marketplace_listed" if listed else "marketplace_unlisted",
            detail=product.name,
        )

        db.session.commit()
        flash("Listing updated.", "success")
        return redirect(url_for("developer.product_detail", product_id=product.product_id))

    return render_template("marketplace/manage_listing.html", product=product)
