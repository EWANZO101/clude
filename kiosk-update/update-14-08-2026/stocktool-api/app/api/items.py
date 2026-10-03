from flask import Blueprint, request, jsonify
from flask_jwt_extended import jwt_required, current_user
from app.extensions import db
from app.models.item import Item
from app.models.category import Category
from app.models.audit_log import AuditAction
from app.utils.decorators import admin_required
from app.utils.audit import log_action
from app.utils.barcode_helper import generate_barcode
from app.units import normalise_measurement

api_items_bp = Blueprint("api_items", __name__, url_prefix="/api/items")


@api_items_bp.route("/", methods=["GET"])
@jwt_required()
def list_items():
    search = request.args.get("q", "").strip()
    category = request.args.get("category", "").strip()
    category_id = request.args.get("category_id", "").strip()
    stock = request.args.get("stock", "").strip()
    query = Item.query.filter_by(is_active=True)
    if search:
        query = query.filter(Item.name.ilike(f"%{search}%") | Item.sku.ilike(f"%{search}%"))
    if category:
        query = query.filter_by(category=category)
    if category_id:
        query = query.filter(Item.categories.any(id=int(category_id)))
    if stock == "low":
        query = query.filter(Item.quantity <= Item.low_stock_threshold, Item.quantity > 0)
    elif stock == "out":
        query = query.filter_by(quantity=0)
    items = query.order_by(Item.name).all()
    return jsonify([i.to_dict() for i in items]), 200


@api_items_bp.route("/categories", methods=["GET"])
@jwt_required()
def list_categories():
    rows = db.session.query(Item.category).filter(
        Item.is_active == True, Item.category != None
    ).distinct().all()
    return jsonify(sorted(c[0] for c in rows)), 200


@api_items_bp.route("/<int:item_id>", methods=["GET"])
@jwt_required()
def get_item(item_id):
    item = Item.query.get_or_404(item_id)
    return jsonify(item.to_dict()), 200


@api_items_bp.route("/", methods=["POST"])
@jwt_required()
@admin_required
def create_item():
    data = request.get_json(silent=True) or {}
    name = data.get("name", "").strip()
    if not name:
        return jsonify({"error": "name is required"}), 400

    measurement_type, unit = normalise_measurement(
        data.get("measurement_type", "count"), data.get("unit")
    )
    item = Item(
        name=name,
        sku=data.get("sku") or None,
        description=data.get("description") or None,
        category=data.get("category") or None,
        location=data.get("location") or None,
        quantity=int(data.get("quantity", 0)) if measurement_type == "count" else 0,
        measurement_type=measurement_type,
        unit=unit,
        stock_amount=float(data["stock_amount"]) if data.get("stock_amount") not in (None, "") else None,
        low_stock_threshold=int(data.get("low_stock_threshold", 5)),
    )
    if data.get("category_ids"):
        item.categories = Category.query.filter(Category.id.in_(data["category_ids"])).all()
    db.session.add(item)
    db.session.flush()
    generate_barcode("item", item.id)
    log_action(AuditAction.ITEM_CREATED, "item", item.id, item.name,
               f"Item '{item.name}' created with qty {item.quantity}", user=current_user)
    db.session.commit()
    return jsonify(item.to_dict()), 201


@api_items_bp.route("/<int:item_id>", methods=["PUT"])
@jwt_required()
@admin_required
def update_item(item_id):
    item = Item.query.get_or_404(item_id)
    data = request.get_json(silent=True) or {}
    if "name" in data and not data["name"].strip():
        return jsonify({"error": "name cannot be empty"}), 400
    for field in ["name", "sku", "description", "category", "location"]:
        if field in data:
            setattr(item, field, (data[field] or None) if isinstance(data[field], str) else data[field])
    if "low_stock_threshold" in data:
        item.low_stock_threshold = int(data["low_stock_threshold"])

    if "measurement_type" in data or "unit" in data:
        item.set_measurement(data.get("measurement_type", item.measurement_type),
                              data.get("unit", item.unit))
    if "stock_amount" in data:
        item.stock_amount = float(data["stock_amount"]) if data["stock_amount"] not in (None, "") else None
    if "category_ids" in data:
        item.categories = Category.query.filter(Category.id.in_(data["category_ids"] or [])).all()

    log_action(AuditAction.ITEM_UPDATED, "item", item.id, item.name,
               f"Item '{item.name}' updated", user=current_user)
    db.session.commit()
    return jsonify(item.to_dict()), 200


