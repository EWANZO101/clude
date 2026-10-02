import csv
import io
from datetime import datetime, timezone
from flask import Blueprint, request, jsonify, Response
from app.models import db, Tool, ActivityEvent, ToolCheckoutEvent, ToolMaintenanceEvent
from app.auth import permission_required

tools_bp = Blueprint("tools", __name__, url_prefix="/api/tools")


def _now():
    return datetime.now(timezone.utc)


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
    if tool.status == Tool.STATUS_MAINTENANCE:
        return jsonify({"error": f"'{tool.name}' is under maintenance and can't be checked out."}), 409

    data = request.get_json(silent=True) or {}
    who = (data.get("checked_out_by_name") or "").strip()
    if not who:
        return jsonify({"error": "checked_out_by_name is required."}), 400
    project = (data.get("project") or "").strip() or None

    tool.status = Tool.STATUS_CHECKED_OUT
    tool.checked_out_by_name = who
    tool.current_project = project
    tool.dirty = True
    tool.updated_at = _now()
    db.session.add(ToolCheckoutEvent(
        tool_id=tool.id, checked_out_by_name=who, project=project, checked_out_at=_now(),
    ))
    ActivityEvent.log(ActivityEvent.TYPE_TOOL_CHECKOUT, tool.name, actor=who, project=project)
    db.session.commit()
    return jsonify(tool.to_dict()), 200


@tools_bp.route("/<int:tool_id>/checkin", methods=["POST"])
def checkin_tool(tool_id):
    tool = db.session.get(Tool, tool_id)
    if not tool:
        return jsonify({"error": "Tool not found."}), 404
    if tool.status != Tool.STATUS_CHECKED_OUT:
        return jsonify({"error": f"'{tool.name}' isn't checked out."}), 409

    returned_by = tool.checked_out_by_name
    returned_project = tool.current_project  # authoritative: what it was actually checked out for,
                                              # not whatever the checkin request happens to send
    tool.status = Tool.STATUS_AVAILABLE
    tool.checked_out_by_name = None
    tool.current_project = None
    tool.dirty = True
    tool.updated_at = _now()

    open_event = (ToolCheckoutEvent.query
                  .filter_by(tool_id=tool.id, checked_in_at=None)
                  .order_by(ToolCheckoutEvent.checked_out_at.desc())
                  .first())
    if open_event:
        now = _now()
        open_event.checked_in_at = now
        started = open_event.checked_out_at
        if started.tzinfo is None:
            started = started.replace(tzinfo=timezone.utc)
        open_event.duration_seconds = max(0.0, (now - started).total_seconds())

    ActivityEvent.log(ActivityEvent.TYPE_TOOL_CHECKIN, tool.name, actor=returned_by, project=returned_project)
    db.session.commit()
    return jsonify(tool.to_dict()), 200


