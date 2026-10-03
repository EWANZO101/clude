from flask import Blueprint, request, jsonify
from app.models import db, Item

items_bp = Blueprint("items", __name__, url_prefix="/api/items")


@items_bp.route("", methods=["GET"])
def list_items():
    q = request.args.get("q", "").strip()
    query = Item.query
    if q:
        query = query.filter(
            db.or_(Item.name.ilike(f"%{q}%"), Item.sku.ilike(f"%{q}%"))
        )
    items = query.order_by(Item.name.asc()).all()
    return jsonify([i.to_dict() for i in items]), 200


@items_bp.route("/<int:item_id>", methods=["GET"])
def get_item(item_id):
    item = db.session.get(Item, item_id)
    if not item:
        return jsonify({"error": "Item not found."}), 404
    return jsonify(item.to_dict()), 200


@items_bp.route("/<int:item_id>/adjust", methods=["POST"])
def adjust_item(item_id):
    """
    Quick stock adjustment — the day-to-day kiosk action. Not full CRUD:
    creating/deleting items is an admin action that happens in the cloud
    admin app and reaches this device only via sync (Part 3).
    """
    item = db.session.get(Item, item_id)
    if not item:
        return jsonify({"error": "Item not found."}), 404

    data = request.get_json(silent=True) or {}
    try:
        delta = int(data.get("delta", 0))
    except (TypeError, ValueError):
        return jsonify({"error": "delta must be an integer."}), 400
    if delta == 0:
        return jsonify({"error": "delta must be non-zero."}), 400

    item.adjust_stock(delta)
    db.session.commit()
    return jsonify(item.to_dict()), 200
