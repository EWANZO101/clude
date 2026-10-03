"""
POST /licence-activate — backs the "Activate Licence" button on
license_invalid.html. Writes the submitted key to license.txt, then
re-runs the same validate_license() the app used at startup so the
running process's in-memory state updates immediately (no restart
needed to pick up a freshly-entered key).
"""
from flask import Blueprint, request, jsonify

import license as stocktool_license

license_bp = Blueprint("license", __name__)


@license_bp.route("/licence-activate", methods=["POST"])
def licence_activate():
    data = request.get_json(silent=True) or {}
    key = (data.get("license_key") or "").strip().upper()
    if not key or len(key) < 10:
        return jsonify({"success": False, "error": "Please enter a valid licence key."}), 400

    with open(stocktool_license.LICENSE_FILE, "w") as f:
        f.write(key + "\n")

    ok = stocktool_license.validate_license(key)
    if ok:
        state = stocktool_license.get_state()
        msg = f"Activated — {state.get('customer') or 'licence'} ({state.get('tier') or 'licensed'})"
        return jsonify({"success": True, "message": msg}), 200

    error = stocktool_license.get_state().get("error") or "Licence invalid."
    return jsonify({"success": False, "error": error}), 400
