from flask import Blueprint, render_template, request, flash
from adminapp.utils.api_client import api_get, APIError
from adminapp.utils.decorators import login_required
from adminapp.utils.formatting import hydrate_list

logs_bp = Blueprint("logs", __name__, url_prefix="/logs")


@logs_bp.route("/")
@login_required
def index():
    page = request.args.get("page", 1, type=int)
    action_filter = request.args.get("action", "").strip()
    user_filter = request.args.get("user", "").strip()

    try:
        logs = api_get("/api/audit-logs", params={"page": page, "action": action_filter, "user": user_filter})
    except APIError as e:
        flash(e.message, "danger")
        logs = {"results": [], "page": 1, "pages": 0, "has_next": False, "has_prev": False}

    hydrate_list(logs.get("results"), ["created_at"])
    return render_template("logs/index.html", logs=logs,
                            action_filter=action_filter, user_filter=user_filter)


@logs_bp.route("/tool-history")
@login_required
def tool_history():
    page = request.args.get("page", 1, type=int)
    try:
        history = api_get("/api/tool-history", params={"page": page})
    except APIError as e:
        flash(e.message, "danger")
        history = {"results": [], "page": 1, "pages": 0, "has_next": False, "has_prev": False}

    hydrate_list(history.get("results"), ["created_at", "checked_out_at", "checked_in_at"])
    return render_template("logs/tool_history.html", history=history)
