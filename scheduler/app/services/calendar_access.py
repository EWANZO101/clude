"""Access control for shared calendars: two deliberately different cookies.

- "device" cookie: long-lived (1 year), remembers which CalendarAccess this
  browser belongs to for a given calendar, so a returning visitor skips
  re-typing their email and goes straight to a PIN prompt.
- "unlock" cookie: a *session* cookie (no expiry set at all, so the browser
  drops it on close) proving the PIN was entered correctly. This is what
  actually gates access to the calendar. Deliberately NOT reusing Flask's
  built-in `session` object, because the admin login elsewhere in this app
  sometimes marks that session permanent ("remember me"), which would leak
  into the calendar-maker and defeat "PIN required whenever they return."

Both cookies are signed with itsdangerous so a visitor can't hand-craft one
claiming to be a different access_id without knowing the app's SECRET_KEY.
"""

import time
from collections import defaultdict

from flask import current_app
from itsdangerous import BadSignature, URLSafeSerializer, URLSafeTimedSerializer

DEVICE_COOKIE_MAX_AGE = 60 * 60 * 24 * 400  # ~13 months


def _device_cookie_name(share_token):
    return f"cm_device_{share_token}"


def _unlock_cookie_name(share_token):
    return f"cm_unlock_{share_token}"


def _device_serializer():
    return URLSafeTimedSerializer(current_app.secret_key, salt="calendarmaker-device")


def _unlock_serializer():
    return URLSafeSerializer(current_app.secret_key, salt="calendarmaker-unlock")


def get_device_access_id(request, share_token):
    """The access_id this browser was last recognized as for this calendar, if any."""
    raw = request.cookies.get(_device_cookie_name(share_token))
    if not raw:
        return None
    try:
        data = _device_serializer().loads(raw, max_age=DEVICE_COOKIE_MAX_AGE)
        return int(data["access_id"])
    except (BadSignature, KeyError, ValueError, TypeError):
        return None


def set_device_cookie(response, share_token, access_id):
    token = _device_serializer().dumps({"access_id": access_id})
    response.set_cookie(
        _device_cookie_name(share_token),
        token,
        max_age=DEVICE_COOKIE_MAX_AGE,
        httponly=True,
        samesite="Lax",
        secure=current_app.config.get("SESSION_COOKIE_SECURE", False),
    )


def get_unlocked_access_id(request, share_token):
    """The access_id proven-via-PIN for this browser SESSION (cleared on browser close)."""
    raw = request.cookies.get(_unlock_cookie_name(share_token))
    if not raw:
        return None
    try:
        data = _unlock_serializer().loads(raw)
        return int(data["access_id"])
    except (BadSignature, KeyError, ValueError, TypeError):
        return None


def set_unlock_cookie(response, share_token, access_id):
    token = _unlock_serializer().dumps({"access_id": access_id})
    # No max_age/expires at all -> a real session cookie, dropped when the
    # browser fully closes. This is the mechanism that enforces "PIN
    # required whenever they return."
    response.set_cookie(
        _unlock_cookie_name(share_token),
        token,
        httponly=True,
        samesite="Lax",
        secure=current_app.config.get("SESSION_COOKIE_SECURE", False),
    )


def clear_unlock_cookie(response, share_token):
    response.delete_cookie(_unlock_cookie_name(share_token))


# --- PIN attempt rate limiting -------------------------------------------
# A 4-6 digit PIN has very little entropy, so this matters more than the
# login rate limiter it's modeled on. Same process-local caveat applies:
# fine for one worker, swap for a shared store before running several.

_MAX_ATTEMPTS = 5
_WINDOW_SECONDS = 15 * 60
_pin_attempts = defaultdict(list)


def _prune(key):
    cutoff = time.time() - _WINDOW_SECONDS
    _pin_attempts[key] = [t for t in _pin_attempts[key] if t > cutoff]
    return _pin_attempts[key]


def pin_is_locked_out(access_id):
    return len(_prune(f"access:{access_id}")) >= _MAX_ATTEMPTS


def record_failed_pin_attempt(access_id):
    _prune(f"access:{access_id}")
    _pin_attempts[f"access:{access_id}"].append(time.time())


def clear_pin_attempts(access_id):
    _pin_attempts.pop(f"access:{access_id}", None)
