import os
from flask import Blueprint, request, jsonify, current_app, send_from_directory, abort
from flask_jwt_extended import jwt_required, current_user
from app.extensions import db
from app.models.barcode import Barcode
from app.utils.barcode_helper import generate_barcode
from app.utils.decorators import admin_required

api_barcodes_bp = Blueprint("api_barcodes", __name__, url_prefix="/api/barcodes")


@api_barcodes_bp.route("/lookup", methods=["POST"])
@jwt_required()
def lookup():
    """
    Generic barcode lookup — given any scanned code, identify what it is
    (user badge, item, tool, or project) and return its details.
    """
    data = request.get_json(silent=True) or {}
    code = data.get("code", "").strip().upper()
    if not code:
        return jsonify({"error": "code is required"}), 400

    bc = Barcode.query.filter_by(code=code).first()
    if not bc:
        return jsonify({"error": f"No match for code '{code}'"}), 404

    entity = bc.user or bc.item or bc.tool or bc.project
    return jsonify({
        "entity_type": bc.entity_type,
        "code": bc.code,
        "entity": entity.to_dict() if entity else None,
    }), 200


@api_barcodes_bp.route("/<code>", methods=["GET"])
@jwt_required()
def get_barcode(code):
    bc = Barcode.query.filter_by(code=code.upper()).first_or_404()
    return jsonify(bc.to_dict()), 200


@api_barcodes_bp.route("/image/<code>", methods=["GET"])
def barcode_image(code):
    """
    Serves the barcode PNG directly. Deliberately not JWT-protected — a
    printed barcode is already physically accessible to anyone near it, and
    the admin frontend's <img> tags need to load these without juggling
    Authorization headers on an <img> request. The code itself is an
    opaque 12-char token; this endpoint reveals nothing beyond "yes, an
    image exists for this exact code".
    """
    bc = Barcode.query.filter_by(code=code.upper()).first()
    if not bc or not bc.image_path:
        abort(404)
    directory = current_app.config["BARCODE_OUTPUT_DIR"]
    filename = os.path.basename(bc.image_path)
    return send_from_directory(directory, filename)


@api_barcodes_bp.route("/<entity_type>/<int:entity_id>/regenerate", methods=["POST"])
@jwt_required()
@admin_required
def regenerate(entity_type, entity_id):
    if entity_type not in ("item", "tool", "user", "project"):
        return jsonify({"error": "Unknown entity_type"}), 400
    bc = generate_barcode(entity_type, entity_id)
    db.session.commit()
    return jsonify(bc.to_dict()), 200
