from flask import Blueprint, render_template, redirect, url_for, flash, request
from adminapp.utils.api_client import api_get, api_post, api_put, api_delete, APIError
from adminapp.utils.decorators import login_required, admin_required
from adminapp.utils.formatting import hydrate, hydrate_list

tools_bp = Blueprint("tools", __name__, url_prefix="/tools")

_DATE_FIELDS = ["created_at", "updated_at", "checked_out_at"]
_DATE_ONLY_FIELDS = ["purchase_date"]

# Mirrors app.models.tool.ToolStatus in stocktool-api — kept here only for
# template rendering (status dropdown labels/colours), never for validation;
# the API is what actually enforces valid values.
class ToolStatus:
    AVAILABLE = "available"
    CHECKED_OUT = "checked_out"
    BROKEN = "broken"
    UNDER_REPAIR = "under_repair"
    STOLEN = "stolen"
    LOST = "lost"
    ALL = [AVAILABLE, CHECKED_OUT, BROKEN, UNDER_REPAIR, STOLEN, LOST]
    LABELS = {
        AVAILABLE: "Available", CHECKED_OUT: "Checked Out", BROKEN: "Broken",
        UNDER_REPAIR: "Under Repair", STOLEN: "Stolen", LOST: "Lost",
    }


@tools_bp.route("/")
@login_required
def index():
    search = request.args.get("q", "").strip()
    status_filter = request.args.get("status", "").strip()
    category = request.args.get("category", "").strip()
    overdue_filter = request.args.get("overdue", "").strip()

    try:
        tools = api_get("/api/tools/", params={"q": search, "status": status_filter,
                                                 "category": category, "overdue": overdue_filter})
        categories = api_get("/api/tools/categories")
    except APIError as e:
        flash(e.message, "danger")
        tools, categories = [], []

    hydrate_list(tools, _DATE_FIELDS, _DATE_ONLY_FIELDS)

    from adminapp.utils.layout_surface import get_published_layout
    from adminapp.utils.layout_columns import COLUMN_META
    layout_components = get_published_layout("admin_tools")
    if layout_components:
        total = len(tools)
        checked_out = sum(1 for t in tools if t.get("checked_out_by"))
        overdue = sum(1 for t in tools if t.get("is_overdue"))
        stats = {
            "total": {"value": total, "label": "Total tools"},
            "checked_out": {"value": checked_out, "label": "Checked out"},
            "overdue": {"value": overdue, "label": "Overdue"},
        }
        return render_template(
            "tools/index_generic.html", tools=tools, categories=categories,
            search=search, status_filter=status_filter, category=category, overdue_filter=overdue_filter,
            ToolStatus=ToolStatus, layout_components=layout_components,
            column_meta=COLUMN_META["tools"], stats=stats,
        )

    return render_template("tools/index.html", tools=tools, categories=categories,
                            search=search, status_filter=status_filter, category=category,
                            overdue_filter=overdue_filter, ToolStatus=ToolStatus)


def _all_categories():
    try:
        return api_get("/api/categories/")
    except APIError:
        return []


@tools_bp.route("/add", methods=["GET", "POST"])
@login_required
@admin_required
def add():
    all_categories = _all_categories()
    if request.method == "POST":
        name = request.form.get("name", "").strip()
        if not name:
            flash("Tool name is required.", "danger")
            return render_template("tools/form.html", tool=None, action="Add", ToolStatus=ToolStatus,
                                    all_categories=all_categories)

        try:
            tool = api_post("/api/tools/", {
                "name": name,
                "tool_number": request.form.get("tool_number", "").strip() or None,
                "brand": request.form.get("brand", "").strip() or None,
                "model": request.form.get("model", "").strip() or None,
                "serial_number": request.form.get("serial_number", "").strip() or None,
                "description": request.form.get("description", "").strip() or None,
                "category": request.form.get("category", "").strip() or None,
                "location": request.form.get("location", "").strip() or None,
                "purchase_date": request.form.get("purchase_date", "").strip() or None,
                "purchase_price": request.form.get("purchase_price", "").strip() or None,
                "category_ids": [int(x) for x in request.form.getlist("category_ids")],
            })
        except APIError as e:
            flash(e.message, "danger")
            return render_template("tools/form.html", tool=None, action="Add", ToolStatus=ToolStatus,
                                    all_categories=all_categories)

        flash(f"Tool '{tool['name']}' added successfully.", "success")
        return redirect(url_for("tools.index"))

    return render_template("tools/form.html", tool=None, action="Add", ToolStatus=ToolStatus,
                            all_categories=all_categories)


