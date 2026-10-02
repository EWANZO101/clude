from datetime import datetime

from flask import Blueprint, render_template, redirect, url_for, request, flash, abort
from flask_login import login_required, current_user

from app.extensions import db
from app.models import (
    Tool, Barcode, ToolCheckoutEvent, ToolMaintenanceEvent, MaintenanceAlertThreshold,
    ActivityEvent, gen_tool_barcode,
)
from app.permissions import require_sidebar_item, ADMIN_ROLES
from app.barcode_render import code128_data_uri, qr_data_uri
from app.categorization import guess_category

bp = Blueprint("tools", __name__, url_prefix="/tools")
bp.before_request(require_sidebar_item("tools"))


def _register_barcode(code: str, entity_type: str, entity_id: int):
    db.session.add(Barcode(code=code, entity_type=entity_type, entity_id=entity_id))


def _category_suggestions():
    return sorted({c for (c,) in db.session.query(Tool.category).filter(Tool.category.isnot(None)).distinct()})


@bp.route("/")
@login_required
def list_tools():
    tools = Tool.query.filter_by(deleted_at=None).order_by(Tool.name).all()
    groups = {}
    for t in tools:
        label = (t.category or "").strip() or "Uncategorized"
        groups.setdefault(label, []).append(t)
    tools_by_category = sorted(groups.items(), key=lambda kv: (kv[0] == "Uncategorized", kv[0].lower()))
    uncategorized_count = len(groups.get("Uncategorized", []))
    return render_template(
        "tools/list.html", tools=tools, tools_by_category=tools_by_category,
        category_suggestions=_category_suggestions(), uncategorized_count=uncategorized_count,
    )


@bp.route("/auto-categorize", methods=["POST"])
@login_required
def auto_categorize():
    """Best-effort bulk categorization for tools with no category set —
    see items.py's identical auto_categorize for the full rationale."""
    if current_user.role not in ADMIN_ROLES:
        abort(403)

    uncategorized = Tool.query.filter(Tool.deleted_at.is_(None), Tool.category.is_(None)).all()
    categorized_count = 0
    for tool in uncategorized:
        guess = guess_category(tool.name)
        if guess:
            tool.category = guess
            categorized_count += 1

    if categorized_count:
        db.session.add(ActivityEvent(
            event_type="tools_auto_categorized", entity_name=f"{categorized_count} tool(s)",
            actor=current_user.username, local_user_id=current_user.id,
            detail=f"Auto-categorized {categorized_count} of {len(uncategorized)} previously uncategorized tools",
        ))
        db.session.commit()
        left = len(uncategorized) - categorized_count
        msg = f"Categorized {categorized_count} tool(s)."
        if left:
            msg += f" {left} left uncategorized — no keyword match found for those names."
        flash(msg, "success")
    else:
        flash("No matches found — nothing was categorized.", "info")

    return redirect(url_for("tools.list_tools"))


@bp.route("/add", methods=["GET", "POST"])
@login_required
def add_tool():
    if request.method == "POST":
        name = request.form.get("name", "").strip()
        if not name:
            flash("Name is required.", "danger")
            return render_template("tools/add.html", category_suggestions=_category_suggestions())

        barcode_code = request.form.get("barcode_code", "").strip() or gen_tool_barcode()
        if Barcode.query.get(barcode_code) is not None:
            flash(f"Barcode '{barcode_code}' is already in use.", "danger")
            return render_template("tools/add.html", category_suggestions=_category_suggestions())

        tool = Tool(
            name=name,
            description=request.form.get("description", "").strip() or None,
            barcode_code=barcode_code,
            category=request.form.get("category", "").strip() or None,
            purchase_price=float(request.form.get("purchase_price")) if request.form.get("purchase_price") else None,
        )
        db.session.add(tool)
        db.session.flush()
        _register_barcode(barcode_code, "tool", tool.id)
        db.session.commit()

        flash(f"Tool '{tool.name}' added.", "success")
        return redirect(url_for("tools.list_tools"))

    return render_template("tools/add.html", category_suggestions=_category_suggestions())


