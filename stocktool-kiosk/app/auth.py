"""
Local session handling for the kiosk. This is a single-machine embedded
API (nothing here is exposed to the internet — the cloud sync client is
the only thing that talks outbound), so a simple in-memory opaque-token
session store is appropriate; no need for JWT/refresh-token machinery
for a purely local API surface.
"""
import secrets
import time
from functools import wraps
from flask import request, jsonify, g

_SESSIONS: dict[str, dict] = {}
_SESSION_TTL_SECONDS = 60 * 60 * 12  # 12h — a work shift


def create_session(local_user) -> str:
    token = secrets.token_urlsafe(24)
    _SESSIONS[token] = {
        "user_id": local_user.id,
        "username": local_user.username,
        "role": local_user.role,
        "expires_at": time.time() + _SESSION_TTL_SECONDS,
    }
    return token


def _get_session(token: str):
    session = _SESSIONS.get(token)
    if not session:
        return None
    if session["expires_at"] < time.time():
        _SESSIONS.pop(token, None)
        return None
    return session


def login_required(fn):
    @wraps(fn)
    def wrapper(*args, **kwargs):
        auth_header = request.headers.get("Authorization", "")
        token = auth_header[7:] if auth_header.startswith("Bearer ") else None
        session = _get_session(token) if token else None
        if not session:
            return jsonify({"error": "Not logged in."}), 401
        g.session = session
        return fn(*args, **kwargs)
    return wrapper


def permission_required(*roles):
    """Gate an action behind specific synced-from-cloud roles. This is a
    permission check on data the cloud already manages — it is NOT a user
    management UI, so it doesn't count as the kiosk having 'administrative
    functionality' of its own."""
    def decorator(fn):
        @wraps(fn)
        @login_required
        def wrapper(*args, **kwargs):
            if g.session["role"] not in roles:
                return jsonify({"error": "You don't have permission to do that."}), 403
            return fn(*args, **kwargs)
        return wrapper
    return decorator
