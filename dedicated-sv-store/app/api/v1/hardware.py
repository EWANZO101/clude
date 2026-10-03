from flask import request

from app.api.v1 import api_v1_bp
from app.api.v1.helpers import api_success, api_error, pagination_meta
from app.hardware.registry import HARDWARE_REGISTRY


def _serialize_hardware(item):
    return {
        "id": item.id,
        "model_name": item.model_name,
        "brand": item.brand.name if item.brand else None,
        "price": float(item.price or 0),
        "availability": item.availability.value,
    }


@api_v1_bp.route("/hardware")
def hardware_categories():
    return api_success({slug: entry["label"] for slug, entry in HARDWARE_REGISTRY.items()})


@api_v1_bp.route("/hardware/<category>")
def hardware_list(category):
    entry = HARDWARE_REGISTRY.get(category)
    if entry is None:
        return api_error("NOT_FOUND", f"Unknown hardware category '{category}'.", 404)

    page = request.args.get("page", 1, type=int)
    per_page = min(request.args.get("per_page", 25, type=int), 100)
    query = entry["model"].query.filter_by(is_active=True).order_by(entry["model"].model_name)
    pagination = query.paginate(page=page, per_page=per_page, error_out=False)
    return api_success(
        [_serialize_hardware(item) for item in pagination.items], meta=pagination_meta(pagination)
    )
