from functools import wraps
from flask import request, jsonify, g
from app.models import Installation


def install_token_required(fn):
    """
    Gates sync/config endpoints behind a per-installation token (issued
    once at registration — see app/api/installations.py) rather than the
    per-user JWT used elsewhere. A desktop kiosk install represents a
    trusted DEVICE relaying many local users' actions, not one user's
    session, so it needs its own credential type.
    """
    @wraps(fn)
    def wrapper(*args, **kwargs):
        auth_header = request.headers.get("Authorization", "")
        token = auth_header[7:] if auth_header.startswith("Bearer ") else None
        installation = Installation.find_by_token(token) if token else None
        if not installation:
            return jsonify({"error": "Invalid or missing installation token."}), 401
        g.installation = installation
        return fn(*args, **kwargs)
    return wrapper
