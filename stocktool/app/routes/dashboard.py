from flask import Blueprint, render_template
from flask_login import login_required
from app.models.item import Item
from app.models.tool import Tool, ToolStatus
from app.models.tool_history import ToolHistory, HistoryAction
from app.models.audit_log import AuditLog

dashboard_bp = Blueprint("dashboard", __name__)


@dashboard_bp.route("/dashboard")
@login_required
def index():
    total_items = Item.query.filter_by(is_active=True).count()
    low_stock_items = Item.query.filter(
        Item.is_active == True,
        Item.quantity <= Item.low_stock_threshold
    ).count()
    out_of_stock = Item.query.filter_by(is_active=True, quantity=0).count()

    total_tools = Tool.query.filter_by(is_active=True).count()
    available_tools = Tool.query.filter_by(is_active=True, status=ToolStatus.AVAILABLE).count()
    checked_out_tools = Tool.query.filter_by(is_active=True, status=ToolStatus.CHECKED_OUT).count()
    broken_tools = Tool.query.filter(
        Tool.is_active == True,
        Tool.status.in_([ToolStatus.BROKEN, ToolStatus.UNDER_REPAIR])
    ).count()

    recent_checkouts = (
        ToolHistory.query
        .filter_by(action=HistoryAction.CHECKED_OUT)
        .order_by(ToolHistory.created_at.desc())
        .limit(5).all()
    )
    recent_logs = (
        AuditLog.query
        .order_by(AuditLog.created_at.desc())
        .limit(8).all()
    )
    low_stock_list = (
        Item.query
        .filter(Item.is_active == True, Item.quantity <= Item.low_stock_threshold)
        .order_by(Item.quantity.asc())
        .limit(5).all()
    )

    return render_template(
        "dashboard/index.html",
        total_items=total_items,
        low_stock_items=low_stock_items,
        out_of_stock=out_of_stock,
        total_tools=total_tools,
        available_tools=available_tools,
        checked_out_tools=checked_out_tools,
        broken_tools=broken_tools,
        recent_checkouts=recent_checkouts,
        recent_logs=recent_logs,
        low_stock_list=low_stock_list,
    )
