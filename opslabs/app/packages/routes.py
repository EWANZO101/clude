"""
Admin-managed service packages (pricing cards on /services/<slug> pages).

Admin (staff+):
  GET  /admin/packages                  list, grouped by service
  GET  /admin/packages/new              new-package form
  POST /admin/packages/new              create
  GET  /admin/packages/<id>/edit        edit-package form
  POST /admin/packages/<id>/edit        update
  POST /admin/packages/<id>/visibility  toggle shown on the public service page
  POST /admin/packages/<id>/move        nudge up/down within its service
  POST /admin/packages/<id>/delete      remove
"""
from flask import render_template, request, redirect, url_for, flash
from flask_login import current_user

from . import packages_bp
from .. import db
from ..models_business import ServicePackage, AuditLog, SERVICE_PACKAGE_SLUGS
from ..services_data import SERVICES_ORDERED
from ..rbac import require_admin_page


def _grouped(items):
    buckets = {slug: [] for slug in SERVICE_PACKAGE_SLUGS}
    for it in items:
        buckets.setdefault(it.service_slug, []).append(it)
    return buckets


def _service_names():
    names = {slug: data["name"] for slug, data in SERVICES_ORDERED}
    for slug in SERVICE_PACKAGE_SLUGS:
        names.setdefault(slug, slug)
    return names


@packages_bp.route("/admin/packages")
@require_admin_page("packages")
def admin_list():
    items = (ServicePackage.query
             .order_by(ServicePackage.service_slug.asc(),
                       ServicePackage.position.asc(),
                       ServicePackage.created_at.asc()).all())
    return render_template(
        "admin/packages/list.html",
        columns=_grouped(items),
        service_names=_service_names(),
        service_slugs=SERVICE_PACKAGE_SLUGS,
        total=len(items),
    )


@packages_bp.route("/admin/packages/new", methods=["GET", "POST"])
@require_admin_page("packages")
def admin_new():
    if request.method == "POST":
        name = (request.form.get("name") or "").strip()
        slug = request.form.get("service_slug") or ""
        if not name or slug not in SERVICE_PACKAGE_SLUGS:
            flash("Give the package a name and choose a valid service.", "error")
            return render_template("admin/packages/form.html", item=None,
                                    service_names=_service_names(),
                                    service_slugs=SERVICE_PACKAGE_SLUGS, form=request.form,
                                    is_visible_checked=bool(request.form.get("is_visible")))
        max_pos = db.session.query(db.func.max(ServicePackage.position)) \
            .filter(ServicePackage.service_slug == slug).scalar() or 0
        item = ServicePackage(
            service_slug=slug,
            name=name[:120],
            description=(request.form.get("description") or "").strip() or None,
            features=(request.form.get("features") or "").strip() or None,
            position=max_pos + 1,
            is_visible=bool(request.form.get("is_visible")),
            created_by=current_user if current_user.is_authenticated else None,
        )
        db.session.add(item)
        db.session.flush()
        AuditLog.log("package.create", actor=current_user, target_type="service_package",
                     target_id=item.id, meta={"name": item.name, "service_slug": item.service_slug},
                     ip=request.remote_addr)
        db.session.commit()
        flash("Package added.", "success")
        return redirect(url_for("packages.admin_list"))
    return render_template("admin/packages/form.html", item=None,
                           service_names=_service_names(),
                           service_slugs=SERVICE_PACKAGE_SLUGS, form={},
                           is_visible_checked=True)


@packages_bp.route("/admin/packages/<int:item_id>/edit", methods=["GET", "POST"])
@require_admin_page("packages")
def admin_edit(item_id):
    item = ServicePackage.query.get_or_404(item_id)
    if request.method == "POST":
        name = (request.form.get("name") or "").strip()
        slug = request.form.get("service_slug") or item.service_slug
        if not name:
            flash("Give the package a name.", "error")
            return render_template("admin/packages/form.html", item=item,
                                    service_names=_service_names(),
                                    service_slugs=SERVICE_PACKAGE_SLUGS, form=request.form,
                                    is_visible_checked=bool(request.form.get("is_visible")))
        if slug not in SERVICE_PACKAGE_SLUGS:
            slug = item.service_slug
        if slug != item.service_slug:
            max_pos = db.session.query(db.func.max(ServicePackage.position)) \
                .filter(ServicePackage.service_slug == slug).scalar() or 0
            item.position = max_pos + 1
        item.service_slug = slug
        item.name = name[:120]
        item.description = (request.form.get("description") or "").strip() or None
        item.features = (request.form.get("features") or "").strip() or None
        item.is_visible = bool(request.form.get("is_visible"))
        AuditLog.log("package.edit", actor=current_user, target_type="service_package",
                     target_id=item.id, meta={"name": item.name, "service_slug": item.service_slug},
                     ip=request.remote_addr)
        db.session.commit()
        flash("Package updated.", "success")
        return redirect(url_for("packages.admin_list"))
    return render_template("admin/packages/form.html", item=item,
                           service_names=_service_names(),
                           service_slugs=SERVICE_PACKAGE_SLUGS, form={},
                           is_visible_checked=item.is_visible)


@packages_bp.route("/admin/packages/<int:item_id>/visibility", methods=["POST"])
@require_admin_page("packages")
def admin_visibility(item_id):
    item = ServicePackage.query.get_or_404(item_id)
    item.is_visible = not item.is_visible
    AuditLog.log("package.visibility", actor=current_user, target_type="service_package",
                 target_id=item.id, meta={"is_visible": item.is_visible}, ip=request.remote_addr)
    db.session.commit()
    flash("Shown on the service page." if item.is_visible else "Hidden from the service page.", "success")
    return redirect(url_for("packages.admin_list"))


@packages_bp.route("/admin/packages/<int:item_id>/move", methods=["POST"])
@require_admin_page("packages")
def admin_move(item_id):
    item = ServicePackage.query.get_or_404(item_id)
    direction = request.form.get("direction")
    siblings = (ServicePackage.query.filter_by(service_slug=item.service_slug)
                .order_by(ServicePackage.position.asc(), ServicePackage.created_at.asc()).all())
    idx = next((i for i, s in enumerate(siblings) if s.id == item.id), None)
    if idx is not None:
        swap_idx = idx - 1 if direction == "up" else idx + 1
        if 0 <= swap_idx < len(siblings):
            other = siblings[swap_idx]
            item.position, other.position = other.position, item.position
            db.session.commit()
    return redirect(url_for("packages.admin_list"))


@packages_bp.route("/admin/packages/<int:item_id>/delete", methods=["POST"])
@require_admin_page("packages")
def admin_delete(item_id):
    item = ServicePackage.query.get_or_404(item_id)
    AuditLog.log("package.delete", actor=current_user, target_type="service_package",
                 target_id=item.id, meta={"name": item.name}, ip=request.remote_addr)
    db.session.delete(item)
    db.session.commit()
    flash("Package deleted.", "success")
    return redirect(url_for("packages.admin_list"))
