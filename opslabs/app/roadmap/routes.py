"""
Public roadmap.

Public (no auth):
  GET  /roadmap                       kanban-style board of visible items

Admin (staff+):
  GET  /admin/roadmap                 manage board (incl. hidden items)
  GET  /admin/roadmap/new             new-item form
  POST /admin/roadmap/new             create
  GET  /admin/roadmap/<id>/edit       edit-item form
  POST /admin/roadmap/<id>/edit       update
  POST /admin/roadmap/<id>/status     quick status change (dropdown on the board)
  POST /admin/roadmap/<id>/visibility toggle public visibility
  POST /admin/roadmap/<id>/move       nudge up/down within its column
  POST /admin/roadmap/<id>/delete     remove
"""
from datetime import datetime

from flask import render_template, request, redirect, url_for, flash
from flask_login import current_user

from . import roadmap_bp
from .. import db
from ..models_business import RoadmapItem, AuditLog, ROADMAP_STATUS_META, ROADMAP_STATUS_ORDER
from ..rbac import require_role, STAFF, require_admin_page


def _grouped(items):
    """Bucket a list of RoadmapItem into an ordered dict keyed by status."""
    buckets = {s: [] for s in ROADMAP_STATUS_ORDER}
    for it in items:
        buckets.setdefault(it.status, []).append(it)
    return buckets


def _parse_date(raw):
    raw = (raw or "").strip()
    if not raw:
        return None
    try:
        return datetime.strptime(raw, "%Y-%m-%d").date()
    except ValueError:
        return None


# ════════════════════════════════════════════════ PUBLIC ═══════════════════
@roadmap_bp.route("/roadmap")
def index():
    items = (RoadmapItem.query.filter_by(is_visible=True)
             .order_by(RoadmapItem.position.asc(), RoadmapItem.created_at.asc()).all())
    return render_template(
        "roadmap/index.html",
        columns=_grouped(items),
        status_meta=ROADMAP_STATUS_META,
        status_order=ROADMAP_STATUS_ORDER,
        total=len(items),
    )


# ════════════════════════════════════════════════ ADMIN ════════════════════
@roadmap_bp.route("/admin/roadmap")
@require_admin_page("roadmap")
def admin_list():
    items = (RoadmapItem.query
             .order_by(RoadmapItem.position.asc(), RoadmapItem.created_at.asc()).all())
    return render_template(
        "admin/roadmap/list.html",
        columns=_grouped(items),
        status_meta=ROADMAP_STATUS_META,
        status_order=ROADMAP_STATUS_ORDER,
        total=len(items),
    )


@roadmap_bp.route("/admin/roadmap/new", methods=["GET", "POST"])
@require_admin_page("roadmap")
def admin_new():
    if request.method == "POST":
        title = (request.form.get("title") or "").strip()
        if not title:
            flash("Give the item a title.", "error")
            return render_template("admin/roadmap/form.html", item=None,
                                    status_meta=ROADMAP_STATUS_META,
                                    status_order=ROADMAP_STATUS_ORDER, form=request.form,
                                    is_visible_checked=bool(request.form.get("is_visible")))
        status = request.form.get("status") or "idea"
        if status not in ROADMAP_STATUS_META:
            status = "idea"
        max_pos = db.session.query(db.func.max(RoadmapItem.position)) \
            .filter(RoadmapItem.status == status).scalar() or 0
        item = RoadmapItem(
            title=title[:160],
            description=(request.form.get("description") or "").strip() or None,
            category=(request.form.get("category") or "").strip()[:60] or None,
            status=status,
            position=max_pos + 1,
            is_visible=bool(request.form.get("is_visible")),
            target_date=_parse_date(request.form.get("target_date")),
            created_by=current_user if current_user.is_authenticated else None,
        )
        db.session.add(item)
        db.session.flush()
        AuditLog.log("roadmap.create", actor=current_user, target_type="roadmap_item",
                     target_id=item.id, meta={"title": item.title, "status": item.status},
                     ip=request.remote_addr)
        db.session.commit()
        flash("Roadmap item added.", "success")
        return redirect(url_for("roadmap.admin_list"))
    return render_template("admin/roadmap/form.html", item=None,
                           status_meta=ROADMAP_STATUS_META,
                           status_order=ROADMAP_STATUS_ORDER, form={},
                           is_visible_checked=True)


