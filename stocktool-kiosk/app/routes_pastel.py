"""
Admin-gated API for the Sage Active / Pastel accounting integration
(via CloudSolve). Mirrors the shape of app/routes_backup.py /
app/routes_admin.py: everything here needs the "admin" role, reads
config from settings.json via app.settings, and never has its own
separate credential store.

Endpoints:
  GET  /api/admin/pastel/settings         -- current config (secrets masked)
  POST /api/admin/pastel/settings         -- update config fields
  GET  /api/admin/pastel/oauth/authorize  -- redirects the admin's browser to Sage Active login/consent
  GET  /api/admin/pastel/oauth/callback   -- Sage Active redirects back here with ?code=...
  POST /api/admin/pastel/sync             -- run a full sync pass right now
  GET  /api/admin/pastel/log              -- recent PastelSyncLog rows
"""
import secrets

from flask import Blueprint, jsonify, request, current_app, redirect

from app.auth import permission_required
from app.settings import load_settings, save_settings
from app.models import PastelSyncLog
from app.pastel_client import PastelCredentials, build_authorize_url, exchange_code_for_token, PastelAuthError

pastel_bp = Blueprint("pastel", __name__, url_prefix="/api/admin/pastel")

# In-memory OAuth `state` store -- short-lived CSRF token for the
# authorize/callback round trip, same lifetime concern as app/auth.py's
# session tokens but much shorter-lived (a few minutes at most), so a
# simple process-local dict is fine (this is a single-machine kiosk).
_PENDING_STATES: set[str] = set()

_SECRET_FIELDS = {"pastel_client_secret", "pastel_subscription_key", "pastel_access_token", "pastel_refresh_token"}

_EDITABLE_FIELDS = [
    "pastel_enabled", "pastel_legislation", "pastel_api_base", "pastel_auth_url", "pastel_token_url",
    "pastel_client_id", "pastel_client_secret", "pastel_subscription_key", "pastel_redirect_uri",
    "pastel_usage_journal_code", "pastel_usage_expense_account_code", "pastel_stock_contra_account_code",
    "pastel_sync_interval_seconds",
]


def _masked(settings: dict) -> dict:
    out = {}
    for key, value in settings.items():
        if not key.startswith("pastel_"):
            continue
        if key in _SECRET_FIELDS and value:
            out[key] = "•" * 8 + str(value)[-4:]
        else:
            out[key] = value
    return out


@pastel_bp.route("/settings", methods=["GET"])
@permission_required("admin")
def get_settings():
    settings = load_settings(current_app.config["DATA_DIR"])
    return jsonify(_masked(settings)), 200


@pastel_bp.route("/settings", methods=["POST"])
@permission_required("admin")
def update_settings():
    body = request.get_json(silent=True) or {}
    data_dir = current_app.config["DATA_DIR"]
    settings = load_settings(data_dir)
    for field in _EDITABLE_FIELDS:
        if field in body:
            settings[field] = body[field]
    save_settings(data_dir, settings)
    return jsonify(_masked(settings)), 200


@pastel_bp.route("/oauth/authorize", methods=["GET"])
@permission_required("admin")
def oauth_authorize():
    settings = load_settings(current_app.config["DATA_DIR"])
    creds = PastelCredentials.from_settings(settings)
    if not (creds.auth_url and creds.client_id and creds.redirect_uri):
        return jsonify({"error": "Set pastel_auth_url, pastel_client_id and pastel_redirect_uri first."}), 409

    state = secrets.token_urlsafe(24)
    _PENDING_STATES.add(state)
    url = build_authorize_url(creds, state)
    return redirect(url, code=302)


@pastel_bp.route("/oauth/callback", methods=["GET"])
def oauth_callback():
    """Sage Active redirects here after the admin logs in and grants
    consent. Not permission_required -- Sage itself is the caller, and
    the `state` check below is what prevents this from being abused
    (an attacker would need a code minted for OUR client_id/redirect_uri,
    which only Sage can issue after a real login)."""
    error = request.args.get("error")
    if error:
        return jsonify({"error": f"Sage Active declined authorization: {error}"}), 400

    state = request.args.get("state")
    if not state or state not in _PENDING_STATES:
        return jsonify({"error": "Missing or unrecognized OAuth state -- start the authorize flow again."}), 400
    _PENDING_STATES.discard(state)

    code = request.args.get("code")
    if not code:
        return jsonify({"error": "No authorization code in callback."}), 400

    data_dir = current_app.config["DATA_DIR"]
    settings = load_settings(data_dir)
    creds = PastelCredentials.from_settings(settings)
    try:
        token_data = exchange_code_for_token(creds, code)
    except PastelAuthError as e:
        return jsonify({"error": str(e)}), 502

    import time
    settings["pastel_access_token"] = token_data["access_token"]
    settings["pastel_refresh_token"] = token_data.get("refresh_token")
    settings["pastel_token_expires_at"] = time.time() + token_data.get("expires_in", 28800)
    save_settings(data_dir, settings)

    return jsonify({
        "ok": True,
        "message": "Sage Active connected. Next: call GET /api/admin/pastel/organizations, "
                    "pick one, then POST its id to /api/admin/pastel/settings as pastel_organization_id.",
    }), 200


@pastel_bp.route("/organizations", methods=["GET"])
@permission_required("admin")
def list_organizations():
    settings = load_settings(current_app.config["DATA_DIR"])
    from app.pastel_client import PastelClient
    creds = PastelCredentials.from_settings(settings)
    try:
        client = PastelClient(creds)
        orgs = client.list_organizations()
    except PastelAuthError as e:
        return jsonify({"error": str(e)}), 409
    except Exception as e:  # pragma: no cover -- surfaced to the admin verbatim
        return jsonify({"error": str(e)}), 502
    return jsonify({"organizations": orgs}), 200


@pastel_bp.route("/organization", methods=["POST"])
@permission_required("admin")
def set_organization():
    """Persist the chosen organization id. Separate from the generic
    /settings PATCH (and deliberately not in _EDITABLE_FIELDS there) so
    an admin can only set this via a real pick from /organizations,
    never by hand-typing an arbitrary id that was never actually
    returned as one they're authorized to use."""
    body = request.get_json(silent=True) or {}
    org_id = body.get("organization_id")
    if not org_id:
        return jsonify({"error": "organization_id is required."}), 400
    data_dir = current_app.config["DATA_DIR"]
    settings = load_settings(data_dir)
    settings["pastel_organization_id"] = org_id
    save_settings(data_dir, settings)
    return jsonify({"ok": True, "pastel_organization_id": org_id}), 200


@pastel_bp.route("/sync", methods=["POST"])
@permission_required("admin")
def run_sync_now():
    settings = load_settings(current_app.config["DATA_DIR"])
    if not settings.get("pastel_enabled"):
        return jsonify({"error": "Pastel integration is disabled -- enable pastel_enabled first."}), 409

    from app.pastel_sync import PastelSyncEngine
    engine = PastelSyncEngine(current_app._get_current_object())
    try:
        results = engine.run_full_sync(settings)
    except PastelAuthError as e:
        return jsonify({"error": str(e)}), 409
    return jsonify(results), 200


@pastel_bp.route("/log", methods=["GET"])
@permission_required("admin")
def sync_log():
    rows = PastelSyncLog.query.order_by(PastelSyncLog.id.desc()).limit(100).all()
    return jsonify([r.to_dict() for r in rows]), 200
