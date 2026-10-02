from datetime import datetime, timezone
from flask import Blueprint, render_template, redirect, url_for, flash, request
from flask_login import login_required, current_user
from app.extensions import db
from app.models.tool import Tool, ToolStatus
from app.models.tool_history import ToolHistory, HistoryAction
from app.models.audit_log import AuditAction
from app.utils.decorators import admin_required
from app.utils.audit import log_action
from app.utils.barcode_helper import generate_barcode

tools_bp = Blueprint("tools", __name__, url_prefix="/tools")


@tools_bp.route("/")
@login_required
def index():
    search = request.args.get("q", "").strip()
    status_filter = request.args.get("status", "").strip()
    category = request.args.get("category", "").strip()

    query = Tool.query.filter_by(is_active=True)
    if search:
        query = query.filter(
            Tool.name.ilike(f"%{search}%") |
            Tool.tool_number.ilike(f"%{search}%") |
            Tool.serial_number.ilike(f"%{search}%")
        )
    if status_filter:
        query = query.filter_by(status=status_filter)
    if category:
        query = query.filter_by(category=category)

    tools = query.order_by(Tool.name.asc()).all()
    categories = db.session.query(Tool.category).filter(
        Tool.is_active == True, Tool.category != None
    ).distinct().all()
    categories = [c[0] for c in categories]

    return render_template("tools/index.html", tools=tools, categories=categories,
                           search=search, status_filter=status_filter,
                           category=category, ToolStatus=ToolStatus)


@tools_bp.route("/add", methods=["GET", "POST"])
@login_required
@admin_required
def add():
    if request.method == "POST":
        name = request.form.get("name", "").strip()
        if not name:
            flash("Tool name is required.", "danger")
            return render_template("tools/form.html", tool=None, action="Add",
                                   ToolStatus=ToolStatus)

        purchase_date = None
        pd_str = request.form.get("purchase_date", "").strip()
        if pd_str:
            try:
                from datetime import date
                purchase_date = date.fromisoformat(pd_str)
            except ValueError:
                pass

        tool = Tool(
            name=name,
            tool_number=request.form.get("tool_number", "").strip() or None,
            brand=request.form.get("brand", "").strip() or None,
            model=request.form.get("model", "").strip() or None,
            serial_number=request.form.get("serial_number", "").strip() or None,
            description=request.form.get("description", "").strip() or None,
            category=request.form.get("category", "").strip() or None,
            location=request.form.get("location", "").strip() or None,
            status=ToolStatus.AVAILABLE,
            purchase_date=purchase_date,
            purchase_price=float(request.form.get("purchase_price", 0) or 0) or None,
        )
        db.session.add(tool)
        db.session.flush()

        generate_barcode("tool", tool.id)

        log_action(AuditAction.TOOL_CREATED, "tool", tool.id, tool.name,
                   f"Tool '{tool.name}' added to system")
        db.session.commit()
        flash(f"Tool '{tool.name}' added successfully.", "success")
        return redirect(url_for("tools.index"))

    return render_template("tools/form.html", tool=None, action="Add", ToolStatus=ToolStatus)


@tools_bp.route("/<int:tool_id>")
@login_required
def view(tool_id):
    tool = Tool.query.get_or_404(tool_id)
    history = tool.history.limit(20).all()
    return render_template("tools/view.html", tool=tool, history=history,
                           ToolStatus=ToolStatus)


@tools_bp.route("/<int:tool_id>/edit", methods=["GET", "POST"])
@login_required
@admin_required
def edit(tool_id):
    tool = Tool.query.get_or_404(tool_id)

    if request.method == "POST":
        name = request.form.get("name", "").strip()
        if not name:
            flash("Tool name is required.", "danger")
            return render_template("tools/form.html", tool=tool, action="Edit",
                                   ToolStatus=ToolStatus)

        tool.name = name
        tool.tool_number = request.form.get("tool_number", "").strip() or None
        tool.brand = request.form.get("brand", "").strip() or None
        tool.model = request.form.get("model", "").strip() or None
        tool.serial_number = request.form.get("serial_number", "").strip() or None
        tool.description = request.form.get("description", "").strip() or None
        tool.category = request.form.get("category", "").strip() or None
        tool.location = request.form.get("location", "").strip() or None
        tool.condition_notes = request.form.get("condition_notes", "").strip() or None

        pd_str = request.form.get("purchase_date", "").strip()
        if pd_str:
            try:
                from datetime import date
                tool.purchase_date = date.fromisoformat(pd_str)
            except ValueError:
                pass

        pp = request.form.get("purchase_price", "").strip()
        tool.purchase_price = float(pp) if pp else None

        log_action(AuditAction.TOOL_UPDATED, "tool", tool.id, tool.name,
                   f"Tool '{tool.name}' details updated")
        db.session.commit()
        flash(f"Tool '{tool.name}' updated.", "success")
        return redirect(url_for("tools.view", tool_id=tool.id))

    return render_template("tools/form.html", tool=tool, action="Edit", ToolStatus=ToolStatus)


