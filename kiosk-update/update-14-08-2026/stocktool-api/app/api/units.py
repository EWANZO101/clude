from flask import Blueprint, jsonify
from flask_jwt_extended import jwt_required
from app.units import catalog

api_units_bp = Blueprint("api_units", __name__, url_prefix="/api/units")


@api_units_bp.route("/", methods=["GET"])
@jwt_required()
def list_units():
    return jsonify(catalog()), 200
