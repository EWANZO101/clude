"""
Barcode viewing/printing/sharing.

Two different trust levels on purpose:

  - Items/tools/projects: barcode_code is just an inventory identifier,
    not a credential. GET /barcode/print/<type>/<id> is a genuinely
    public page (no login) -- that's what makes it a real "share this
    link" URL, since this kiosk's auth is Bearer-token-only (see
    app/auth.py) with no cookies, so a plain clicked/shared link can
    never carry a login session anyway. Making these specific pages
    intentionally public, rather than broken-when-not-logged-in, is
    the honest choice given that constraint.

  - Users: badge_code IS the login credential (see app/routes_auth.py
    -- there's no password, badge_code is the only thing standing
    between "logged out" and "logged in as this person"). There is
    deliberately NO public print/share page for a user's badge -- only
    the authenticated in-app viewer below, gated to admin. Printing a
    replacement badge is still fully supported, just requires being
    logged in as an admin to do it, the same as creating the account
    in the first place.
"""
from flask import Blueprint, render_template, jsonify, Response, g
from app.models import db, Item, Tool, Project, LocalUser, WireCoil
from app.auth import login_required
from app.barcode_render import generate_barcode_svg

barcode_view_bp = Blueprint("barcode_view", __name__)

_ENTITY_MODELS = {"item": Item, "tool": Tool, "project": Project, "wire": WireCoil}


@barcode_view_bp.route("/barcode/print/<entity_type>/<int:entity_id>", methods=["GET"])
def print_barcode(entity_type, entity_id):
    """Public, no login required -- see module docstring for why this
    is safe for items/tools/projects specifically (and why users are
    deliberately NOT handled here at all)."""
    model = _ENTITY_MODELS.get(entity_type)
    if not model:
        return jsonify({"error": "Unknown entity type."}), 404

    entity = db.session.get(model, entity_id)
    if not entity or not entity.barcode_code:
        return jsonify({"error": "Not found, or no barcode assigned yet."}), 404

    svg = generate_barcode_svg(entity.barcode_code)
    display_name = getattr(entity, "name", None) or getattr(entity, "username", None) or entity.barcode_code
    return render_template(
        "barcode_print.html",
        entity_name=display_name,
        code=entity.barcode_code,
        svg=svg,
        entity_type=entity_type,
    )


@barcode_view_bp.route("/api/admin/barcode-svg/<entity_type>/<int:entity_id>", methods=["GET"])
@login_required
def barcode_svg(entity_type, entity_id):
    """Authenticated SVG fetch used by the in-app "view/print barcode"
    modal for all four entity types. Items/tools/projects: any logged-
    in role can view/print (reprinting a lost inventory label isn't an
    admin-only action). Users: admin only, since badge_code is a login
    credential -- viewing/printing someone else's badge is exactly the
    kind of thing that should require admin rights, the same as
    creating or editing that account does."""
    if entity_type == "user":
        if g.session["role"] != "admin":
            return jsonify({"error": "You don't have permission to do that."}), 403
        entity = db.session.get(LocalUser, entity_id)
        code = entity.badge_code if entity else None
    else:
        model = _ENTITY_MODELS.get(entity_type)
        if not model:
            return jsonify({"error": "Unknown entity type."}), 400
        entity = db.session.get(model, entity_id)
        code = entity.barcode_code if entity else None

    if not entity or not code:
        return jsonify({"error": "Not found, or no code assigned yet."}), 404

    svg = generate_barcode_svg(code)
    return Response(svg, mimetype="image/svg+xml")
