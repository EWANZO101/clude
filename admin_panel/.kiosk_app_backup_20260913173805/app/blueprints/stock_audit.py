from datetime import datetime

from flask import Blueprint, render_template, redirect, url_for, request, flash
from flask_login import login_required, current_user

from app.extensions import db
from app.models import StockAudit, StockAuditLine, Item, ActivityEvent
from app.permissions import require_sidebar_item, ADMIN_ROLES

bp = Blueprint("stock_audit", __name__, url_prefix="/stock-audit")
bp.before_request(require_sidebar_item("stock_audit"))


def get_open_audit():
    return StockAudit.query.filter_by(status="open").first()


def _next_target(audit_id):
    return url_for("scan.index") if request.form.get("next") == "scan" else url_for("stock_audit.detail", audit_id=audit_id)


@bp.route("/")
@login_required
def index():
    open_audit = get_open_audit()
    if open_audit is not None:
        return redirect(url_for("stock_audit.detail", audit_id=open_audit.id))
    past = StockAudit.query.filter_by(status="closed").order_by(StockAudit.closed_at.desc()).all()
    return render_template("stock_audit/index.html", past=past)


@bp.route("/start", methods=["POST"])
@login_required
def start():
    if get_open_audit() is not None:
        flash("An audit is already open.", "warning")
        return redirect(url_for("stock_audit.index"))

    audit = StockAudit(label=request.form.get("label", "").strip() or None, started_by=current_user.username)
    db.session.add(audit)
    db.session.flush()
    db.session.add(ActivityEvent(
        event_type="stock_audit_start", entity_name=audit.display_label(), actor=current_user.username,
        local_user_id=current_user.id,
        detail="Stock audit opened",
    ))
    db.session.commit()
    flash(f"'{audit.display_label()}' started. Stock movement is now frozen for non-admin roles.", "success")
    return redirect(url_for("stock_audit.detail", audit_id=audit.id))


@bp.route("/<int:audit_id>")
@login_required
def detail(audit_id):
    audit = StockAudit.query.get_or_404(audit_id)
    lines = audit.lines
    pending_count = sum(1 for l in lines if l.status == "pending" and l.discrepancy != 0)
    items = Item.query.filter_by(deleted_at=None).order_by(Item.name).all()
    counted_item_ids = {l.item_id for l in lines}
    return render_template(
        "stock_audit/detail.html", audit=audit, lines=lines, pending_count=pending_count,
        items=items, counted_item_ids=counted_item_ids,
    )


@bp.route("/<int:audit_id>/count", methods=["POST"])
@login_required
def record_count(audit_id):
    audit = StockAudit.query.get_or_404(audit_id)
    if audit.status != "open":
        flash("This audit is already closed.", "danger")
        return redirect(_next_target(audit_id))

    try:
        item_id = int(request.form.get("item_id"))
        counted_qty = int(request.form.get("counted_qty"))
    except (TypeError, ValueError):
        flash("Enter a valid item and count.", "danger")
        return redirect(_next_target(audit_id))
    if counted_qty < 0:
        flash("Counted quantity can't be negative.", "danger")
        return redirect(_next_target(audit_id))

    item = Item.query.get_or_404(item_id)
    line = StockAuditLine.query.filter_by(audit_id=audit.id, item_id=item.id).first()
    if line is None:
        line = StockAuditLine(
            audit_id=audit.id, item_id=item.id, expected_qty=item.quantity,
            counted_qty=counted_qty, counted_by=current_user.username,
        )
        db.session.add(line)
    else:
        # Recount: fix the entered number, keep the original expected_qty
        # snapshot and reset any prior resolution — a corrected count
        # needs a fresh decision, not to silently keep a stale one.
        line.counted_qty = counted_qty
        line.counted_by = current_user.username
        line.counted_at = datetime.utcnow()
        line.status = "pending"
        line.resolved_by = None
        line.resolved_at = None

    db.session.commit()
    if line.discrepancy == 0:
        flash(f"'{item.name}' counted — matches system quantity.", "success")
    else:
        flash(f"'{item.name}' counted — discrepancy of {line.discrepancy:+d} recorded.", "warning")
    return redirect(_next_target(audit_id))


@bp.route("/<int:audit_id>/lines/<int:line_id>/reconcile", methods=["POST"])
@login_required
def reconcile_line(audit_id, line_id):
    line = StockAuditLine.query.filter_by(id=line_id, audit_id=audit_id).first_or_404()
    if line.status != "pending":
        flash("That line was already resolved.", "warning")
        return redirect(url_for("stock_audit.detail", audit_id=audit_id))

    item = line.item
    old_qty = item.quantity
    item.quantity = line.counted_qty
    line.status = "reconciled"
    line.resolved_by = current_user.username
    line.resolved_at = datetime.utcnow()
    db.session.add(ActivityEvent(
        event_type="stock_audit_reconcile", entity_name=item.name, actor=current_user.username,
        local_user_id=current_user.id,
        detail=f"Audit correction applied: {old_qty} -> {line.counted_qty} ({line.discrepancy:+d})",
    ))
    db.session.commit()
    flash(f"'{item.name}' quantity corrected to {line.counted_qty}.", "success")
    return redirect(url_for("stock_audit.detail", audit_id=audit_id))


@bp.route("/<int:audit_id>/lines/<int:line_id>/dismiss", methods=["POST"])
@login_required
def dismiss_line(audit_id, line_id):
    line = StockAuditLine.query.filter_by(id=line_id, audit_id=audit_id).first_or_404()
    if line.status != "pending":
        flash("That line was already resolved.", "warning")
        return redirect(url_for("stock_audit.detail", audit_id=audit_id))

    line.status = "dismissed"
    line.resolved_by = current_user.username
    line.resolved_at = datetime.utcnow()
    db.session.add(ActivityEvent(
        event_type="stock_audit_dismiss", entity_name=line.item.name, actor=current_user.username,
        local_user_id=current_user.id,
        detail=f"Discrepancy dismissed, system quantity kept at {line.expected_qty} (counted {line.counted_qty})",
    ))
    db.session.commit()
    flash(f"Discrepancy for '{line.item.name}' dismissed — system quantity unchanged.", "info")
    return redirect(url_for("stock_audit.detail", audit_id=audit_id))


@bp.route("/<int:audit_id>/close", methods=["POST"])
@login_required
def close(audit_id):
    audit = StockAudit.query.get_or_404(audit_id)
    if audit.status != "open":
        flash("Already closed.", "warning")
        return redirect(url_for("stock_audit.detail", audit_id=audit_id))

    unresolved = [l for l in audit.lines if l.status == "pending" and l.discrepancy != 0]
    if unresolved:
        flash(f"{len(unresolved)} discrepanc{'y' if len(unresolved) == 1 else 'ies'} still need reconciling or dismissing before this audit can close.", "danger")
        return redirect(url_for("stock_audit.detail", audit_id=audit_id))

    audit.status = "closed"
    audit.closed_by = current_user.username
    audit.closed_at = datetime.utcnow()
    db.session.add(ActivityEvent(
        event_type="stock_audit_close", entity_name=audit.display_label(), actor=current_user.username,
        local_user_id=current_user.id,
        detail=f"Stock audit closed — {len(audit.lines)} item(s) counted",
    ))
    db.session.commit()
    flash(f"'{audit.display_label()}' closed.", "success")
    return redirect(url_for("stock_audit.index"))
