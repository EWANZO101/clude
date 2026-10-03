from flask import Blueprint, request, jsonify
from flask_jwt_extended import jwt_required, current_user
from app.extensions import db
from app.models.item import Item
from app.models.user import User
from app.models.audit_log import AuditAction
from app.utils.audit import log_action
from app.utils.barcode_helper import generate_barcode

api_items_bp = Blueprint("api_items", __name__, url_prefix="/api/items")


def _require_admin():
    # Check the freshly-loaded DB user rather than the JWT's "role" claim,
    # which is fixed at login time and would still say "admin" for up to
    # 8 hours after an admin is demoted.
    if not current_user or current_user.role != "admin":
        return jsonify({"error": "Admin access required"}), 403
    return None


@api_items_bp.route("/", methods=["GET"])
@jwt_required()
def list_items():
    search = request.args.get("q", "").strip()
    stock = request.args.get("stock", "").strip()
    query = Item.query.filter_by(is_active=True)
    if search:
        query = query.filter(Item.name.ilike(f"%{search}%"))
    if stock == "low":
        query = query.filter(Item.quantity <= Item.low_stock_threshold)
    elif stock == "out":
        query = query.filter_by(quantity=0)
    items = query.order_by(Item.name).all()
    return jsonify([i.to_dict() for i in items]), 200


@api_items_bp.route("/<int:item_id>", methods=["GET"])
@jwt_required()
def get_item(item_id):
    item = Item.query.get_or_404(item_id)
    return jsonify(item.to_dict()), 200


@api_items_bp.route("/", methods=["POST"])
@jwt_required()
def create_item():
    err = _require_admin()
    if err:
        return err
    data = request.get_json(silent=True) or {}
    name = data.get("name", "").strip()
    if not name:
        return jsonify({"error": "name is required"}), 400

    item = Item(
        name=name,
        sku=data.get("sku") or None,
        description=data.get("description") or None,
        category=data.get("category") or None,
        location=data.get("location") or None,
        quantity=int(data.get("quantity", 0)),
        unit=data.get("unit") or None,
        low_stock_threshold=int(data.get("low_stock_threshold", 5)),
    )
    db.session.add(item)
    db.session.flush()
    generate_barcode("item", item.id)
    log_action(AuditAction.ITEM_CREATED, "item", item.id, item.name,
               f"Created via API")
    db.session.commit()
    return jsonify(item.to_dict()), 201


@api_items_bp.route("/<int:item_id>", methods=["PUT"])
@jwt_required()
def update_item(item_id):
    err = _require_admin()
    if err:
        return err
    item = Item.query.get_or_404(item_id)
    data = request.get_json(silent=True) or {}
    for field in ["name","sku","description","category","location","unit"]:
        if field in data:
            setattr(item, field, data[field] or None)
    if "quantity" in data:
        item.quantity = int(data["quantity"])
    if "low_stock_threshold" in data:
        item.low_stock_threshold = int(data["low_stock_threshold"])
    log_action(AuditAction.ITEM_UPDATED, "item", item.id, item.name, "Updated via API")
    db.session.commit()
    return jsonify(item.to_dict()), 200


@api_items_bp.route("/<int:item_id>/adjust", methods=["POST"])
@jwt_required()
def adjust_stock(item_id):
    item = Item.query.get_or_404(item_id)
    data = request.get_json(silent=True) or {}
    delta = int(data.get("delta", 0))
    if delta == 0:
        return jsonify({"error": "delta must be non-zero"}), 400
    old = item.quantity
    item.adjust_stock(delta)
    log_action(AuditAction.ITEM_STOCK_ADJUSTED, "item", item.id, item.name,
               f"API stock adjust {old} → {item.quantity}",
               quantity_delta=delta, device="api")
    db.session.commit()
    return jsonify(item.to_dict()), 200


@api_items_bp.route("/<int:item_id>/quick-remove", methods=["POST"])
@jwt_required()
def quick_remove(item_id):
    """
    One-scan stock removal for the kiosk: scan the item barcode, enter a
    quantity, done. Always subtracts (never adds) — quick-remove is
    intentionally one-directional so a shop-floor operator can't
    accidentally add phantom stock with the same fast flow; additions still
    go through the full adjust-stock screen.
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
               f"Kiosk quick-remove {quantity} ({old} → {item.quantity}) on {device}",
               quantity_delta=-quantity, device=device)
    db.session.commit()
    return jsonify(item.to_dict()), 200


@api_items_bp.route("/<int:item_id>", methods=["DELETE"])
@jwt_required()
def delete_item(item_id):
    err = _require_admin()
    if err:
        return err
    item = Item.query.get_or_404(item_id)
    item.is_active = False
    log_action(AuditAction.ITEM_DELETED, "item", item.id, item.name, "Deleted via API")
    db.session.commit()
    return jsonify({"message": f"Item '{item.name}' removed"}), 200
