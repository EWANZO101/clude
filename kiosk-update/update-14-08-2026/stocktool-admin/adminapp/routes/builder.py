from flask import Blueprint, render_template, request, jsonify
from adminapp.utils.api_client import api_get, api_post, api_put, api_delete, APIError
from adminapp.utils.decorators import login_required, admin_required

builder_bp = Blueprint("builder", __name__, url_prefix="/builder")


def _proxy_json(fn, *args, **kwargs):
    try:
        data = fn(*args, **kwargs)
        return jsonify(data if data is not None else {}), 200
    except APIError as e:
        return jsonify({"error": e.message}), e.status_code


# ── Page ─────────────────────────────────────────────────────────────────

@builder_bp.route("/")
@login_required
@admin_required
def index():
    return render_template("builder/index.html")


# ── JSON proxy — browser JS talks to these (same-origin, CSRF-protected)
#    instead of stocktool-api directly, since the JWT lives server-side in
#    this app's session and was never exposed to the browser. ──────────────

@builder_bp.route("/api/catalog")
@login_required
@admin_required
def api_catalog():
    return _proxy_json(api_get, "/api/layouts/component-catalog")


@builder_bp.route("/api/units")
@login_required
@admin_required
def api_units():
    return _proxy_json(api_get, "/api/units/")


@builder_bp.route("/api/categories")
@login_required
@admin_required
def api_categories():
    return _proxy_json(api_get, "/api/categories/")


@builder_bp.route("/api/layouts")
@login_required
@admin_required
def api_layouts():
    return _proxy_json(api_get, "/api/layouts/")


@builder_bp.route("/api/layouts/<int:layout_id>")
@login_required
@admin_required
def api_layout(layout_id):
    return _proxy_json(api_get, f"/api/layouts/{layout_id}")


@builder_bp.route("/api/layouts", methods=["POST"])
@login_required
@admin_required
def api_layout_create():
    return _proxy_json(api_post, "/api/layouts/", request.get_json(silent=True) or {})


@builder_bp.route("/api/layouts/<int:layout_id>", methods=["PUT"])
@login_required
@admin_required
def api_layout_save(layout_id):
    return _proxy_json(api_put, f"/api/layouts/{layout_id}", request.get_json(silent=True) or {})


@builder_bp.route("/api/layouts/<int:layout_id>/validate", methods=["POST"])
@login_required
@admin_required
def api_layout_validate(layout_id):
    return _proxy_json(api_post, f"/api/layouts/{layout_id}/validate", request.get_json(silent=True) or {})


@builder_bp.route("/api/layouts/<int:layout_id>/publish", methods=["POST"])
@login_required
@admin_required
def api_layout_publish(layout_id):
    return _proxy_json(api_post, f"/api/layouts/{layout_id}/publish", {})


@builder_bp.route("/api/layouts/<int:layout_id>/reset", methods=["POST"])
@login_required
@admin_required
def api_layout_reset(layout_id):
    return _proxy_json(api_post, f"/api/layouts/{layout_id}/reset", {})


@builder_bp.route("/api/layouts/<int:layout_id>/duplicate", methods=["POST"])
@login_required
@admin_required
def api_layout_duplicate(layout_id):
    return _proxy_json(api_post, f"/api/layouts/{layout_id}/duplicate", request.get_json(silent=True) or {})


@builder_bp.route("/api/layouts/<int:layout_id>", methods=["DELETE"])
@login_required
@admin_required
def api_layout_delete(layout_id):
    return _proxy_json(api_delete, f"/api/layouts/{layout_id}")


@builder_bp.route("/api/layouts/<int:layout_id>/preview-token", methods=["POST"])
@login_required
@admin_required
def api_layout_preview_token(layout_id):
    return _proxy_json(api_post, f"/api/layouts/{layout_id}/preview-token", {})