@roadmap_bp.route("/admin/roadmap/<int:item_id>/edit", methods=["GET", "POST"])
@require_admin_page("roadmap")
def admin_edit(item_id):
    item = RoadmapItem.query.get_or_404(item_id)
    if request.method == "POST":
        title = (request.form.get("title") or "").strip()
        if not title:
            flash("Give the item a title.", "error")
            return render_template("admin/roadmap/form.html", item=item,
                                    status_meta=ROADMAP_STATUS_META,
                                    status_order=ROADMAP_STATUS_ORDER, form=request.form,
                                    is_visible_checked=bool(request.form.get("is_visible")))
        status = request.form.get("status") or item.status
        if status not in ROADMAP_STATUS_META:
            status = item.status
        if status != item.status:
            max_pos = db.session.query(db.func.max(RoadmapItem.position)) \
                .filter(RoadmapItem.status == status).scalar() or 0
            item.position = max_pos + 1
        item.title = title[:160]
        item.description = (request.form.get("description") or "").strip() or None
        item.category = (request.form.get("category") or "").strip()[:60] or None
        item.status = status
        item.is_visible = bool(request.form.get("is_visible"))
        item.target_date = _parse_date(request.form.get("target_date"))
        AuditLog.log("roadmap.edit", actor=current_user, target_type="roadmap_item",
                     target_id=item.id, meta={"title": item.title, "status": item.status},
                     ip=request.remote_addr)
        db.session.commit()
        flash("Roadmap item updated.", "success")
        return redirect(url_for("roadmap.admin_list"))
    return render_template("admin/roadmap/form.html", item=item,
                           status_meta=ROADMAP_STATUS_META,
                           status_order=ROADMAP_STATUS_ORDER, form={},
                           is_visible_checked=item.is_visible)


@roadmap_bp.route("/admin/roadmap/<int:item_id>/status", methods=["POST"])
@require_admin_page("roadmap")
def admin_status(item_id):
    item = RoadmapItem.query.get_or_404(item_id)
    status = request.form.get("status")
    if status in ROADMAP_STATUS_META and status != item.status:
        max_pos = db.session.query(db.func.max(RoadmapItem.position)) \
            .filter(RoadmapItem.status == status).scalar() or 0
        item.status = status
        item.position = max_pos + 1
        AuditLog.log("roadmap.status", actor=current_user, target_type="roadmap_item",
                     target_id=item.id, meta={"status": status}, ip=request.remote_addr)
        db.session.commit()
        flash("Status updated.", "success")
    return redirect(url_for("roadmap.admin_list"))


@roadmap_bp.route("/admin/roadmap/<int:item_id>/visibility", methods=["POST"])
@require_admin_page("roadmap")
def admin_visibility(item_id):
    item = RoadmapItem.query.get_or_404(item_id)
    item.is_visible = not item.is_visible
    AuditLog.log("roadmap.visibility", actor=current_user, target_type="roadmap_item",
                 target_id=item.id, meta={"is_visible": item.is_visible}, ip=request.remote_addr)
    db.session.commit()
    flash("Shown on public roadmap." if item.is_visible else "Hidden from public roadmap.", "success")
    return redirect(url_for("roadmap.admin_list"))


@roadmap_bp.route("/admin/roadmap/<int:item_id>/move", methods=["POST"])
@require_admin_page("roadmap")
def admin_move(item_id):
    item = RoadmapItem.query.get_or_404(item_id)
    direction = request.form.get("direction")
    siblings = (RoadmapItem.query.filter_by(status=item.status)
                .order_by(RoadmapItem.position.asc(), RoadmapItem.created_at.asc()).all())
    idx = next((i for i, s in enumerate(siblings) if s.id == item.id), None)
    if idx is not None:
        swap_idx = idx - 1 if direction == "up" else idx + 1
        if 0 <= swap_idx < len(siblings):
            other = siblings[swap_idx]
            item.position, other.position = other.position, item.position
            db.session.commit()
    return redirect(url_for("roadmap.admin_list"))


@roadmap_bp.route("/admin/roadmap/<int:item_id>/delete", methods=["POST"])
@require_admin_page("roadmap")
def admin_delete(item_id):
    item = RoadmapItem.query.get_or_404(item_id)
    AuditLog.log("roadmap.delete", actor=current_user, target_type="roadmap_item",
                 target_id=item.id, meta={"title": item.title}, ip=request.remote_addr)
    db.session.delete(item)
    db.session.commit()
    flash("Roadmap item deleted.", "success")
    return redirect(url_for("roadmap.admin_list"))
