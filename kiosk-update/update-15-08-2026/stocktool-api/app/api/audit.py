from datetime import datetime
from flask import Blueprint, request, jsonify
from flask_jwt_extended import jwt_required
from app.extensions import db
from app.models.audit_log import AuditLog
from app.models.tool_history import ToolHistory, HistoryAction
from app.models.item import Item
from app.models.tool import Tool, ToolStatus
from app.models.project import Project
from app.models.user import User
from app.utils.decorators import admin_required

api_audit_bp = Blueprint("api_audit", __name__, url_prefix="/api")


def _paginate(query, page: int, per_page: int):
    result = db.paginate(query, page=page, per_page=per_page, error_out=False)
    return {
        # NOT "items" — that collides with dict.items() when Jinja does
        # attribute lookup on this dict in the admin frontend's templates.
        "results": [row.to_dict() for row in result.items],
        "page": result.page,
        "pages": result.pages,
        "total": result.total,
        "has_next": result.has_next,
        "has_prev": result.has_prev,
        "next_num": result.next_num,
        "prev_num": result.prev_num,
    }


@api_audit_bp.route("/audit-logs", methods=["GET"])
@jwt_required()
def list_audit_logs():
    """Filterable, paginated audit log — by user/item/tool/project/date/
    device/action. Open to any logged-in user (matches the original admin
    site's /logs page, which wasn't admin-only)."""
    query = AuditLog.query

    user_id = request.args.get("user_id", type=int)
    if user_id:
        query = query.filter_by(user_id=user_id)

    username = request.args.get("user", "").strip()
    if username:
        u = User.query.filter_by(username=username).first()
        query = query.filter_by(user_id=u.id if u else -1)

    entity_type = request.args.get("entity_type", "").strip()
    if entity_type:
        query = query.filter_by(entity_type=entity_type)

    entity_id = request.args.get("entity_id", type=int)
    if entity_id:
        query = query.filter_by(entity_id=entity_id)

    device = request.args.get("device", "").strip()
    if device:
        query = query.filter(AuditLog.device.ilike(f"%{device}%"))

    action = request.args.get("action", "").strip()
    if action:
        query = query.filter(AuditLog.action.ilike(f"%{action}%"))

    date_from = request.args.get("date_from", "").strip()
    if date_from:
        try:
            query = query.filter(AuditLog.created_at >= datetime.fromisoformat(date_from))
        except ValueError:
            pass

    date_to = request.args.get("date_to", "").strip()
    if date_to:
        try:
            query = query.filter(AuditLog.created_at <= datetime.fromisoformat(date_to))
        except ValueError:
            pass

    page = request.args.get("page", 1, type=int)
    per_page = min(request.args.get("per_page", 50, type=int), 200)
    query = query.order_by(AuditLog.created_at.desc())
    return jsonify(_paginate(query, page, per_page)), 200


@api_audit_bp.route("/tool-history", methods=["GET"])
@jwt_required()
def global_tool_history():
    """All tool history across every tool, paginated — powers the admin
    frontend's /logs/tool-history page."""
    page = request.args.get("page", 1, type=int)
    per_page = min(request.args.get("per_page", 50, type=int), 200)
    query = ToolHistory.query.order_by(ToolHistory.created_at.desc())
    return jsonify(_paginate(query, page, per_page)), 200


@api_audit_bp.route("/reports/summary", methods=["GET"])
@jwt_required()
def reports_summary():
    """Dashboard-style aggregate numbers, computed here so every client
    (admin frontend, anything else built later) sees identical figures."""
    total_items = Item.query.filter_by(is_active=True).count()
    low_stock = Item.query.filter(
        Item.is_active == True, Item.quantity <= Item.low_stock_threshold, Item.quantity > 0
    ).count()
    out_of_stock = Item.query.filter_by(is_active=True, quantity=0).count()

    total_tools = Tool.query.filter_by(is_active=True).count()
    tools_checked_out = Tool.query.filter_by(is_active=True, status=ToolStatus.CHECKED_OUT).count()
    tools_broken = Tool.query.filter(
        Tool.is_active == True, Tool.status.in_([ToolStatus.BROKEN, ToolStatus.UNDER_REPAIR])
    ).count()

    # KPI: tools checked out longer than Settings.max_checkout_hours.
    # Computed live (no stored "overdue" flag to drift out of date).
    checked_out_tools = Tool.query.filter_by(is_active=True, status=ToolStatus.CHECKED_OUT).all()
    overdue_tools = [t for t in checked_out_tools if t.is_overdue]

    total_projects = Project.query.filter_by(is_active=True).count()
    total_users = User.query.filter_by(is_active=True).count()

    recent_activity = AuditLog.query.order_by(AuditLog.created_at.desc()).limit(10).all()
    recent_checkouts = (
        ToolHistory.query.filter_by(action=HistoryAction.CHECKED_OUT)
        .order_by(ToolHistory.created_at.desc()).limit(10).all()
    )

    return jsonify({
        "items": {"total": total_items, "low_stock": low_stock, "out_of_stock": out_of_stock},
        "tools": {"total": total_tools, "checked_out": tools_checked_out,
                   "needs_attention": tools_broken, "overdue": len(overdue_tools)},
        "projects": {"total": total_projects},
        "users": {"active": total_users},
        "recent_activity": [l.to_dict() for l in recent_activity],
        "recent_checkouts": [h.to_dict() for h in recent_checkouts],
        "overdue_tools": [t.to_dict() for t in sorted(
            overdue_tools, key=lambda t: t.hours_checked_out, reverse=True
        )[:10]],
    }), 200
