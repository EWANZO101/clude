from flask import Blueprint, render_template, redirect, url_for, flash, request
from flask_login import login_required
from app.extensions import db
from app.models.project import Project
from app.models.audit_log import AuditAction
from app.utils.decorators import admin_required
from app.utils.audit import log_action
from app.utils.barcode_helper import generate_barcode

projects_bp = Blueprint("projects", __name__, url_prefix="/projects")


@projects_bp.route("/")
@login_required
def index():
    search = request.args.get("q", "").strip()
    query = Project.query.filter_by(is_active=True)
    if search:
        query = query.filter(Project.name.ilike(f"%{search}%") | Project.code.ilike(f"%{search}%"))
    projects = query.order_by(Project.name.asc()).all()
    return render_template("projects/index.html", projects=projects, search=search)


@projects_bp.route("/add", methods=["GET", "POST"])
@login_required
@admin_required
def add():
    if request.method == "POST":
        name = request.form.get("name", "").strip()
        if not name:
            flash("Project name is required.", "danger")
            return render_template("projects/form.html", project=None, action="Add")

        project = Project(
            name=name,
            code=request.form.get("code", "").strip() or None,
            description=request.form.get("description", "").strip() or None,
        )
        db.session.add(project)
        db.session.flush()

        generate_barcode("project", project.id)

        log_action(AuditAction.PROJECT_CREATED, "project", project.id, project.name,
                   f"Project '{project.name}' created")
        db.session.commit()
        flash(f"Project '{project.name}' added.", "success")
        return redirect(url_for("projects.index"))

    return render_template("projects/form.html", project=None, action="Add")


@projects_bp.route("/<int:project_id>")
@login_required
def view(project_id):
    project = Project.query.get_or_404(project_id)
    return render_template("projects/view.html", project=project)


@projects_bp.route("/<int:project_id>/edit", methods=["GET", "POST"])
@login_required
@admin_required
def edit(project_id):
    project = Project.query.get_or_404(project_id)

    if request.method == "POST":
        name = request.form.get("name", "").strip()
        if not name:
            flash("Project name is required.", "danger")
            return render_template("projects/form.html", project=project, action="Edit")

        project.name = name
        project.code = request.form.get("code", "").strip() or None
        project.description = request.form.get("description", "").strip() or None

        log_action(AuditAction.PROJECT_UPDATED, "project", project.id, project.name,
                   f"Project '{project.name}' updated")
        db.session.commit()
        flash(f"Project '{project.name}' updated.", "success")
        return redirect(url_for("projects.view", project_id=project.id))

    return render_template("projects/form.html", project=project, action="Edit")


@projects_bp.route("/<int:project_id>/delete", methods=["POST"])
@login_required
@admin_required
def delete(project_id):
    project = Project.query.get_or_404(project_id)
    project.is_active = False  # soft delete
    log_action(AuditAction.PROJECT_DELETED, "project", project.id, project.name,
               f"Project '{project.name}' removed")
    db.session.commit()
    flash(f"Project '{project.name}' removed.", "info")
    return redirect(url_for("projects.index"))
