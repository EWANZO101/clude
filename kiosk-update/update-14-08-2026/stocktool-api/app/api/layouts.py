from flask import Blueprint, request, jsonify
from flask_jwt_extended import jwt_required, current_user
from app.extensions import db
from app.models.category import Category
from app.models.layout import DashboardLayout, DEFAULT_LAYOUT_COMPONENTS, slugify
from app.models.audit_log import AuditAction
from app.utils.decorators import admin_required
from app.utils.audit import log_action
from app.layout_components import catalog as component_catalog, validate_layout

api_layouts_bp = Blueprint("api_layouts", __name__, url_prefix="/api/layouts")


def _unique_slug(name: str, exclude_id: int = None) -> str:
    base = slugify(name)
    slug = base
    n = 2
    while True:
        q = DashboardLayout.query.filter_by(slug=slug)
        if exclude_id:
            q = q.filter(DashboardLayout.id != exclude_id)
        if not q.first():
            return slug
        slug = f"{base}-{n}"
        n += 1


def _valid_category_ids() -> set:
    return {c.id for c in Category.query.with_entities(Category.id).all()}


@api_layouts_bp.route("/component-catalog", methods=["GET"])
@jwt_required()
def get_component_catalog():
    """Everything Builder Mode needs to draw its palette + property panels,
    without hard-coding component knowledge into the admin templates."""
    return jsonify(component_catalog()), 200


@api_layouts_bp.route("/", methods=["GET"])
@jwt_required()
def list_layouts():
    layouts = DashboardLayout.query.order_by(DashboardLayout.name).all()
    return jsonify([l.to_dict(include_components=False) for l in layouts]), 200


@api_layouts_bp.route("/<int:layout_id>", methods=["GET"])
@jwt_required()
def get_layout(layout_id):
    layout = DashboardLayout.query.get_or_404(layout_id)
    return jsonify(layout.to_dict()), 200


@api_layouts_bp.route("/", methods=["POST"])
@jwt_required()
@admin_required
def create_layout():
    """Body: {"name": ..., "target_device": ..., "duplicate_from": <layout_id, optional>}
    Without duplicate_from, starts from the built-in default template."""
    data = request.get_json(silent=True) or {}
    name = (data.get("name") or "").strip()
    if not name:
        return jsonify({"error": "name is required"}), 400

    layout = DashboardLayout(
        name=name,
        slug=_unique_slug(name),
        target_device=(data.get("target_device") or "").strip() or None,
        created_by_id=current_user.id if current_user else None,
    )

    duplicate_from = data.get("duplicate_from")
    if duplicate_from:
        source = DashboardLayout.query.get(duplicate_from)
        if not source:
            return jsonify({"error": f"Layout {duplicate_from} not found to duplicate from"}), 400
        layout.draft = source.draft
    else:
        layout.draft = DEFAULT_LAYOUT_COMPONENTS

    db.session.add(layout)
    db.session.flush()
    log_action(AuditAction.LAYOUT_CREATED, "layout", layout.id, layout.name,
               f"Layout '{layout.name}' created" + (f" (duplicated from #{duplicate_from})" if duplicate_from else ""),
               user=current_user)
    db.session.commit()
    return jsonify(layout.to_dict()), 201


@api_layouts_bp.route("/<int:layout_id>/duplicate", methods=["POST"])
@jwt_required()
@admin_required
def duplicate_layout(layout_id):
    source = DashboardLayout.query.get_or_404(layout_id)
    data = request.get_json(silent=True) or {}
    name = (data.get("name") or f"Copy of {source.name}").strip()

    layout = DashboardLayout(
        name=name,
        slug=_unique_slug(name),
        target_device=None,  # never auto-assign a device to a duplicate — avoids two layouts silently fighting over one kiosk
        created_by_id=current_user.id if current_user else None,
    )
    layout.draft = source.draft
    db.session.add(layout)
    db.session.flush()
    log_action(AuditAction.LAYOUT_CREATED, "layout", layout.id, layout.name,
               f"Duplicated from '{source.name}' (#{source.id})", user=current_user)
    db.session.commit()
    return jsonify(layout.to_dict()), 201


