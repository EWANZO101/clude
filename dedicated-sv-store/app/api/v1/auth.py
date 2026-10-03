import time
from functools import wraps

from flask import request, g

from app.extensions import db
from app.models.api import ApiKey, ApiLog, hash_key
from app.models.base import utcnow
from app.api.v1.helpers import api_error


def require_api_key(scope=None):
    def decorator(fn):
        @wraps(fn)
        def wrapper(*args, **kwargs):
            start = time.monotonic()
            raw_key = request.headers.get("X-API-Key") or request.headers.get(
                "Authorization", ""
            ).removeprefix("Bearer ").strip()

            if not raw_key:
                return api_error("UNAUTHORIZED", "An API key is required.", 401)

            api_key = ApiKey.query.filter_by(key_hash=hash_key(raw_key)).first()
            if not api_key or not api_key.is_valid():
                return api_error("UNAUTHORIZED", "Invalid or revoked API key.", 401)

            if scope and not api_key.has_scope(scope):
                return api_error("FORBIDDEN", f"API key is missing scope '{scope}'.", 403)

            api_key.last_used_at = utcnow()
            g.api_key = api_key
            g.api_user = api_key.user

            response = fn(*args, **kwargs)

            duration_ms = int((time.monotonic() - start) * 1000)
            status_code = response[1] if isinstance(response, tuple) else 200
            db.session.add(
                ApiLog(
                    api_key_id=api_key.id,
                    method=request.method,
                    path=request.path,
                    status_code=status_code,
                    ip_address=request.remote_addr,
                    duration_ms=duration_ms,
                )
            )
            db.session.commit()
            return response

        return wrapper

    return decorator