@tools_bp.route("/<int:tool_id>/checkout", methods=["POST"])
@login_required
def checkout(tool_id):
    tool = Tool.query.get_or_404(tool_id)

    if not tool.is_available:
        flash(f"Tool is not available (current status: {tool.status_label}).", "danger")
        return redirect(url_for("tools.view", tool_id=tool.id))

    notes = request.form.get("notes", "").strip()
    now = datetime.now(timezone.utc)

    tool.status = ToolStatus.CHECKED_OUT
    tool.checked_out_by_id = current_user.id
    tool.checked_out_at = now

    history = ToolHistory(
        tool_id=tool.id,
        user_id=current_user.id,
        action=HistoryAction.CHECKED_OUT,
        from_status=ToolStatus.AVAILABLE,
        to_status=ToolStatus.CHECKED_OUT,
        notes=notes,
        checked_out_at=now,
    )
    db.session.add(history)

    log_action(AuditAction.TOOL_CHECKED_OUT, "tool", tool.id, tool.name,
               f"Checked out by {current_user.username}")
    db.session.commit()
    flash(f"'{tool.name}' checked out to you.", "success")
    return redirect(url_for("tools.view", tool_id=tool.id))


@tools_bp.route("/<int:tool_id>/checkin", methods=["POST"])
@login_required
def checkin(tool_id):
    tool = Tool.query.get_or_404(tool_id)

    if tool.status != ToolStatus.CHECKED_OUT:
        flash("Tool is not currently checked out.", "warning")
        return redirect(url_for("tools.view", tool_id=tool.id))

    notes = request.form.get("notes", "").strip()
    condition = request.form.get("condition", ToolStatus.AVAILABLE)
    if condition not in ToolStatus.ALL:
        condition = ToolStatus.AVAILABLE

    now = datetime.now(timezone.utc)

    # Find the open checkout history record for this tool
    open_record = (
        ToolHistory.query
        .filter_by(tool_id=tool.id, action=HistoryAction.CHECKED_OUT)
        .filter(ToolHistory.checked_in_at == None)
        .order_by(ToolHistory.created_at.desc())
        .first()
    )
    if open_record:
        open_record.checked_in_at = now
        open_record.notes = (open_record.notes or "") + (f" | Return: {notes}" if notes else "")

    checkin_record = ToolHistory(
        tool_id=tool.id,
        user_id=current_user.id,
        action=HistoryAction.CHECKED_IN,
        from_status=ToolStatus.CHECKED_OUT,
        to_status=condition,
        notes=notes,
        checked_in_at=now,
    )
    db.session.add(checkin_record)

    tool.status = condition
    tool.checked_out_by_id = None
    tool.checked_out_at = None

    log_action(AuditAction.TOOL_CHECKED_IN, "tool", tool.id, tool.name,
               f"Checked in by {current_user.username}. Condition: {condition}")
    db.session.commit()
    flash(f"'{tool.name}' checked back in. Status: {ToolStatus.LABELS[condition]}.", "success")
    return redirect(url_for("tools.view", tool_id=tool.id))


@tools_bp.route("/<int:tool_id>/status", methods=["POST"])
@login_required
@admin_required
def change_status(tool_id):
    tool = Tool.query.get_or_404(tool_id)
    new_status = request.form.get("status", "").strip()

    if new_status not in ToolStatus.ALL:
        flash("Invalid status.", "danger")
        return redirect(url_for("tools.view", tool_id=tool.id))

    old_status = tool.status
    notes = request.form.get("notes", "").strip()

    history = ToolHistory(
        tool_id=tool.id,
        user_id=current_user.id,
        action=HistoryAction.STATUS_CHANGED,
        from_status=old_status,
        to_status=new_status,
        notes=notes,
    )
    db.session.add(history)

    tool.status = new_status
    if new_status != ToolStatus.CHECKED_OUT:
        tool.checked_out_by_id = None
        tool.checked_out_at = None

    log_action(AuditAction.TOOL_STATUS_CHANGED, "tool", tool.id, tool.name,
               f"Status changed: {old_status} → {new_status}")
    db.session.commit()
    flash(f"Tool status updated to {ToolStatus.LABELS[new_status]}.", "success")
    return redirect(url_for("tools.view", tool_id=tool.id))


@tools_bp.route("/<int:tool_id>/delete", methods=["POST"])
@login_required
@admin_required
def delete(tool_id):
    tool = Tool.query.get_or_404(tool_id)
    tool.is_active = False
    log_action(AuditAction.TOOL_DELETED, "tool", tool.id, tool.name,
               f"Tool '{tool.name}' removed from system")
    db.session.commit()
    flash(f"Tool '{tool.name}' removed.", "info")
    return redirect(url_for("tools.index"))
