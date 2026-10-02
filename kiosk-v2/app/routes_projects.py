from flask import Blueprint, jsonify
from app.models import db, Project

projects_bp = Blueprint("projects", __name__, url_prefix="/api/projects")


@projects_bp.route("", methods=["GET"])
def list_projects():
    projects = Project.query.filter_by(is_active=True).order_by(Project.name.asc()).all()
    return jsonify([p.to_dict() for p in projects]), 200


@projects_bp.route("/<int:project_id>", methods=["GET"])
def get_project(project_id):
    project = db.session.get(Project, project_id)
    if not project:
        return jsonify({"error": "Project not found."}), 404
    return jsonify(project.to_dict()), 200
