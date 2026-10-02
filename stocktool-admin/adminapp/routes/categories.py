from flask import Blueprint, render_template, redirect, url_for, flash, request, jsonify
from adminapp.utils.api_client import api_get, api_post, api_put, api_delete, APIError
from adminapp.utils.decorators import login_required, admin_required

categories_bp = Blueprint("categories", __name__, url_prefix="/categories")


@categories_bp.route("/")
@login_required
def index():
    try:
        categories = api_get("/api/categories/")
    except APIError as e:
        flash(e.message, "danger")
        categories = []

    from adminapp.utils.layout_surface import get_published_layout
    layout_components = get_published_layout("admin_categories")
    return render_template("categories/index.html", categories=categories, layout_components=layout_components)


@categories_bp.route("/add", methods=["POST"])
@login_required
@admin_required
def add():
    name = request.form.get("name", "").strip()
    if not name:
        flash("Category name is required.", "danger")
        return redirect(url_for("categories.index"))
    try:
        api_post("/api/categories/", {
            "name": name,
            "icon": request.form.get("icon", "").strip() or None,
            "color": request.form.get("color", "").strip() or None,
        })
        flash(f"Category '{name}' created.", "success")
    except APIError as e:
        flash(e.message, "danger")
    return redirect(url_for("categories.index"))


@categories_bp.route("/<int:category_id>/edit", methods=["POST"])
@login_required
@admin_required
def edit(category_id):
    name = request.form.get("name", "").strip()
    if not name:
        flash("Category name is required.", "danger")
        return redirect(url_for("categories.index"))
    try:
        api_put(f"/api/categories/{category_id}", {
            "name": name,
            "icon": request.form.get("icon", "").strip() or None,
            "color": request.form.get("color", "").strip() or None,
        })
        flash(f"Category '{name}' updated.", "success")
    except APIError as e:
        flash(e.message, "danger")
    return redirect(url_for("categories.index"))


@categories_bp.route("/<int:category_id>/delete", methods=["POST"])
@login_required
@admin_required
def delete(category_id):
    try:
        result = api_delete(f"/api/categories/{category_id}")
        flash(result.get("message", "Category removed."), "info")
    except APIError as e:
        flash(e.message, "danger")
    return redirect(url_for("categories.index"))


@categories_bp.route("/reorder", methods=["POST"])
@login_required
@admin_required
def reorder():
    """AJAX endpoint the drag-reorder list posts to. Body: JSON {"order": [...]}"""
    data = request.get_json(silent=True) or {}
    try:
        api_post("/api/categories/reorder", {"order": data.get("order", [])})
        return jsonify({"ok": True})
    except APIError as e:
        return jsonify({"ok": False, "error": e.message}), e.status_code
