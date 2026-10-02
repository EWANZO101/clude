"""Access control for links protected by one shared PIN (not a per-person
login) — e.g. a time-off share link, or calendarmaker's optional public
PIN. Generalized out of app/services/calendar_access.py, which handles the
per-person (email + PIN) case for calendarmaker's invite links.

Unlock proof lives in a session cookie (no expiry set, so the browser
drops it on close) — re-entering the PIN whenever the browser fully closes
is deliberate here, the same reasoning as calendar_access.py.
"""

import time
from collections import defaultdict

from flask import current_app
from itsdangerous import BadSignature, URLSafeSerializer


def _cookie_name(namespace, token):
    return f"pin_unlock_{namespace}_{token}"


def _serializer():
    return URLSafeSerializer(current_app.secret_key, salt="pin-unlock")


def is_unlocked(request, namespace, token):
    raw = request.cookies.get(_cookie_name(namespace, token))
    if not raw:
        return False
    try:
        data = _serializer().loads(raw)
        return data.get("token") == token
    except (BadSignature, KeyError, TypeError):
        return False


def set_unlocked(response, namespace, token):
    value = _serializer().dumps({"token": token})
    response.set_cookie(
        _cookie_name(namespace, token),
        value,
        httponly=True,
        samesite="Lax",
        secure=current_app.config.get("SESSION_COOKIE_SECURE", False),
    )


def clear_unlocked(response, namespace, token):
    response.delete_cookie(_cookie_name(namespace, token))


# --- PIN attempt rate limiting -------------------------------------------
# Same process-local caveat as calendar_access.py: fine for one worker,
# swap for a shared store before running several.

_MAX_ATTEMPTS = 5
_WINDOW_SECONDS = 15 * 60
_attempts = defaultdict(list)


def _key(namespace, token):
    return f"{namespace}:{token}"


def _prune(key):
    cutoff = time.time() - _WINDOW_SECONDS
    _attempts[key] = [t for t in _attempts[key] if t > cutoff]
    return _attempts[key]


def is_locked_out(namespace, token):
    return len(_prune(_key(namespace, token))) >= _MAX_ATTEMPTS


def record_failed_attempt(namespace, token):
    _prune(_key(namespace, token))
    _attempts[_key(namespace, token)].append(time.time())


def clear_attempts(namespace, token):
    _attempts.pop(_key(namespace, token), None)