@api_items_bp.route("/<int:item_id>/adjust", methods=["POST"])
@jwt_required()
def adjust_stock(item_id):
    item = Item.query.get_or_404(item_id)
    data = request.get_json(silent=True) or {}
    delta = int(data.get("delta", 0))
    notes = data.get("notes", "")
    device = data.get("device", "").strip() or "api"
    if delta == 0:
        return jsonify({"error": "delta must be non-zero"}), 400
    old = item.quantity
    item.adjust_stock(delta)
    direction = "increased" if delta > 0 else "decreased"
    log_action(AuditAction.ITEM_STOCK_ADJUSTED, "item", item.id, item.name,
               f"Stock {direction} by {abs(delta)} ({old} → {item.quantity}). {notes}",
               user=current_user, quantity_delta=delta, device=device)
    db.session.commit()
    return jsonify(item.to_dict()), 200


@api_items_bp.route("/<int:item_id>/adjust-amount", methods=["POST"])
@jwt_required()
def adjust_amount(item_id):
    """Counterpart to /adjust for weight/volume/length-tracked items, where
    stock is a decimal amount rather than a whole-unit count."""
    item = Item.query.get_or_404(item_id)
    if item.measurement_type == "count":
        return jsonify({"error": "This item is tracked by count — use /adjust instead."}), 400

    data = request.get_json(silent=True) or {}
    delta = data.get("delta")
    if delta is None:
        return jsonify({"error": "delta is required"}), 400
    delta = float(delta)
    notes = data.get("notes", "")
    device = data.get("device", "").strip() or "api"

    old = item.stock_amount or 0
    item.stock_amount = max(0.0, old + delta)
    direction = "increased" if delta > 0 else "decreased"
    log_action(AuditAction.ITEM_STOCK_ADJUSTED, "item", item.id, item.name,
               f"Stock {direction} by {abs(delta):g}{item.unit or ''} "
               f"({old:g} → {item.stock_amount:g}). {notes}",
               user=current_user, device=device)
    db.session.commit()
    return jsonify(item.to_dict()), 200


@api_items_bp.route("/<int:item_id>/quick-remove", methods=["POST"])
@jwt_required()
def quick_remove(item_id):
    """
    One-scan stock removal for the kiosk: scan the item barcode, enter a
    quantity, done. Always subtracts (never adds) — quick-remove is
    intentionally one-directional so a shop-floor operator can't
    accidentally add phantom stock with the same fast flow; additions
    still go through the full adjust-stock endpoint/screen.
    """
    item = Item.query.get_or_404(item_id)
    data = request.get_json(silent=True) or {}
    quantity = int(data.get("quantity", 0))
    device = data.get("device", "").strip() or "kiosk"

    if quantity <= 0:
        return jsonify({"error": "quantity must be a positive number"}), 400

    old = item.quantity
    item.adjust_stock(-quantity)
    log_action(AuditAction.KIOSK_QUICK_REMOVE, "item", item.id, item.name,
               f"Quick-remove {quantity} ({old} → {item.quantity}) on {device}",
               user=current_user, quantity_delta=-quantity, device=device)
    db.session.commit()
    return jsonify(item.to_dict()), 200


@api_items_bp.route("/<int:item_id>", methods=["DELETE"])
@jwt_required()
@admin_required
def delete_item(item_id):
    item = Item.query.get_or_404(item_id)
    item.is_active = False
    log_action(AuditAction.ITEM_DELETED, "item", item.id, item.name,
               "Deleted via API", user=current_user)
    db.session.commit()
    return jsonify({"message": f"Item '{item.name}' removed"}), 200
