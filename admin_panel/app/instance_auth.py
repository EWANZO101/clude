from functools import wraps

from flask import request, jsonify, g

from app.models import Instance


def _parse_bearer():
    """Expects: Authorization: Bearer <instance_public_id>.<instance_secret>
    Kept as a single opaque-looking bearer token (rather than two headers) so
    it behaves like a normal API key for any HTTP client/library the agent
    might use."""
    auth = request.headers.get("Authorization", "")
    if not auth.startswith("Bearer "):
        return None, None
    token = auth[len("Bearer "):].strip()
    if "." not in token:
        return None, None
    instance_id, _, secret = token.partition(".")
    return instance_id, secret


def instance_auth_required(view):
    """Authenticates the calling Instance Agent. On success, sets g.instance.
    Never reveals whether an instance_id exists vs. the secret being wrong —
    both return the same 401."""
    @wraps(view)
    def wrapper(*args, **kwargs):
        instance_id, secret = _parse_bearer()
        if not instance_id or not secret:
            return jsonify({"error": "missing or malformed Authorization header"}), 401

        instance = Instance.query.filter_by(public_id=instance_id).first()
        if instance is None or not instance.check_secret(secret):
            return jsonify({"error": "invalid instance credentials"}), 401

        if not instance.is_licensed():
            # Deliberately after credential validation, not before — a
            # suspended instance's Agent should be told it's suspended
            # specifically (see agent/heartbeat.py's run_heartbeat_loop,
            # which stops the locally supervised kiosk process on seeing
            # this exact error code), not folded into the generic "invalid
            # credentials" 401 a wrong secret gets.
            reason = instance.license_display_status()  # "suspended" | "expired"
            return jsonify({"error": f"license_{reason}"}), 403

        g.instance = instance
        return view(*args, **kwargs)
    return wrapper