@tools_bp.route("/<int:tool_id>/status", methods=["POST"])
@permission_required("admin", "supervisor")
def set_tool_status(tool_id):
    """Manually flip a tool between available and maintenance -- e.g.
    pulling something out of rotation for repair, or putting it back.
    Deliberately doesn't allow setting 'checked_out' directly here;
    that only happens through the actual checkout/checkin flow above,
    which needs a checked_out_by_name.

    Entering maintenance: body may include `level` (int, default 1) and
    `reason` -- opens a ToolMaintenanceEvent.
    Leaving maintenance: body may include `cost` -- closes the open
    ToolMaintenanceEvent (duration_seconds computed, cost recorded).
    """
    tool = db.session.get(Tool, tool_id)
    if not tool:
        return jsonify({"error": "Tool not found."}), 404
    if tool.status == Tool.STATUS_CHECKED_OUT:
        return jsonify({"error": f"'{tool.name}' is checked out -- check it in first."}), 409

    data = request.get_json(silent=True) or {}
    new_status = data.get("status")
    if new_status not in (Tool.STATUS_AVAILABLE, Tool.STATUS_MAINTENANCE):
        return jsonify({"error": "status must be 'available' or 'maintenance'."}), 400

    old_status = tool.status
    tool.status = new_status
    tool.dirty = True
    tool.updated_at = _now()

    if new_status == Tool.STATUS_MAINTENANCE and old_status != Tool.STATUS_MAINTENANCE:
        level = data.get("level", 1)
        try:
            level = int(level)
        except (TypeError, ValueError):
            level = 1
        reason = (data.get("reason") or "").strip() or None
        tool.maintenance_level = level
        db.session.add(ToolMaintenanceEvent(
            tool_id=tool.id, level=level, reason=reason, started_at=_now(),
        ))
        ActivityEvent.log("tool_status_change", tool.name, detail=f"{old_status} -> {new_status} (level {level})")

    elif old_status == Tool.STATUS_MAINTENANCE and new_status != Tool.STATUS_MAINTENANCE:
        cost = data.get("cost")
        try:
            cost = float(cost) if cost is not None else None
        except (TypeError, ValueError):
            cost = None
        open_event = (ToolMaintenanceEvent.query
                      .filter_by(tool_id=tool.id, ended_at=None)
                      .order_by(ToolMaintenanceEvent.started_at.desc())
                      .first())
        if open_event:
            now = _now()
            open_event.ended_at = now
            started = open_event.started_at
            if started.tzinfo is None:
                started = started.replace(tzinfo=timezone.utc)
            open_event.duration_seconds = max(0.0, (now - started).total_seconds())
            if cost is not None:
                open_event.cost = cost
        tool.maintenance_level = None
        ActivityEvent.log("tool_status_change", tool.name, detail=f"{old_status} -> {new_status}")

    else:
        if old_status != new_status:
            ActivityEvent.log("tool_status_change", tool.name, detail=f"{old_status} -> {new_status}")

    db.session.commit()
    return jsonify(tool.to_dict()), 200


@tools_bp.route("/<int:tool_id>/purchase-price", methods=["POST"])
@permission_required("admin", "supervisor")
def set_purchase_price(tool_id):
    tool = db.session.get(Tool, tool_id)
    if not tool:
        return jsonify({"error": "Tool not found."}), 404
    data = request.get_json(silent=True) or {}
    price = data.get("purchase_price")
    try:
        price = float(price)
    except (TypeError, ValueError):
        return jsonify({"error": "purchase_price must be a number."}), 400
    tool.purchase_price = price
    tool.dirty = True
    tool.updated_at = _now()
    db.session.commit()
    return jsonify(tool.to_dict()), 200


@tools_bp.route("/<int:tool_id>/maintenance/<int:event_id>", methods=["POST"])
@permission_required("admin", "supervisor")
def update_maintenance_event(tool_id, event_id):
    """Patch a maintenance event after the fact -- e.g. an invoice for
    the repair cost arrives later than the tool coming back into service."""
    event = db.session.get(ToolMaintenanceEvent, event_id)
    if not event or event.tool_id != tool_id:
        return jsonify({"error": "Maintenance event not found."}), 404
    data = request.get_json(silent=True) or {}
    if "cost" in data:
        try:
            event.cost = float(data["cost"]) if data["cost"] is not None else None
        except (TypeError, ValueError):
            return jsonify({"error": "cost must be a number."}), 400
    if "reason" in data:
        event.reason = (data.get("reason") or "").strip() or None
    db.session.commit()
    return jsonify(event.to_dict()), 200


