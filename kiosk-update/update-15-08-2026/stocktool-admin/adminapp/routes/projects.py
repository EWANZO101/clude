from flask import Blueprint, render_template, redirect, url_for, flash, request
from adminapp.utils.api_client import api_get, api_post, api_put, api_delete, APIError
from adminapp.utils.decorators import login_required, admin_required
from adminapp.utils.formatting import hydrate, hydrate_list

projects_bp = Blueprint("projects", __name__, url_prefix="/projects")

_DATE_FIELDS = ["created_at", "updated_at"]


@projects_bp.route("/")
@login_required
def index():
    search = request.args.get("q", "").strip()
    try:
        projects = api_get("/api/projects/", params={"q": search})
    except APIError as e:
        flash(e.message, "danger")
        projects = []
    hydrate_list(projects, _DATE_FIELDS)

    from adminapp.utils.layout_surface import get_published_layout
    from adminapp.utils.layout_columns import COLUMN_META
    layout_components = get_published_layout("admin_projects")
    if layout_components:
        stats = {"total": {"value": len(projects), "label": "Total projects"}}
        return render_template("projects/index_generic.html", projects=projects, search=search,
                                layout_components=layout_components, column_meta=COLUMN_META["projects"],
                                stats=stats)

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

        try:
            project = api_post("/api/projects/", {
                "name": name,
                "code": request.form.get("code", "").strip() or None,
                "description": request.form.get("description", "").strip() or None,
            })
        except APIError as e:
            flash(e.message, "danger")
            return render_template("projects/form.html", project=None, action="Add")

        flash(f"Project '{project['name']}' added.", "success")
        return redirect(url_for("projects.index"))

    return render_template("projects/form.html", project=None, action="Add")


@projects_bp.route("/<int:project_id>")
@login_required
def view(project_id):
    try:
        project = api_get(f"/api/projects/{project_id}")
    except APIError as e:
        flash(e.message, "danger")
        return redirect(url_for("projects.index"))
    hydrate(project, _DATE_FIELDS)
    return render_template("projects/view.html", project=project)


@projects_bp.route("/<int:project_id>/edit", methods=["GET", "POST"])
@login_required
@admin_required
def edit(project_id):
    try:
        project = api_get(f"/api/projects/{project_id}")
    except APIError as e:
        flash(e.message, "danger")
        return redirect(url_for("projects.index"))

    if request.method == "POST":
        name = request.form.get("name", "").strip()
        if not name:
            flash("Project name is required.", "danger")
            return render_template("projects/form.html", project=project, action="Edit")

        try:
            project = api_put(f"/api/projects/{project_id}", {
                "name": name,
                "code": request.form.get("code", "").strip() or None,
                "description": request.form.get("description", "").strip() or None,
            })
        except APIError as e:
            flash(e.message, "danger")
            return render_template("projects/form.html", project=project, action="Edit")

        flash(f"Project '{project['name']}' updated.", "success")
        return redirect(url_for("projects.view", project_id=project["id"]))

    return render_template("projects/form.html", project=project, action="Edit")


@projects_bp.route("/<int:project_id>/delete", methods=["POST"])
@login_required
@admin_required
def delete(project_id):
    try:
        result = api_delete(f"/api/projects/{project_id}")
    except APIError as e:
        flash(e.message, "danger")
        return redirect(url_for("projects.index"))
    flash(result.get("message", "Project removed."), "info")
    return redirect(url_for("projects.index"))
