import csv
import io
from flask import Blueprint, request, jsonify, Response
from app.models import db, Item, ActivityEvent, IssuanceEvent
from app.auth import permission_required
from app.reporting import compute_item_anomalies

items_bp = Blueprint("items", __name__, url_prefix="/api/items")


@items_bp.route("", methods=["GET"])
def list_items():
    q = request.args.get("q", "").strip()
    category = request.args.get("category", "").strip()
    query = Item.query
    if q:
        query = query.filter(
            db.or_(Item.name.ilike(f"%{q}%"), Item.sku.ilike(f"%{q}%"))
        )
    if category:
        query = query.filter_by(category=category)
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

    adjusted_by = (data.get("adjusted_by") or "").strip() or None
    project = (data.get("project") or "").strip() or None
    item.adjust_stock(delta, adjusted_by=adjusted_by, project=project)
    ActivityEvent.log(
        ActivityEvent.TYPE_ITEM_ADJUST, item.name, actor=adjusted_by, project=project,
        detail=f"{'+' if delta > 0 else ''}{delta} (now {item.quantity})",
    )
    # A negative delta with a named employee is an issuance -- log it
    # as structured IssuanceEvent data (Items/Consumables + PPE
    # per-employee transaction history), on top of the flat ActivityEvent
    # feed above.
    if delta < 0 and adjusted_by:
        db.session.add(IssuanceEvent(
            item_id=item.id, employee=adjusted_by, quantity=abs(delta), project=project,
        ))
    db.session.commit()
    return jsonify(item.to_dict()), 200


@items_bp.route("/<int:item_id>/history", methods=["GET"])
def item_history(item_id):
    """Full issuance history for one item: every transaction, plus a
    per-employee total so unusual/excessive usage stands out (spec
    item 3's grinding-disks example)."""
    item = db.session.get(Item, item_id)
    if not item:
        return jsonify({"error": "Item not found."}), 404

    events = (IssuanceEvent.query.filter_by(item_id=item.id)
              .order_by(IssuanceEvent.created_at.desc()).all())

    totals_by_employee = {}
    for e in events:
        totals_by_employee[e.employee] = totals_by_employee.get(e.employee, 0) + e.quantity
    per_employee = sorted(
        ({"employee": emp, "total_quantity": qty} for emp, qty in totals_by_employee.items()),
        key=lambda r: r["total_quantity"], reverse=True,
    )

    return jsonify({
        "item": item.to_dict(),
        "total_quantity_issued": sum(e.quantity for e in events),
        "per_employee": per_employee,
        "transactions": [e.to_dict() for e in events],
        "anomalies": compute_item_anomalies(item),
    }), 200


@items_bp.route("/<int:item_id>/history/export", methods=["GET"])
def item_history_export(item_id):
    """Printable/exportable CSV of an item's transaction history."""
    item = db.session.get(Item, item_id)
    if not item:
        return jsonify({"error": "Item not found."}), 404

    events = (IssuanceEvent.query.filter_by(item_id=item.id)
              .order_by(IssuanceEvent.created_at.asc()).all())

    buf = io.StringIO()
    w = csv.writer(buf)
    w.writerow(["Item", item.name])
    w.writerow(["Total Quantity Issued", sum(e.quantity for e in events)])
    w.writerow([])
    w.writerow(["Employee", "Quantity", "Project", "Date/Time"])
    for e in events:
        w.writerow([e.employee, e.quantity, e.project or "", e.created_at])

    safe_name = "".join(c if c.isalnum() or c in "-_" else "_" for c in item.name)
    return Response(
        buf.getvalue(),
        mimetype="text/csv",
        headers={"Content-Disposition": f'attachment; filename="item_{safe_name}_history.csv"'},
    )


@items_bp.route("/<int:item_id>/category", methods=["POST"])
@permission_required("admin", "supervisor")
def set_item_category(item_id):
    """PPE (spec item 4) is just an Item with category='ppe' -- this is
    what moves an item in/out of that dedicated category."""
    item = db.session.get(Item, item_id)
    if not item:
        return jsonify({"error": "Item not found."}), 404
    data = request.get_json(silent=True) or {}
    category = (data.get("category") or "").strip()
    if not category:
        return jsonify({"error": "category is required."}), 400
    item.category = category
    item.dirty = True
    db.session.commit()
    return jsonify(item.to_dict()), 200


@items_bp.route("/<int:item_id>/normal-interval", methods=["POST"])
@permission_required("admin", "supervisor")
def set_item_normal_interval(item_id):
    """Sets the expected re-issue gap (days) an item's usage anomalies
    (spec item 4's 'issued 3x in one week when normally once a month'
    example) are compared against. Pass null/0 to clear it."""
    item = db.session.get(Item, item_id)
    if not item:
        return jsonify({"error": "Item not found."}), 404
    data = request.get_json(silent=True) or {}
    days = data.get("normal_interval_days")
    if days in (None, 0, ""):
        item.normal_interval_days = None
    else:
        try:
            item.normal_interval_days = float(days)
        except (TypeError, ValueError):
            return jsonify({"error": "normal_interval_days must be a number."}), 400
    item.dirty = True
    db.session.commit()
    return jsonify(item.to_dict()), 200
