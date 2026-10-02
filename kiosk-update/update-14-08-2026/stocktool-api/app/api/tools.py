from datetime import datetime, timezone, date
from flask import Blueprint, request, jsonify
from flask_jwt_extended import jwt_required, current_user
from app.extensions import db
from app.models.tool import Tool, ToolStatus
from app.models.tool_history import ToolHistory, HistoryAction
from app.models.audit_log import AuditAction
from app.utils.decorators import admin_required
from app.utils.audit import log_action
from app.utils.barcode_helper import generate_barcode

api_tools_bp = Blueprint("api_tools", __name__, url_prefix="/api/tools")


@api_tools_bp.route("/", methods=["GET"])
@jwt_required()
def list_tools():
    status = request.args.get("status", "").strip()
    category = request.args.get("category", "").strip()
    search = request.args.get("q", "").strip()
    overdue_only = request.args.get("overdue", "").strip().lower() == "true"
    query = Tool.query.filter_by(is_active=True)
    if status:
        query = query.filter_by(status=status)
    if category:
        query = query.filter_by(category=category)
    if search:
        query = query.filter(
            Tool.name.ilike(f"%{search}%") |
            Tool.tool_number.ilike(f"%{search}%") |
            Tool.serial_number.ilike(f"%{search}%")
        )
    tools = query.order_by(Tool.name).all()
    if overdue_only:
        tools = [t for t in tools if t.is_overdue]
    return jsonify([t.to_dict() for t in tools]), 200


@api_tools_bp.route("/categories", methods=["GET"])
@jwt_required()
def list_categories():
    rows = db.session.query(Tool.category).filter(
        Tool.is_active == True, Tool.category != None
    ).distinct().all()
    return jsonify(sorted(c[0] for c in rows)), 200


@api_tools_bp.route("/<int:tool_id>", methods=["GET"])
@jwt_required()
def get_tool(tool_id):
    tool = Tool.query.get_or_404(tool_id)
    return jsonify(tool.to_dict()), 200


@api_tools_bp.route("/", methods=["POST"])
@jwt_required()
@admin_required
def create_tool():
    data = request.get_json(silent=True) or {}
    name = data.get("name", "").strip()
    if not name:
        return jsonify({"error": "name is required"}), 400

    purchase_date = None
    if data.get("purchase_date"):
        try:
            purchase_date = date.fromisoformat(data["purchase_date"])
        except ValueError:
            return jsonify({"error": "purchase_date must be YYYY-MM-DD"}), 400

    tool = Tool(
        name=name,
        tool_number=data.get("tool_number") or None,
        brand=data.get("brand") or None,
        model=data.get("model") or None,
        serial_number=data.get("serial_number") or None,
        description=data.get("description") or None,
        category=data.get("category") or None,
        location=data.get("location") or None,
        status=ToolStatus.AVAILABLE,
        purchase_date=purchase_date,
        purchase_price=float(data["purchase_price"]) if data.get("purchase_price") else None,
    )
    if data.get("category_ids"):
        from app.models.category import Category
        tool.categories = Category.query.filter(Category.id.in_(data["category_ids"])).all()
    db.session.add(tool)
    db.session.flush()
    generate_barcode("tool", tool.id)
    log_action(AuditAction.TOOL_CREATED, "tool", tool.id, tool.name,
               "Created via API", user=current_user)
    db.session.commit()
    return jsonify(tool.to_dict()), 201


@api_tools_bp.route("/<int:tool_id>", methods=["PUT"])
@jwt_required()
@admin_required
def update_tool(tool_id):
    tool = Tool.query.get_or_404(tool_id)
    data = request.get_json(silent=True) or {}
    for field in ["name", "tool_number", "brand", "model", "serial_number",
                  "description", "category", "location", "condition_notes"]:
        if field in data:
            setattr(tool, field, data[field] or None)
    if "purchase_date" in data:
        if data["purchase_date"]:
            try:
                tool.purchase_date = date.fromisoformat(data["purchase_date"])
            except ValueError:
                return jsonify({"error": "purchase_date must be YYYY-MM-DD"}), 400
        else:
            tool.purchase_date = None
    if "purchase_price" in data:
        tool.purchase_price = float(data["purchase_price"]) if data["purchase_price"] else None
    if "category_ids" in data:
        from app.models.category import Category
        tool.categories = Category.query.filter(Category.id.in_(data["category_ids"] or [])).all()
    log_action(AuditAction.TOOL_UPDATED, "tool", tool.id, tool.name,
               "Updated via API", user=current_user)
    db.session.commit()
    return jsonify(tool.to_dict()), 200