@tools_bp.route("/<int:tool_id>/history", methods=["GET"])
def tool_history(tool_id):
    """Full economics history for one tool: checkout events, maintenance
    events, and the rollup summary (usage hours, maintenance cost,
    replacement-candidate flag) -- the basis for the printable/export
    view and for 'is this tool still worth keeping' decisions."""
    tool = db.session.get(Tool, tool_id)
    if not tool:
        return jsonify({"error": "Tool not found."}), 404

    checkouts = (ToolCheckoutEvent.query.filter_by(tool_id=tool.id)
                 .order_by(ToolCheckoutEvent.checked_out_at.desc()).all())
    maint = (ToolMaintenanceEvent.query.filter_by(tool_id=tool.id)
             .order_by(ToolMaintenanceEvent.started_at.desc()).all())

    return jsonify({
        "tool": tool.to_dict(),
        "summary": tool.usage_summary(),
        "checkout_events": [c.to_dict() for c in checkouts],
        "maintenance_events": [m.to_dict() for m in maint],
    }), 200


@tools_bp.route("/<int:tool_id>/history/export", methods=["GET"])
def tool_history_export(tool_id):
    """Printable/exportable CSV of a tool's full history: summary rows
    first, then every checkout event, then every maintenance event."""
    tool = db.session.get(Tool, tool_id)
    if not tool:
        return jsonify({"error": "Tool not found."}), 404

    summary = tool.usage_summary()
    checkouts = (ToolCheckoutEvent.query.filter_by(tool_id=tool.id)
                 .order_by(ToolCheckoutEvent.checked_out_at.asc()).all())
    maint = (ToolMaintenanceEvent.query.filter_by(tool_id=tool.id)
             .order_by(ToolMaintenanceEvent.started_at.asc()).all())

    buf = io.StringIO()
    w = csv.writer(buf)
    w.writerow(["Tool", tool.name])
    w.writerow(["Purchase Price", tool.purchase_price])
    w.writerow(["Total Checkout Count", summary["total_checkout_count"]])
    w.writerow(["Total Usage Hours", summary["total_usage_hours"]])
    w.writerow(["Maintenance Count", summary["maintenance_count"]])
    w.writerow(["Total Maintenance Hours", summary["total_maintenance_hours"]])
    w.writerow(["Total Maintenance Cost", summary["total_maintenance_cost"]])
    w.writerow(["Replacement Candidate", summary["is_replacement_candidate"]])
    for reason in summary["replacement_reasons"]:
        w.writerow(["Replacement Reason", reason])
    w.writerow([])

    w.writerow(["Checkout History"])
    w.writerow(["Checked Out By", "Project", "Checked Out At", "Checked In At", "Duration (hours)"])
    for c in checkouts:
        w.writerow([c.checked_out_by_name, c.project or "", c.checked_out_at, c.checked_in_at or "",
                    round(c.duration_seconds / 3600.0, 2) if c.duration_seconds is not None else ""])
    w.writerow([])

    w.writerow(["Maintenance History"])
    w.writerow(["Level", "Reason", "Started At", "Ended At", "Duration (hours)", "Cost"])
    for m in maint:
        w.writerow([m.level, m.reason or "", m.started_at, m.ended_at or "",
                    round(m.duration_seconds / 3600.0, 2) if m.duration_seconds is not None else "",
                    m.cost if m.cost is not None else ""])

    safe_name = "".join(c if c.isalnum() or c in "-_" else "_" for c in tool.name)
    return Response(
        buf.getvalue(),
        mimetype="text/csv",
        headers={"Content-Disposition": f'attachment; filename="tool_{safe_name}_history.csv"'},
    )


@tools_bp.route("/economics", methods=["GET"])
@permission_required("admin", "supervisor")
def tools_economics():
    """All tools' economics summaries in one call, sorted worst-first --
    the 'which tools should I consider replacing' view."""
    tools = Tool.query.order_by(Tool.name.asc()).all()
    rows = []
    for t in tools:
        summary = t.usage_summary()
        rows.append({"tool": t.to_dict(), "summary": summary})
    rows.sort(key=lambda r: (not r["summary"]["is_replacement_candidate"], -r["summary"]["total_maintenance_cost"]))
    return jsonify(rows), 200
