from flask import jsonify


def api_success(data=None, meta=None, status=200):
    payload = {"success": True, "data": data if data is not None else {}}
    if meta is not None:
        payload["meta"] = meta
    return jsonify(payload), status


def api_error(code, message, status=400):
    return jsonify({"success": False, "error": {"code": code, "message": message}}), status


def pagination_meta(pagination):
    return {
        "page": pagination.page,
        "per_page": pagination.per_page,
        "total": pagination.total,
        "pages": pagination.pages,
    }
