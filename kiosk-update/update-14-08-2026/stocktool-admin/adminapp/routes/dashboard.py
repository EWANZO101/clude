from flask import Blueprint, render_template, flash
from adminapp.utils.api_client import api_get, APIError
from adminapp.utils.decorators import login_required
from adminapp.utils.formatting import hydrate_list

dashboard_bp = Blueprint("dashboard", __name__)


@dashboard_bp.route("/dashboard")
@login_required
def index():
    try:
        summary = api_get("/api/reports/summary")
    except APIError as e:
        flash(f"Could not load dashboard: {e.message}", "danger")
        summary = {
            "items": {"total": 0, "low_stock": 0, "out_of_stock": 0},
            "tools": {"total": 0, "checked_out": 0, "needs_attention": 0},
            "projects": {"total": 0},
            "users": {"active": 0},
            "recent_activity": [],
            "recent_checkouts": [],
        }
    hydrate_list(summary.get("recent_activity"), ["created_at"])
    hydrate_list(summary.get("recent_checkouts"), ["created_at", "checked_out_at", "checked_in_at"])
    return render_template("dashboard/index.html", summary=summary)
