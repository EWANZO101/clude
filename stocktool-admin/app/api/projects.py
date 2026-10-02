from flask import Blueprint, request, jsonify
from flask_jwt_extended import jwt_required, current_user
from app.extensions import db
from app.models.project import Project
from app.models.audit_log import AuditAction
from app.utils.decorators import admin_required
from app.utils.audit import log_action
from app.utils.barcode_helper import generate_barcode

api_projects_bp = Blueprint("api_projects", __name__, url_prefix="/api/projects")


@api_projects_bp.route("/", methods=["GET"])
@jwt_required()
def list_projects():
    search = request.args.get("q", "").strip()
    query = Project.query.filter_by(is_active=True)
    if search:
        query = query.filter(Project.name.ilike(f"%{search}%") | Project.code.ilike(f"%{search}%"))
    projects = query.order_by(Project.name).all()
    return jsonify([p.to_dict() for p in projects]), 200


@api_projects_bp.route("/<int:project_id>", methods=["GET"])
@jwt_required()
def get_project(project_id):
    project = Project.query.get_or_404(project_id)
    return jsonify(project.to_dict()), 200


@api_projects_bp.route("/", methods=["POST"])
@jwt_required()
@admin_required
def create_project():
    data = request.get_json(silent=True) or {}
    name = data.get("name", "").strip()
    if not name:
        return jsonify({"error": "name is required"}), 400

    project = Project(
        name=name,
        code=data.get("code") or None,
        description=data.get("description") or None,
    )
    db.session.add(project)
    db.session.flush()
    generate_barcode("project", project.id)
    log_action(AuditAction.PROJECT_CREATED, "project", project.id, project.name,
               "Created via API", user=current_user)
    db.session.commit()
    return jsonify(project.to_dict()), 201


@api_projects_bp.route("/<int:project_id>", methods=["PUT"])
@jwt_required()
@admin_required
def update_project(project_id):
    project = Project.query.get_or_404(project_id)
    data = request.get_json(silent=True) or {}
    if "name" in data:
        if not data["name"].strip():
            return jsonify({"error": "name cannot be empty"}), 400
        project.name = data["name"].strip()
    if "code" in data:
        project.code = data["code"] or None
    if "description" in data:
        project.description = data["description"] or None
    log_action(AuditAction.PROJECT_UPDATED, "project", project.id, project.name,
               "Updated via API", user=current_user)
    db.session.commit()
    return jsonify(project.to_dict()), 200


@api_projects_bp.route("/<int:project_id>", methods=["DELETE"])
@jwt_required()
@admin_required
def delete_project(project_id):
    project = Project.query.get_or_404(project_id)
    project.is_active = False
    log_action(AuditAction.PROJECT_DELETED, "project", project.id, project.name,
               "Deleted via API", user=current_user)
    db.session.commit()
    return jsonify({"message": f"Project '{project.name}' removed"}), 200
