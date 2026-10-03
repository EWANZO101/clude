from flask import Blueprint, render_template, redirect, url_for, flash, request, jsonify
from flask_login import login_required, current_user
from app.extensions import db
from app.models.item import Item
from app.models.audit_log import AuditAction
from app.utils.decorators import admin_required
from app.utils.audit import log_action
from app.utils.barcode_helper import generate_barcode

items_bp = Blueprint("items", __name__, url_prefix="/items")


@items_bp.route("/")
@login_required
def index():
    search = request.args.get("q", "").strip()
    category = request.args.get("category", "").strip()
    stock_filter = request.args.get("stock", "").strip()

    query = Item.query.filter_by(is_active=True)
    if search:
        query = query.filter(Item.name.ilike(f"%{search}%") | Item.sku.ilike(f"%{search}%"))
    if category:
        query = query.filter_by(category=category)
    if stock_filter == "low":
        query = query.filter(Item.quantity <= Item.low_stock_threshold, Item.quantity > 0)
    elif stock_filter == "out":
        query = query.filter_by(quantity=0)

    items = query.order_by(Item.name.asc()).all()
    categories = db.session.query(Item.category).filter(
        Item.is_active == True, Item.category != None
    ).distinct().all()
    categories = [c[0] for c in categories]

    return render_template("items/index.html", items=items, categories=categories,
                           search=search, category=category, stock_filter=stock_filter)


@items_bp.route("/add", methods=["GET", "POST"])
@login_required
@admin_required
def add():
    if request.method == "POST":
        name = request.form.get("name", "").strip()
        if not name:
            flash("Item name is required.", "danger")
            return render_template("items/form.html", item=None, action="Add")

        item = Item(
            name=name,
            sku=request.form.get("sku", "").strip() or None,
            description=request.form.get("description", "").strip() or None,
            category=request.form.get("category", "").strip() or None,
            location=request.form.get("location", "").strip() or None,
            quantity=int(request.form.get("quantity", 0) or 0),
            unit=request.form.get("unit", "").strip() or None,
            low_stock_threshold=int(request.form.get("low_stock_threshold", 5) or 5),
        )
        db.session.add(item)
        db.session.flush()

        generate_barcode("item", item.id)

        log_action(AuditAction.ITEM_CREATED, "item", item.id, item.name,
                   f"Item '{item.name}' created with qty {item.quantity}")
        db.session.commit()
        flash(f"Item '{item.name}' added successfully.", "success")
        return redirect(url_for("items.index"))

    return render_template("items/form.html", item=None, action="Add")


@items_bp.route("/<int:item_id>")
@login_required
def view(item_id):
    item = Item.query.get_or_404(item_id)
    return render_template("items/view.html", item=item)


@items_bp.route("/<int:item_id>/edit", methods=["GET", "POST"])
@login_required
@admin_required
def edit(item_id):
    item = Item.query.get_or_404(item_id)

    if request.method == "POST":
        name = request.form.get("name", "").strip()
        if not name:
            flash("Item name is required.", "danger")
            return render_template("items/form.html", item=item, action="Edit")

        item.name = name
        item.sku = request.form.get("sku", "").strip() or None
        item.description = request.form.get("description", "").strip() or None
        item.category = request.form.get("category", "").strip() or None
        item.location = request.form.get("location", "").strip() or None
        item.unit = request.form.get("unit", "").strip() or None
        item.low_stock_threshold = int(request.form.get("low_stock_threshold", 5) or 5)

        log_action(AuditAction.ITEM_UPDATED, "item", item.id, item.name,
                   f"Item '{item.name}' details updated")
        db.session.commit()
        flash(f"Item '{item.name}' updated.", "success")
        return redirect(url_for("items.view", item_id=item.id))

    return render_template("items/form.html", item=item, action="Edit")


@items_bp.route("/<int:item_id>/adjust", methods=["POST"])
@login_required
def adjust_stock(item_id):
    item = Item.query.get_or_404(item_id)
    delta = int(request.form.get("delta", 0) or 0)
    notes = request.form.get("notes", "").strip()

    if delta == 0:
        flash("Please enter a non-zero adjustment.", "warning")
        return redirect(url_for("items.view", item_id=item.id))

    old_qty = item.quantity
    item.adjust_stock(delta)
    direction = "increased" if delta > 0 else "decreased"

    log_action(AuditAction.ITEM_STOCK_ADJUSTED, "item", item.id, item.name,
               f"Stock {direction} by {abs(delta)} ({old_qty} → {item.quantity}). {notes}",
               quantity_delta=delta, device="web")
    db.session.commit()
    flash(f"Stock updated: {old_qty} → {item.quantity}.", "success")
    return redirect(url_for("items.view", item_id=item.id))


@items_bp.route("/<int:item_id>/delete", methods=["POST"])
@login_required
@admin_required
def delete(item_id):
    item = Item.query.get_or_404(item_id)
    item.is_active = False  # soft delete
    log_action(AuditAction.ITEM_DELETED, "item", item.id, item.name,
               f"Item '{item.name}' removed from system")
    db.session.commit()
    flash(f"Item '{item.name}' removed.", "info")
    return redirect(url_for("items.index"))