@api_tools_bp.route("/<int:tool_id>/status", methods=["POST"])
@jwt_required()
@admin_required
def change_status(tool_id):
    tool = Tool.query.get_or_404(tool_id)
    data = request.get_json(silent=True) or {}
    new_status = data.get("status", "").strip()
    notes = data.get("notes", "")

    if new_status not in ToolStatus.ALL:
        return jsonify({"error": "Invalid status"}), 400

    old_status = tool.status
    history = ToolHistory(
        tool_id=tool.id, user_id=current_user.id,
        action=HistoryAction.STATUS_CHANGED,
        from_status=old_status, to_status=new_status, notes=notes,
    )
    db.session.add(history)

    tool.status = new_status
    if new_status != ToolStatus.CHECKED_OUT:
        tool.checked_out_by_id = None
        tool.checked_out_at = None

    log_action(AuditAction.TOOL_STATUS_CHANGED, "tool", tool.id, tool.name,
               f"Status changed: {old_status} → {new_status}", user=current_user)
    db.session.commit()
    return jsonify(tool.to_dict()), 200


@api_tools_bp.route("/<int:tool_id>/checkout", methods=["POST"])
@jwt_required()
def checkout(tool_id):
    tool = Tool.query.get_or_404(tool_id)
    if not tool.is_available:
        return jsonify({"error": f"Tool not available. Status: {tool.status}"}), 409

    data = request.get_json(silent=True) or {}
    notes = data.get("notes", "")
    now = datetime.now(timezone.utc)

    tool.status = ToolStatus.CHECKED_OUT
    tool.checked_out_by_id = current_user.id
    tool.checked_out_at = now

    history = ToolHistory(
        tool_id=tool.id, user_id=current_user.id,
        action=HistoryAction.CHECKED_OUT,
        from_status=ToolStatus.AVAILABLE,
        to_status=ToolStatus.CHECKED_OUT,
        notes=notes, checked_out_at=now,
    )
    db.session.add(history)
    log_action(AuditAction.TOOL_CHECKED_OUT, "tool", tool.id, tool.name,
               "Checkout via API", user=current_user)
    db.session.commit()
    return jsonify(tool.to_dict()), 200


@api_tools_bp.route("/<int:tool_id>/checkin", methods=["POST"])
@jwt_required()
def checkin(tool_id):
    tool = Tool.query.get_or_404(tool_id)
    if tool.status != ToolStatus.CHECKED_OUT:
        return jsonify({"error": "Tool is not checked out"}), 409

    data = request.get_json(silent=True) or {}
    notes = data.get("notes", "")
    condition = data.get("condition", ToolStatus.AVAILABLE)
    if condition not in ToolStatus.ALL:
        condition = ToolStatus.AVAILABLE
    now = datetime.now(timezone.utc)

    open_record = (
        ToolHistory.query
        .filter_by(tool_id=tool.id, action=HistoryAction.CHECKED_OUT)
        .filter(ToolHistory.checked_in_at == None)
        .order_by(ToolHistory.created_at.desc()).first()
    )
    if open_record:
        open_record.checked_in_at = now

    ci = ToolHistory(
        tool_id=tool.id, user_id=current_user.id,
        action=HistoryAction.CHECKED_IN,
        from_status=ToolStatus.CHECKED_OUT,
        to_status=condition, notes=notes, checked_in_at=now,
    )
    db.session.add(ci)
    tool.status = condition
    tool.checked_out_by_id = None
    tool.checked_out_at = None
    log_action(AuditAction.TOOL_CHECKED_IN, "tool", tool.id, tool.name,
               "Checkin via API", user=current_user)
    db.session.commit()
    return jsonify(tool.to_dict()), 200


@api_tools_bp.route("/<int:tool_id>/history", methods=["GET"])
@jwt_required()
def history(tool_id):
    tool = Tool.query.get_or_404(tool_id)
    limit = request.args.get("limit", 50, type=int)
    records = tool.history.limit(limit).all()
    return jsonify([r.to_dict() for r in records]), 200


@api_tools_bp.route("/<int:tool_id>", methods=["DELETE"])
@jwt_required()
@admin_required
def delete_tool(tool_id):
    tool = Tool.query.get_or_404(tool_id)
    tool.is_active = False
    log_action(AuditAction.TOOL_DELETED, "tool", tool.id, tool.name,
               "Deleted via API", user=current_user)
    db.session.commit()
    return jsonify({"message": f"Tool '{tool.name}' removed"}), 200
