from datetime import datetime, timezone
from flask import Blueprint, request, jsonify
from app.models import db, Tool

tools_bp = Blueprint("tools", __name__, url_prefix="/api/tools")


@tools_bp.route("", methods=["GET"])
def list_tools():
    status = request.args.get("status")
    query = Tool.query
    if status:
        query = query.filter_by(status=status)
    tools = query.order_by(Tool.name.asc()).all()
    return jsonify([t.to_dict() for t in tools]), 200


@tools_bp.route("/<int:tool_id>", methods=["GET"])
def get_tool(tool_id):
    tool = db.session.get(Tool, tool_id)
    if not tool:
        return jsonify({"error": "Tool not found."}), 404
    return jsonify(tool.to_dict()), 200


@tools_bp.route("/<int:tool_id>/checkout", methods=["POST"])
def checkout_tool(tool_id):
    tool = db.session.get(Tool, tool_id)
    if not tool:
        return jsonify({"error": "Tool not found."}), 404
    if tool.status == Tool.STATUS_CHECKED_OUT:
        return jsonify({"error": f"'{tool.name}' is already checked out."}), 409

    data = request.get_json(silent=True) or {}
    who = (data.get("checked_out_by_name") or "").strip()
    if not who:
        return jsonify({"error": "checked_out_by_name is required."}), 400

    tool.status = Tool.STATUS_CHECKED_OUT
    tool.checked_out_by_name = who
    tool.dirty = True
    tool.updated_at = datetime.now(timezone.utc)
    db.session.commit()
    return jsonify(tool.to_dict()), 200


@tools_bp.route("/<int:tool_id>/checkin", methods=["POST"])
def checkin_tool(tool_id):
    tool = db.session.get(Tool, tool_id)
    if not tool:
        return jsonify({"error": "Tool not found."}), 404
    if tool.status != Tool.STATUS_CHECKED_OUT:
        return jsonify({"error": f"'{tool.name}' isn't checked out."}), 409

    tool.status = Tool.STATUS_AVAILABLE
    tool.checked_out_by_name = None
    tool.dirty = True
    tool.updated_at = datetime.now(timezone.utc)
    db.session.commit()
    return jsonify(tool.to_dict()), 200
