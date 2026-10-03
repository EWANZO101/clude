from flask import Blueprint, request, jsonify
from flask_jwt_extended import jwt_required, current_user
from app.extensions import db
from app.models.category import Category, slugify
from app.models.item import Item
from app.models.tool import Tool
from app.models.audit_log import AuditAction
from app.utils.decorators import admin_required
from app.utils.audit import log_action

api_categories_bp = Blueprint("api_categories", __name__, url_prefix="/api/categories")


def _unique_slug(name: str, exclude_id: int = None) -> str:
    base = slugify(name)
    slug = base
    n = 2
    while True:
        q = Category.query.filter_by(slug=slug)
        if exclude_id:
            q = q.filter(Category.id != exclude_id)
        if not q.first():
            return slug
        slug = f"{base}-{n}"
        n += 1


@api_categories_bp.route("/", methods=["GET"])
@jwt_required()
def list_categories():
    categories = Category.query.order_by(Category.sort_order, Category.name).all()
    return jsonify([c.to_dict() for c in categories]), 200


@api_categories_bp.route("/<int:category_id>", methods=["GET"])
@jwt_required()
def get_category(category_id):
    category = Category.query.get_or_404(category_id)
    data = category.to_dict()
    data["items"] = [i.to_dict() for i in category.items if i.is_active]
    data["tools"] = [t.to_dict() for t in category.tools if t.is_active]
    return jsonify(data), 200


@api_categories_bp.route("/", methods=["POST"])
@jwt_required()
@admin_required
def create_category():
    data = request.get_json(silent=True) or {}
    name = (data.get("name") or "").strip()
    if not name:
        return jsonify({"error": "name is required"}), 400

    max_order = db.session.query(db.func.max(Category.sort_order)).scalar() or 0
    category = Category(
        name=name,
        slug=_unique_slug(name),
        icon=(data.get("icon") or "").strip() or None,
        color=(data.get("color") or "").strip() or None,
        sort_order=int(data.get("sort_order", max_order + 1)),
    )
    db.session.add(category)
    db.session.flush()
    log_action(AuditAction.CATEGORY_CREATED, "category", category.id, category.name,
               f"Category '{category.name}' created", user=current_user)
    db.session.commit()
    return jsonify(category.to_dict()), 201


@api_categories_bp.route("/<int:category_id>", methods=["PUT", "PATCH"])
@jwt_required()
@admin_required
def update_category(category_id):
    category = Category.query.get_or_404(category_id)
    data = request.get_json(silent=True) or {}

    if "name" in data:
        name = (data["name"] or "").strip()
        if not name:
            return jsonify({"error": "name cannot be empty"}), 400
        if name != category.name:
            category.slug = _unique_slug(name, exclude_id=category.id)
        category.name = name
    if "icon" in data:
        category.icon = (data["icon"] or "").strip() or None
    if "color" in data:
        category.color = (data["color"] or "").strip() or None
    if "sort_order" in data:
        category.sort_order = int(data["sort_order"])

    log_action(AuditAction.CATEGORY_UPDATED, "category", category.id, category.name,
               f"Category '{category.name}' updated", user=current_user)
    db.session.commit()
    return jsonify(category.to_dict()), 200


@api_categories_bp.route("/reorder", methods=["POST"])
@jwt_required()
@admin_required
def reorder_categories():
    """Body: {"order": [category_id, category_id, ...]} — sets sort_order
    to each id's position in the list. Used by the admin drag-reorder UI
    and the Builder Mode category picker."""
    data = request.get_json(silent=True) or {}
    order = data.get("order") or []
    if not isinstance(order, list) or not order:
        return jsonify({"error": "order must be a non-empty list of category ids"}), 400

    categories = {c.id: c for c in Category.query.filter(Category.id.in_(order)).all()}
    missing = [cid for cid in order if cid not in categories]
    if missing:
        return jsonify({"error": f"Unknown category ids: {missing}"}), 400

    for index, cid in enumerate(order):
        categories[cid].sort_order = index

    log_action(AuditAction.CATEGORY_REORDERED, "category", None, None,
               f"Reordered {len(order)} categories", user=current_user)
    db.session.commit()
    return jsonify([categories[cid].to_dict() for cid in order]), 200


@api_categories_bp.route("/<int:category_id>", methods=["DELETE"])
@jwt_required()
@admin_required
def delete_category(category_id):
    category = Category.query.get_or_404(category_id)
    name = category.name
    db.session.delete(category)
    log_action(AuditAction.CATEGORY_DELETED, "category", category_id, name,
               f"Category '{name}' deleted", user=current_user)
    db.session.commit()
    return jsonify({"message": f"Category '{name}' removed"}), 200


# ── Assignment ────────────────────────────────────────────────────────────
# Items/tools can belong to any number of categories, so assignment is a
# full-replace: send the complete list of category ids the entity should
# now belong to. This matches how the admin UI's checkbox picker works and
# avoids a separate add/remove endpoint pair for every combination.

@api_categories_bp.route("/assign/items/<int:item_id>", methods=["PUT"])
@jwt_required()
@admin_required
def assign_item_categories(item_id):
    item = Item.query.get_or_404(item_id)
    data = request.get_json(silent=True) or {}
    category_ids = data.get("category_ids") or []
    categories = Category.query.filter(Category.id.in_(category_ids)).all()
    found_ids = {c.id for c in categories}
    missing = [cid for cid in category_ids if cid not in found_ids]
    if missing:
        return jsonify({"error": f"Unknown category ids: {missing}"}), 400

    item.categories = categories
    log_action(AuditAction.ITEM_UPDATED, "item", item.id, item.name,
               f"Categories set to: {', '.join(c.name for c in categories) or '(none)'}",
               user=current_user)
    db.session.commit()
    return jsonify(item.to_dict()), 200


@api_categories_bp.route("/assign/tools/<int:tool_id>", methods=["PUT"])
@jwt_required()
@admin_required
def assign_tool_categories(tool_id):
    tool = Tool.query.get_or_404(tool_id)
    data = request.get_json(silent=True) or {}
    category_ids = data.get("category_ids") or []
    categories = Category.query.filter(Category.id.in_(category_ids)).all()
    found_ids = {c.id for c in categories}
    missing = [cid for cid in category_ids if cid not in found_ids]
    if missing:
        return jsonify({"error": f"Unknown category ids: {missing}"}), 400

    tool.categories = categories
    log_action(AuditAction.TOOL_UPDATED, "tool", tool.id, tool.name,
               f"Categories set to: {', '.join(c.name for c in categories) or '(none)'}",
               user=current_user)
    db.session.commit()
    return jsonify(tool.to_dict()), 200