@bp.route("/<int:tool_id>/edit", methods=["GET", "POST"])
@login_required
def edit_tool(tool_id):
    tool = Tool.query.get_or_404(tool_id)
    if request.method == "POST":
        tool.name = request.form.get("name", tool.name or "").strip() or tool.name
        tool.description = request.form.get("description", tool.description or "").strip() or None
        tool.category = request.form.get("category", "").strip() or None
        price = request.form.get("purchase_price", "")
        tool.purchase_price = float(price) if price else tool.purchase_price
        db.session.commit()
        flash("Tool updated.", "success")
        return redirect(url_for("tools.list_tools"))
    return render_template("tools/edit.html", tool=tool, category_suggestions=_category_suggestions())


@bp.route("/<int:tool_id>/delete", methods=["POST"])
@login_required
def delete_tool(tool_id):
    tool = Tool.query.get_or_404(tool_id)
    if tool.status != "available":
        flash("Only an available tool can be deleted — check it in or close maintenance first.", "danger")
        return redirect(url_for("tools.list_tools"))
    if tool.checkout_events or tool.maintenance_events:
        # Fixed in Part 8: deleting a tool used to cascade-delete its own
        # checkout/maintenance history along with it, silently pulling
        # real usage data out of Tool Economics — the same bug class
        # found and fixed for Wire spools in Part 5. A tool that's ever
        # been used keeps its history now; only a never-used tool
        # (added by mistake, wrong barcode, etc.) can be deleted outright.
        flash("This tool has usage history, so deleting it would corrupt Tool Economics — it can't be removed.", "danger")
        return redirect(url_for("tools.list_tools"))
    from datetime import datetime
    Barcode.query.filter_by(code=tool.barcode_code).delete()
    # Soft-delete (tombstone), not db.session.delete — see Tool.deleted_at:
    # a hard delete here would never reach the Admin Panel's own mirror of
    # this tool (see app/blueprints/sync_api.py / the Instance Agent's
    # inventory sync), which would just re-create it right back on its
    # next sync pass.
    tool.deleted_at = datetime.utcnow()
    db.session.commit()
    flash("Tool deleted.", "info")
    return redirect(url_for("tools.list_tools"))


@bp.route("/<int:tool_id>/checkout", methods=["POST"])
@login_required
def checkout_tool(tool_id):
    tool = Tool.query.get_or_404(tool_id)
    if tool.status != "available":
        flash(f"'{tool.name}' is not available (status: {tool.status}).", "danger")
        return redirect(url_for("tools.list_tools"))

    project = request.form.get("project", "").strip() or None
    checked_out_by = current_user.username

    event = ToolCheckoutEvent(tool_id=tool.id, checked_out_by_name=checked_out_by, project=project)
    db.session.add(event)

    tool.status = "checked_out"
    tool.checked_out_by_name = checked_out_by
    tool.current_project = project

    db.session.add(ActivityEvent(
        event_type="tool_checkout", entity_name=tool.name, actor=checked_out_by,
        local_user_id=current_user.id,
        project=project, detail=f"Checked out — for {project or 'no project specified'}",
    ))
    db.session.commit()
    flash(f"'{tool.name}' checked out.", "success")
    if request.form.get("next") == "scan":
        return redirect(url_for("scan.index"))
    return redirect(url_for("tools.list_tools"))