@tools_bp.route("/<int:tool_id>")
@login_required
def view(tool_id):
    try:
        tool = api_get(f"/api/tools/{tool_id}")
        history = api_get(f"/api/tools/{tool_id}/history", params={"limit": 20})
    except APIError as e:
        flash(e.message, "danger")
        return redirect(url_for("tools.index"))
    hydrate(tool, _DATE_FIELDS, _DATE_ONLY_FIELDS)
    hydrate_list(history, ["created_at", "checked_out_at", "checked_in_at"])
    return render_template("tools/view.html", tool=tool, history=history, ToolStatus=ToolStatus)


@tools_bp.route("/<int:tool_id>/edit", methods=["GET", "POST"])
@login_required
@admin_required
def edit(tool_id):
    all_categories = _all_categories()
    try:
        tool = api_get(f"/api/tools/{tool_id}")
    except APIError as e:
        flash(e.message, "danger")
        return redirect(url_for("tools.index"))

    if request.method == "POST":
        name = request.form.get("name", "").strip()
        if not name:
            flash("Tool name is required.", "danger")
            return render_template("tools/form.html", tool=tool, action="Edit", ToolStatus=ToolStatus,
                                    all_categories=all_categories)

        try:
            tool = api_put(f"/api/tools/{tool_id}", {
                "name": name,
                "tool_number": request.form.get("tool_number", "").strip() or None,
                "brand": request.form.get("brand", "").strip() or None,
                "model": request.form.get("model", "").strip() or None,
                "serial_number": request.form.get("serial_number", "").strip() or None,
                "description": request.form.get("description", "").strip() or None,
                "category": request.form.get("category", "").strip() or None,
                "location": request.form.get("location", "").strip() or None,
                "condition_notes": request.form.get("condition_notes", "").strip() or None,
                "purchase_date": request.form.get("purchase_date", "").strip() or None,
                "purchase_price": request.form.get("purchase_price", "").strip() or None,
                "category_ids": [int(x) for x in request.form.getlist("category_ids")],
            })
        except APIError as e:
            flash(e.message, "danger")
            return render_template("tools/form.html", tool=tool, action="Edit", ToolStatus=ToolStatus,
                                    all_categories=all_categories)

        flash(f"Tool '{tool['name']}' updated.", "success")
        return redirect(url_for("tools.view", tool_id=tool["id"]))

    return render_template("tools/form.html", tool=tool, action="Edit", ToolStatus=ToolStatus,
                            all_categories=all_categories)


@tools_bp.route("/<int:tool_id>/checkout", methods=["POST"])
@login_required
def checkout(tool_id):
    notes = request.form.get("notes", "").strip()
    try:
        tool = api_post(f"/api/tools/{tool_id}/checkout", {"notes": notes})
    except APIError as e:
        flash(e.message, "danger")
        return redirect(url_for("tools.view", tool_id=tool_id))
    flash(f"'{tool['name']}' checked out to you.", "success")
    return redirect(url_for("tools.view", tool_id=tool_id))


@tools_bp.route("/<int:tool_id>/checkin", methods=["POST"])
@login_required
def checkin(tool_id):
    notes = request.form.get("notes", "").strip()
    condition = request.form.get("condition", ToolStatus.AVAILABLE)
    try:
        tool = api_post(f"/api/tools/{tool_id}/checkin", {"notes": notes, "condition": condition})
    except APIError as e:
        flash(e.message, "danger")
        return redirect(url_for("tools.view", tool_id=tool_id))
    flash(f"'{tool['name']}' checked back in. Status: {ToolStatus.LABELS.get(tool['status'], tool['status'])}.", "success")
    return redirect(url_for("tools.view", tool_id=tool_id))


@tools_bp.route("/<int:tool_id>/status", methods=["POST"])
@login_required
@admin_required
def change_status(tool_id):
    new_status = request.form.get("status", "").strip()
    notes = request.form.get("notes", "").strip()
    try:
        tool = api_post(f"/api/tools/{tool_id}/status", {"status": new_status, "notes": notes})
    except APIError as e:
        flash(e.message, "danger")
        return redirect(url_for("tools.view", tool_id=tool_id))
    flash(f"Tool status updated to {ToolStatus.LABELS.get(tool['status'], tool['status'])}.", "success")
    return redirect(url_for("tools.view", tool_id=tool_id))


@tools_bp.route("/<int:tool_id>/delete", methods=["POST"])
@login_required
@admin_required
def delete(tool_id):
    try:
        result = api_delete(f"/api/tools/{tool_id}")
    except APIError as e:
        flash(e.message, "danger")
        return redirect(url_for("tools.index"))
    flash(result.get("message", "Tool removed."), "info")
    return redirect(url_for("tools.index"))
