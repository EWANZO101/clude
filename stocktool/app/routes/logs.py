from flask import Blueprint, render_template, request
from flask_login import login_required
from app.models.audit_log import AuditLog
from app.models.tool_history import ToolHistory

logs_bp = Blueprint("logs", __name__, url_prefix="/logs")


@logs_bp.route("/")
@login_required
def index():
    page = request.args.get("page", 1, type=int)
    action_filter = request.args.get("action", "").strip()
    user_filter = request.args.get("user", "").strip()

    query = AuditLog.query.order_by(AuditLog.created_at.desc())
    if action_filter:
        query = query.filter(AuditLog.action.ilike(f"%{action_filter}%"))
    if user_filter:
        from app.models.user import User
        user = User.query.filter_by(username=user_filter).first()
        if user:
            query = query.filter_by(user_id=user.id)

    logs = query.paginate(page=page, per_page=50, error_out=False)
    return render_template("logs/index.html", logs=logs,
                           action_filter=action_filter, user_filter=user_filter)


@logs_bp.route("/tool-history")
@login_required
def tool_history():
    page = request.args.get("page", 1, type=int)
    query = ToolHistory.query.order_by(ToolHistory.created_at.desc())
    history = query.paginate(page=page, per_page=50, error_out=False)
    return render_template("logs/tool_history.html", history=history)
