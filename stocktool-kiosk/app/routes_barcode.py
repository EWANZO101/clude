from flask import Blueprint, request, jsonify
from app.models import db, Barcode, Item, Tool, Project, LocalUser, WireCoil
from app.auth import permission_required

barcode_bp = Blueprint("barcode", __name__, url_prefix="/api/barcode")

_ENTITY_MODEL = {"item": Item, "tool": Tool, "project": Project, "wire": WireCoil}


@barcode_bp.route("/lookup", methods=["POST"])
def lookup():
    """
    Scan-to-search — works identically whether the code arrived from a
    USB keyboard-wedge scanner (just types + Enter into a text field) or
    a camera-based scanner (JS decodes the frame client-side and posts
    the resulting string here). The API doesn't need to know which.

    Also recognises a scanned USER badge (not just item/tool/project),
    for the "scan who's doing this, then scan what they're doing it to"
    workflow -- see app/templates/index.html's Scan tab. Checked
    against the shared Barcode table first, then LocalUser.badge_code
    as a fallback, since those are two genuinely separate tables (a
    badge is a login credential, not an inventory barcode registration
    -- see app/models.py's LocalUser docstring).
    """
    data = request.get_json(silent=True) or {}
    code = (data.get("code") or "").strip().upper()
    if not code:
        return jsonify({"error": "code is required."}), 400

    bc = Barcode.query.filter_by(code=code).first()
    if bc:
        model = _ENTITY_MODEL.get(bc.entity_type)
        entity = db.session.get(model, bc.entity_id) if model else None
        if not entity:
            return jsonify({"error": "Barcode is registered but its target no longer exists."}), 404
        return jsonify({"entity_type": bc.entity_type, "entity": entity.to_dict()}), 200

    user = LocalUser.query.filter_by(badge_code=code).first()
    if user and user.is_active:
        return jsonify({"entity_type": "user", "entity": user.to_dict()}), 200

    return jsonify({"error": f"No match for code '{code}'."}), 404


@barcode_bp.route("/register", methods=["POST"])
@permission_required("admin", "supervisor")
def register():
    """
    Assigns a new barcode to an existing item/tool/project. Permission-
    gated (see app/auth.py) — this is an operational action on data the
    cloud already owns, not a user-management/admin console feature.
    """
    data = request.get_json(silent=True) or {}
    code = (data.get("code") or "").strip().upper()
    entity_type = (data.get("entity_type") or "").strip().lower()
    entity_id = data.get("entity_id")

    if not code:
        return jsonify({"error": "code is required."}), 400
    if entity_type not in _ENTITY_MODEL:
        return jsonify({"error": "entity_type must be one of: item, tool, project, wire."}), 400

    model = _ENTITY_MODEL[entity_type]
    entity = db.session.get(model, entity_id) if entity_id else None
    if not entity:
        return jsonify({"error": f"No {entity_type} with that id."}), 404

    if Barcode.query.filter_by(code=code).first():
        return jsonify({"error": f"Code '{code}' is already registered."}), 409

    bc = Barcode(code=code, entity_type=entity_type, entity_id=entity.id)
    entity.barcode_code = code
    if hasattr(entity, "dirty"):  # WireCoil isn't a SyncMixin model, unlike item/tool/project
        entity.dirty = True
    db.session.add(bc)
    db.session.commit()
    return jsonify(bc.to_dict()), 201
