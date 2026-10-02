from datetime import datetime

from flask import Blueprint, render_template, redirect, url_for, request, flash, session
from flask_login import login_required, current_user

from app.extensions import db
from app.models import Project, Barcode, ActivityEvent, gen_project_barcode
from app.permissions import require_sidebar_item
from app.barcode_render import code128_data_uri

bp = Blueprint("projects", __name__, url_prefix="/projects")
bp.before_request(require_sidebar_item("projects"))


def _register_barcode(code: str, entity_type: str, entity_id: int):
    db.session.add(Barcode(code=code, entity_type=entity_type, entity_id=entity_id))


@bp.route("/")
@login_required
def list_projects():
    show_closed = request.args.get("closed") == "1"
    query = Project.query
    if not show_closed:
        query = query.filter_by(status="active")
    projects = query.order_by(Project.name).all()
    return render_template("projects/list.html", projects=projects, show_closed=show_closed)


@bp.route("/add", methods=["GET", "POST"])
@login_required
def add_project():
    if request.method == "POST":
        name = request.form.get("name", "").strip()
        if not name:
            flash("Name is required.", "danger")
            return render_template("projects/add.html")
        if Project.query.filter_by(name=name).first() is not None:
            flash(f"A project named '{name}' already exists.", "danger")
            return render_template("projects/add.html")

        barcode_code = request.form.get("barcode_code", "").strip() or gen_project_barcode()
        if Barcode.query.get(barcode_code) is not None:
            flash(f"Barcode '{barcode_code}' is already in use.", "danger")
            return render_template("projects/add.html")

        project = Project(
            name=name,
            code=request.form.get("code", "").strip() or None,
            description=request.form.get("description", "").strip() or None,
            barcode_code=barcode_code,
        )
        db.session.add(project)
        db.session.flush()
        _register_barcode(barcode_code, "project", project.id)
        db.session.commit()

        flash(f"Project '{project.name}' added.", "success")
        return redirect(url_for("projects.list_projects"))

    return render_template("projects/add.html")


@bp.route("/<int:project_id>/edit", methods=["GET", "POST"])
@login_required
def edit_project(project_id):
    project = Project.query.get_or_404(project_id)
    if request.method == "POST":
        # Same defensive pattern as Item/Tool edit: default to the current
        # value (not blank) if a field is unexpectedly absent from the
        # submitted form, rather than silently wiping it (the SKU-wipe bug
        # class found and fixed in Part 2).
        project.name = request.form.get("name", project.name).strip() or project.name
        project.code = request.form.get("code", project.code or "").strip() or None
        project.description = request.form.get("description", project.description or "").strip() or None
        db.session.commit()
        flash("Project updated.", "success")
        return redirect(url_for("projects.list_projects"))
    return render_template("projects/edit.html", project=project)


@bp.route("/<int:project_id>/close", methods=["POST"])
@login_required
def close_project(project_id):
    project = Project.query.get_or_404(project_id)
    project.status = "closed"
    project.closed_at = datetime.utcnow()
    if session.get("active_project_id") == project.id:
        session.pop("active_project_id", None)
        session.pop("active_project_name", None)
    db.session.add(ActivityEvent(
        event_type="project_close", entity_name=project.name, actor=current_user.username,
        local_user_id=current_user.id,
        detail="Project closed",
    ))
    db.session.commit()
    flash(f"'{project.name}' closed.", "info")
    return redirect(url_for("projects.list_projects"))


@bp.route("/<int:project_id>/reopen", methods=["POST"])
@login_required
def reopen_project(project_id):
    project = Project.query.get_or_404(project_id)
    project.status = "active"
    project.closed_at = None
    db.session.add(ActivityEvent(
        event_type="project_reopen", entity_name=project.name, actor=current_user.username,
        local_user_id=current_user.id,
        detail="Project reopened",
    ))
    db.session.commit()
    flash(f"'{project.name}' reopened.", "success")
    return redirect(url_for("projects.list_projects", closed="1"))


@bp.route("/<int:project_id>/delete", methods=["POST"])
@login_required
def delete_project(project_id):
    project = Project.query.get_or_404(project_id)
    if session.get("active_project_id") == project.id:
        session.pop("active_project_id", None)
        session.pop("active_project_name", None)
    Barcode.query.filter_by(code=project.barcode_code).delete()
    db.session.delete(project)
    db.session.commit()
    flash("Project deleted.", "info")
    return redirect(url_for("projects.list_projects"))


@bp.route("/<int:project_id>/barcode")
@login_required
def view_barcode(project_id):
    project = Project.query.get_or_404(project_id)
    return render_template("projects/barcode.html", project=project,
                            barcode_image=code128_data_uri(project.barcode_code))
