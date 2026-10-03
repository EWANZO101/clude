from flask import Blueprint, render_template, redirect, url_for, flash, request
from adminapp.utils.api_client import api_get, api_post, api_put, api_delete, APIError
from adminapp.utils.decorators import login_required, admin_required
from adminapp.utils.formatting import hydrate, hydrate_list

items_bp = Blueprint("items", __name__, url_prefix="/items")

_DATE_FIELDS = ["created_at", "updated_at"]


def _units_and_categories():
    try:
        catalog = api_get("/api/units/")
        units, measurement_types = catalog["units"], catalog["measurement_types"]
    except APIError:
        units, measurement_types = {}, []
    try:
        all_categories = api_get("/api/categories/")
    except APIError:
        all_categories = []
    return units, measurement_types, all_categories


@items_bp.route("/")
@login_required
def index():
    search = request.args.get("q", "").strip()
    category = request.args.get("category", "").strip()
    stock_filter = request.args.get("stock", "").strip()

    try:
        items = api_get("/api/items/", params={"q": search, "category": category, "stock": stock_filter})
        categories = api_get("/api/items/categories")
    except APIError as e:
        flash(e.message, "danger")
        items, categories = [], []

    hydrate_list(items, _DATE_FIELDS)

    from adminapp.utils.layout_surface import get_published_layout
    from adminapp.utils.layout_columns import COLUMN_META
    layout_components = get_published_layout("admin_items")
    if layout_components:
        total = len(items)
        low_stock = sum(1 for i in items if i.get("is_low_stock"))
        out_of_stock = sum(1 for i in items if i.get("quantity") == 0)
        stats = {
            "total": {"value": total, "label": "Total items"},
            "low_stock": {"value": low_stock, "label": "Low stock"},
            "out_of_stock": {"value": out_of_stock, "label": "Out of stock"},
        }
        return render_template(
            "items/index_generic.html", items=items, categories=categories,
            search=search, category=category, stock_filter=stock_filter,
            layout_components=layout_components, column_meta=COLUMN_META["items"], stats=stats,
        )

    return render_template("items/index.html", items=items, categories=categories,
                            search=search, category=category, stock_filter=stock_filter)


@items_bp.route("/add", methods=["GET", "POST"])
@login_required
@admin_required
def add():
    units_by_type, measurement_types, all_categories = _units_and_categories()

    if request.method == "POST":
        name = request.form.get("name", "").strip()
        if not name:
            flash("Item name is required.", "danger")
            return render_template("items/form.html", item=None, action="Add",
                                    units_by_type=units_by_type, measurement_types=measurement_types,
                                    all_categories=all_categories)

        measurement_type = request.form.get("measurement_type", "count")
        try:
            item = api_post("/api/items/", {
                "name": name,
                "sku": request.form.get("sku", "").strip() or None,
                "description": request.form.get("description", "").strip() or None,
                "category": request.form.get("category", "").strip() or None,
                "location": request.form.get("location", "").strip() or None,
                "quantity": int(request.form.get("quantity", 0) or 0),
                "measurement_type": measurement_type,
                "unit": request.form.get("unit", "").strip() or None,
                "stock_amount": request.form.get("stock_amount") if measurement_type != "count" else None,
                "low_stock_threshold": int(request.form.get("low_stock_threshold", 5) or 5),
                "category_ids": [int(x) for x in request.form.getlist("category_ids")],
            })
        except APIError as e:
            flash(e.message, "danger")
            return render_template("items/form.html", item=None, action="Add",
                                    units_by_type=units_by_type, measurement_types=measurement_types,
                                    all_categories=all_categories)

        flash(f"Item '{item['name']}' added successfully.", "success")
        return redirect(url_for("items.index"))

    return render_template("items/form.html", item=None, action="Add",
                            units_by_type=units_by_type, measurement_types=measurement_types,
                            all_categories=all_categories)


@items_bp.route("/<int:item_id>")
@login_required
def view(item_id):
    try:
        item = api_get(f"/api/items/{item_id}")
    except APIError as e:
        flash(e.message, "danger")
        return redirect(url_for("items.index"))
    hydrate(item, _DATE_FIELDS)
    return render_template("items/view.html", item=item)


@items_bp.route("/<int:item_id>/edit", methods=["GET", "POST"])
@login_required
@admin_required
def edit(item_id):
    units_by_type, measurement_types, all_categories = _units_and_categories()
    try:
        item = api_get(f"/api/items/{item_id}")
    except APIError as e:
        flash(e.message, "danger")
        return redirect(url_for("items.index"))

    if request.method == "POST":
        name = request.form.get("name", "").strip()
        if not name:
            flash("Item name is required.", "danger")
            return render_template("items/form.html", item=item, action="Edit",
                                    units_by_type=units_by_type, measurement_types=measurement_types,
                                    all_categories=all_categories)

        measurement_type = request.form.get("measurement_type", "count")
        try:
            item = api_put(f"/api/items/{item_id}", {
                "name": name,
                "sku": request.form.get("sku", "").strip() or None,
                "description": request.form.get("description", "").strip() or None,
                "category": request.form.get("category", "").strip() or None,
                "location": request.form.get("location", "").strip() or None,
                "measurement_type": measurement_type,
                "unit": request.form.get("unit", "").strip() or None,
                "stock_amount": request.form.get("stock_amount") if measurement_type != "count" else None,
                "low_stock_threshold": int(request.form.get("low_stock_threshold", 5) or 5),
                "category_ids": [int(x) for x in request.form.getlist("category_ids")],
            })
        except APIError as e:
            flash(e.message, "danger")
            return render_template("items/form.html", item=item, action="Edit",
                                    units_by_type=units_by_type, measurement_types=measurement_types,
                                    all_categories=all_categories)

        flash(f"Item '{item['name']}' updated.", "success")
        return redirect(url_for("items.view", item_id=item["id"]))

    return render_template("items/form.html", item=item, action="Edit",
                            units_by_type=units_by_type, measurement_types=measurement_types,
                            all_categories=all_categories)


@items_bp.route("/<int:item_id>/adjust", methods=["POST"])
@login_required
def adjust_stock(item_id):
    delta = int(request.form.get("delta", 0) or 0)
    notes = request.form.get("notes", "").strip()

    if delta == 0:
        flash("Please enter a non-zero adjustment.", "warning")
        return redirect(url_for("items.view", item_id=item_id))

    try:
        item = api_post(f"/api/items/{item_id}/adjust", {"delta": delta, "notes": notes, "device": "web"})
    except APIError as e:
        flash(e.message, "danger")
        return redirect(url_for("items.view", item_id=item_id))

    flash(f"Stock updated to {item['quantity']}.", "success")
    return redirect(url_for("items.view", item_id=item_id))


@items_bp.route("/<int:item_id>/delete", methods=["POST"])
@login_required
@admin_required
def delete(item_id):
    try:
        result = api_delete(f"/api/items/{item_id}")
    except APIError as e:
        flash(e.message, "danger")
        return redirect(url_for("items.index"))

    flash(result.get("message", "Item removed."), "info")
    return redirect(url_for("items.index"))
