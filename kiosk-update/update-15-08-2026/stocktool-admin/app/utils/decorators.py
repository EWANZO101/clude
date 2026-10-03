from functools import wraps
from flask import jsonify
from flask_jwt_extended import current_user


def admin_required(f):
    """API route decorator — the validated JWT's user must be an active admin.

    Uses flask_jwt_extended's current_user, which is loaded fresh from the
    DB on every request (see user_lookup_loader in app/__init__.py) rather
    than trusting the "role" claim baked into the token at login time —
    otherwise a demoted/disabled admin keeps working admin API access for
    up to the token's full lifetime.
    """
    @wraps(f)
    def decorated(*args, **kwargs):
        if not current_user or current_user.role != "admin":
            return jsonify({"error": "Admin access required"}), 403
        return f(*args, **kwargs)
    return decorated
