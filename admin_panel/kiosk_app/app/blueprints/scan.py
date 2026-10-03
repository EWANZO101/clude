from flask import Blueprint, render_template, redirect, url_for, request, flash, session
from flask_login import login_required, current_user

from app.extensions import db
from app.models import Barcode, Item, Tool, Project, WireSpool, StockAudit, ActivityEvent
from app.permissions import require_sidebar_item

bp = Blueprint("scan", __name__, url_prefix="/scan")
bp.before_request(require_sidebar_item("scan"))

# Design note (technical doc Section 4.1 names "project" and "wire" as
# barcode entity_types alongside item/tool but the excerpt available here
# doesn't spell out a scan-driven workflow beyond that shared lookup
# table). This implements the shop-floor pattern the schema points at: a
# hardware scanner emits a code + Enter with no other input available, so
# scanning a Project barcode sets it as the kiosk's "active project" for
# the current login session, and scanning an Item, Tool, or wire spool
# afterward offers a one-tap action (issue / check out / check in /
# empty / return) with that project pre-filled — rather than silently
# auto-issuing stock on a bare scan, which would make a mis-scan
# destructive with no confirmation step.


def get_active_project():
    """Returns the session's active Project, clearing stale session state
    if it was deleted or closed out from under it."""
    project_id = session.get("active_project_id")
    if project_id is None:
        return None
    project = Project.query.get(project_id)
    if project is None or project.status != "active":
        session.pop("active_project_id", None)
        session.pop("active_project_name", None)
        return None
    return project


def _lookup_barcode(raw_code: str):
    code = (raw_code or "").strip()
    if not code:
        return None
    return Barcode.query.get(code) or Barcode.query.get(code.upper())


def _item_result(item):
    status_label, status_color = ("OUT OF STOCK", "red") if item.quantity <= 0 else (
        ("LOW STOCK", "orange") if item.quantity < 5 else ("IN STOCK", "green")
    )
    rows = [("SKU", item.sku or "—"), ("Barcode", item.barcode_code), ("Category", item.category_display())]
    if item.supplier:
        rows.append(("Supplier", item.supplier))
    rows.append(("Location", item.location or "not set"))
    return {
        "kind": "item", "item": item, "name": item.name,
        "status_label": status_label, "status_color": status_color,
        "rows": rows, "stock_value": item.quantity, "stock_unit": item.unit or "",
    }


def _tool_result(tool):
    if tool.status == "available":
        status_label, status_color = "AVAILABLE", "green"
    elif tool.status == "checked_out":
        status_label, status_color = "CHECKED OUT", "orange"
    else:
        status_label, status_color = "IN MAINTENANCE", "red"
    rows = [("Barcode", tool.barcode_code), ("Category", tool.category or "—")]
    if tool.status == "checked_out":
        rows.append(("Checked out to", tool.checked_out_by_name or "—"))
        if tool.current_project:
            rows.append(("Project", tool.current_project))
    if tool.status == "maintenance":
        rows.append(("Maintenance level", tool.maintenance_level))
    return {
        "kind": "tool", "tool": tool, "name": tool.name,
        "status_label": status_label, "status_color": status_color, "rows": rows,
    }


def _wire_result(spool):
    if spool.status == "in_stock":
        status_label, status_color = "IN STOCK", "green"
    elif spool.status == "issued":
        status_label, status_color = "ISSUED", "orange"
    elif spool.status == "empty":
        status_label, status_color = "EMPTY", "muted"
    else:
        status_label, status_color = "SCRAPPED", "red"
    rows = [("Barcode", spool.barcode_code)]
    if spool.diameter:
        rows.append(("Diameter", spool.diameter))
    if spool.status == "issued":
        rows.append(("Issued to", spool.issued_to or "—"))
        if spool.current_project:
            rows.append(("Project", spool.current_project))
    if spool.status == "scrapped" and spool.scrap_reason:
        rows.append(("Scrap reason", spool.scrap_reason))
    result = {
        "kind": "wire", "spool": spool, "name": spool.wire_label(),
        "status_label": status_label, "status_color": status_color, "rows": rows,
    }
    if spool.current_weight_lbs is not None:
        result["stock_value"] = spool.current_weight_lbs
        result["stock_unit"] = "lbs"
    return result


@bp.route("/")
@login_required
def index():
    return render_template("scan/index.html", active_project=get_active_project(), result=None)


@bp.route("/", methods=["POST"])
@login_required
def submit():
    raw_code = request.form.get("code", "").strip()
    barcode = _lookup_barcode(raw_code)
    if barcode is None:
        return render_template(
            "scan/index.html", active_project=get_active_project(),
            result={"kind": "not_found", "code": raw_code},
        )

    if barcode.entity_type == "project":
        project = Project.query.get(barcode.entity_id)
        if project is None:
            flash("That project no longer exists.", "danger")
            return redirect(url_for("scan.index"))
        if project.status != "active":
            flash(f"'{project.name}' is closed — reopen it before scanning it as active.", "danger")
            return redirect(url_for("scan.index"))
        session["active_project_id"] = project.id
        session["active_project_name"] = project.name
        db.session.add(ActivityEvent(
            event_type="project_activate", entity_name=project.name, actor=current_user.username,
            local_user_id=current_user.id,
            detail="Set as active project via scan",
        ))
        db.session.commit()
        flash(f"Active project set to '{project.name}'.", "success")
        return redirect(url_for("scan.index"))

    if barcode.entity_type == "item":
        item = Item.query.get(barcode.entity_id)
        if item is None or item.deleted_at is not None:
            flash("That item no longer exists.", "danger")
            return redirect(url_for("scan.index"))
        open_audit = StockAudit.query.filter_by(status="open").first()
        if open_audit is not None:
            # An open audit takes over item scans entirely — counting is
            # the point of scanning during an audit, and adjust_item is
            # frozen for non-admin roles anyway (Part 7), so routing to
            # the normal issue screen here would just dead-end into that
            # freeze instead of doing what the person actually came to do.
            existing = next((l for l in open_audit.lines if l.item_id == item.id), None)
            return render_template(
                "scan/audit_count_result.html", item=item, audit=open_audit, existing_line=existing,
            )
        return render_template("scan/index.html", active_project=get_active_project(), result=_item_result(item))

    if barcode.entity_type == "tool":
        tool = Tool.query.get(barcode.entity_id)
        if tool is None or tool.deleted_at is not None:
            flash("That tool no longer exists.", "danger")
            return redirect(url_for("scan.index"))
        return render_template("scan/index.html", active_project=get_active_project(), result=_tool_result(tool))

    if barcode.entity_type == "wire":
        spool = WireSpool.query.get(barcode.entity_id)
        if spool is None:
            flash("That wire spool no longer exists.", "danger")
            return redirect(url_for("scan.index"))
        return render_template("scan/index.html", active_project=get_active_project(), result=_wire_result(spool))

    flash(f"Unrecognized barcode type '{barcode.entity_type}'.", "danger")
    return redirect(url_for("scan.index"))


@bp.route("/clear-project", methods=["POST"])
@login_required
def clear_project():
    session.pop("active_project_id", None)
    session.pop("active_project_name", None)
    flash("Active project cleared.", "info")
    return redirect(url_for("scan.index"))