@api_layouts_bp.route("/<int:layout_id>", methods=["PUT", "PATCH"])
@jwt_required()
@admin_required
def update_layout(layout_id):
    """Saves the draft. Never touches published_components — that only
    changes via the /publish endpoint. This is what makes it safe to
    experiment in Builder Mode without affecting a live kiosk screen."""
    layout = DashboardLayout.query.get_or_404(layout_id)
    data = request.get_json(silent=True) or {}

    if "name" in data:
        name = (data["name"] or "").strip()
        if not name:
            return jsonify({"error": "name cannot be empty"}), 400
        if name != layout.name:
            layout.slug = _unique_slug(name, exclude_id=layout.id)
        layout.name = name
    if "target_device" in data:
        layout.target_device = (data["target_device"] or "").strip() or None
    if "is_default" in data:
        if data["is_default"]:
            # Only one layout may be the global default fallback.
            DashboardLayout.query.filter(DashboardLayout.id != layout.id).update({"is_default": False})
        layout.is_default = bool(data["is_default"])

    if "components" in data:
        errors = validate_layout(data["components"], _valid_category_ids())
        if errors:
            return jsonify({"error": "Layout failed validation", "details": errors}), 400
        layout.draft = data["components"]

    log_action(AuditAction.LAYOUT_SAVED, "layout", layout.id, layout.name,
               "Draft saved", user=current_user)
    db.session.commit()
    return jsonify(layout.to_dict()), 200


@api_layouts_bp.route("/<int:layout_id>/validate", methods=["POST"])
@jwt_required()
@admin_required
def validate_draft(layout_id):
    """Lets the builder check-as-you-go without saving — used before the
    Publish button is enabled."""
    layout = DashboardLayout.query.get_or_404(layout_id)
    data = request.get_json(silent=True) or {}
    components = data.get("components", layout.draft)
    errors = validate_layout(components, _valid_category_ids())
    return jsonify({"valid": not errors, "errors": errors}), 200


@api_layouts_bp.route("/<int:layout_id>/publish", methods=["POST"])
@jwt_required()
@admin_required
def publish_layout(layout_id):
    layout = DashboardLayout.query.get_or_404(layout_id)
    errors = validate_layout(layout.draft, _valid_category_ids())
    if errors:
        return jsonify({"error": "Cannot publish — layout has validation errors", "details": errors}), 400

    layout.publish()
    log_action(AuditAction.LAYOUT_PUBLISHED, "layout", layout.id, layout.name,
               "Draft published to kiosks", user=current_user)
    db.session.commit()
    return jsonify(layout.to_dict()), 200


@api_layouts_bp.route("/<int:layout_id>/reset", methods=["POST"])
@jwt_required()
@admin_required
def reset_layout(layout_id):
    """Resets the DRAFT back to the built-in default template. Published
    kiosks are unaffected until the reset draft is published too — same
    safety net as any other draft edit."""
    layout = DashboardLayout.query.get_or_404(layout_id)
    layout.reset_to_default()
    log_action(AuditAction.LAYOUT_RESET, "layout", layout.id, layout.name,
               "Draft reset to default template", user=current_user)
    db.session.commit()
    return jsonify(layout.to_dict()), 200


@api_layouts_bp.route("/<int:layout_id>", methods=["DELETE"])
@jwt_required()
@admin_required
def delete_layout(layout_id):
    layout = DashboardLayout.query.get_or_404(layout_id)
    name = layout.name
    db.session.delete(layout)
    log_action(AuditAction.LAYOUT_DELETED, "layout", layout_id, name,
               f"Layout '{name}' deleted", user=current_user)
    db.session.commit()
    return jsonify({"message": f"Layout '{name}' removed"}), 200


@api_layouts_bp.route("/<int:layout_id>/preview-token", methods=["POST"])
@jwt_required()
@admin_required
def create_preview_token(layout_id):
    """Issues a short-lived token Builder Mode's preview iframe uses to
    view this layout's DRAFT rendered as a real kiosk screen — without
    publishing it, and without the iframe needing to carry a JWT (it's
    just an <iframe src="...">, which can't set an Authorization header)."""
    from flask import current_app, url_for
    from app.kiosk import state

    layout = DashboardLayout.query.get_or_404(layout_id)
    token = state.create_preview_token(layout.id)
    return jsonify({
        "token": token,
        "expires_in": state.PREVIEW_TOKEN_TTL_SECONDS,
        "preview_path": url_for("kiosk.preview", token=token),
    }), 200


@api_layouts_bp.route("/resolve", methods=["GET"])
@jwt_required()
def resolve_layout():
    """?device=<name> — what a kiosk with that device name should render:
    its own published layout if one targets it specifically, else the
    global default (is_default / target_device IS NULL) layout, else None
    (caller falls back to the hard-coded scan-only screen)."""
    device = request.args.get("device", "").strip()

    layout = None
    if device:
        layout = DashboardLayout.query.filter_by(target_device=device).filter(
            DashboardLayout.published_components.isnot(None)
        ).first()
    if not layout:
        layout = DashboardLayout.query.filter_by(is_default=True).filter(
            DashboardLayout.published_components.isnot(None)
        ).first()
    if not layout:
        layout = DashboardLayout.query.filter_by(target_device=None).filter(
            DashboardLayout.published_components.isnot(None)
        ).order_by(DashboardLayout.id).first()

    if not layout:
        return jsonify({"layout": None}), 200
    return jsonify({"layout": {"id": layout.id, "name": layout.name, "components": layout.published}}), 200
