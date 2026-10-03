"""
PPE (spec item 4) -- a dedicated URL surface on top of Item/IssuanceEvent
(category='ppe'), rather than PPE being just another filter someone has
to remember to apply on /api/items. Reuses everything Items already has
(adjust, history, export) via app.reporting so the anomaly logic is
identical to consumables -- PPE just gets its own namespace and list.
"""
from flask import Blueprint, jsonify
from app.models import db, Item, IssuanceEvent
from app.reporting import compute_item_anomalies, get_ppe_anomalies

ppe_bp = Blueprint("ppe", __name__, url_prefix="/api/ppe")


@ppe_bp.route("", methods=["GET"])
def list_ppe():
    items = Item.query.filter_by(category=Item.CATEGORY_PPE).order_by(Item.name.asc()).all()
    return jsonify([i.to_dict() for i in items]), 200


@ppe_bp.route("/<int:item_id>", methods=["GET"])
def get_ppe_item(item_id):
    item = db.session.get(Item, item_id)
    if not item or item.category != Item.CATEGORY_PPE:
        return jsonify({"error": "PPE item not found."}), 404
    return jsonify(item.to_dict()), 200


@ppe_bp.route("/<int:item_id>/history", methods=["GET"])
def ppe_item_history(item_id):
    """Who received it, when, how many times, usage per employee --
    spec item 4's PPE requirements, identical shape to the Items
    history endpoint but scoped to category='ppe'."""
    item = db.session.get(Item, item_id)
    if not item or item.category != Item.CATEGORY_PPE:
        return jsonify({"error": "PPE item not found."}), 404

    events = (IssuanceEvent.query.filter_by(item_id=item.id)
              .order_by(IssuanceEvent.created_at.desc()).all())
    totals_by_employee = {}
    counts_by_employee = {}
    for e in events:
        totals_by_employee[e.employee] = totals_by_employee.get(e.employee, 0) + e.quantity
        counts_by_employee[e.employee] = counts_by_employee.get(e.employee, 0) + 1
    per_employee = sorted(
        ({"employee": emp, "total_quantity": totals_by_employee[emp], "times_received": counts_by_employee[emp]}
         for emp in totals_by_employee),
        key=lambda r: r["times_received"], reverse=True,
    )

    return jsonify({
        "item": item.to_dict(),
        "per_employee": per_employee,
        "transactions": [e.to_dict() for e in events],
        "anomalies": compute_item_anomalies(item),
    }), 200


@ppe_bp.route("/anomalies", methods=["GET"])
def ppe_anomalies():
    """Unusual PPE consumption across every PPE item at once -- spec
    item 4's 'highlight unusual consumption' requirement."""
    return jsonify(get_ppe_anomalies()), 200