@bp.route("/<int:tool_id>/checkin", methods=["POST"])
@login_required
def checkin_tool(tool_id):
    tool = Tool.query.get_or_404(tool_id)
    if tool.status != "checked_out":
        flash(f"'{tool.name}' is not currently checked out.", "danger")
        return redirect(url_for("tools.list_tools"))

    event = ToolCheckoutEvent.query.filter_by(tool_id=tool.id, checked_in_at=None).order_by(
        ToolCheckoutEvent.checked_out_at.desc()
    ).first()
    now = datetime.utcnow()
    if event is not None:
        event.checked_in_at = now
        event.duration_seconds = (now - event.checked_out_at).total_seconds()

    checked_out_by = tool.checked_out_by_name
    tool.status = "available"
    tool.checked_out_by_name = None
    tool.current_project = None

    db.session.add(ActivityEvent(
        event_type="tool_checkin", entity_name=tool.name, actor=current_user.username,
        local_user_id=current_user.id,
        detail=f"Checked in (was out to {checked_out_by})" if checked_out_by else "Checked in",
    ))
    db.session.commit()
    flash(f"'{tool.name}' checked in.", "success")
    if request.form.get("next") == "scan":
        return redirect(url_for("scan.index"))
    return redirect(url_for("tools.list_tools"))


@bp.route("/<int:tool_id>/maintenance/start", methods=["POST"])
@login_required
def start_maintenance(tool_id):
    tool = Tool.query.get_or_404(tool_id)
    if tool.status == "checked_out":
        flash(f"'{tool.name}' is checked out — check it in before sending it to maintenance.", "danger")
        return redirect(url_for("tools.list_tools"))

    try:
        level = int(request.form.get("level", "1"))
    except ValueError:
        level = 1
    reason = request.form.get("reason", "").strip() or None

    tool.status = "maintenance"
    tool.maintenance_level = level
    db.session.add(ToolMaintenanceEvent(tool_id=tool.id, level=level, reason=reason))
    db.session.commit()
    flash(f"'{tool.name}' marked as in maintenance (level {level}).", "warning")
    return redirect(url_for("tools.list_tools"))


@bp.route("/<int:tool_id>/maintenance/<int:event_id>/close", methods=["POST"])
@login_required
def close_maintenance(tool_id, event_id):
    tool = Tool.query.get_or_404(tool_id)
    event = ToolMaintenanceEvent.query.filter_by(id=event_id, tool_id=tool.id).first_or_404()
    if event.ended_at is not None:
        flash("That maintenance event is already closed.", "warning")
        return redirect(url_for("tools.list_tools"))

    now = datetime.utcnow()
    event.ended_at = now
    event.duration_seconds = (now - event.started_at).total_seconds()
    cost = request.form.get("cost", "")
    event.cost = float(cost) if cost else None

    tool.status = "available"
    tool.maintenance_level = None
    db.session.commit()
    flash(f"Maintenance closed for '{tool.name}'.", "success")
    return redirect(url_for("tools.list_tools"))


@bp.route("/<int:tool_id>/barcode")
@login_required
def view_barcode(tool_id):
    tool = Tool.query.get_or_404(tool_id)
    return render_template(
        "tools/barcode.html", tool=tool,
        barcode_image=code128_data_uri(tool.barcode_code),
        qr_image=qr_data_uri(tool.barcode_code),
    )


@bp.route("/economics")
@login_required
def economics():
    tools = Tool.query.filter_by(deleted_at=None).order_by(Tool.name).all()
    rows = [(t, t.usage_summary()) for t in tools]
    replacement_candidates = [(t, s) for t, s in rows if s["replacement_candidate"]]
    return render_template("tools/economics.html", rows=rows, replacement_candidates=replacement_candidates)


@bp.route("/alerts")
@login_required
def alerts():
    now = datetime.utcnow()
    overdue = []
    open_events = ToolMaintenanceEvent.query.filter_by(ended_at=None).all()
    for event in open_events:
        threshold = MaintenanceAlertThreshold.get_or_default(event.level)
        hours_in_maintenance = (now - event.started_at).total_seconds() / 3600
        if hours_in_maintenance > threshold:
            overdue.append((event, hours_in_maintenance, threshold))
    return render_template("tools/alerts.html", overdue=overdue)
