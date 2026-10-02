"""Small shared security helpers: safe post-login redirects + CSRF origin check."""
import os
from urllib.parse import urlsplit

from flask import request, jsonify, abort, current_app


# ---------- Safe "next" redirects ----------
def safe_next(target, default=None):
    """Return `target` only if it's a same-site relative path, else `default`.

    Blocks absolute URLs, scheme-relative "//evil.com", and the backslash
    variant "/\\evil.com" that browsers normalise to "//evil.com".
    """
    if not target or not isinstance(target, str):
        return default
    t = target.strip()
    if any(ord(ch) < 32 for ch in t):
        return default
    norm = t.replace("\\", "/")
    if not norm.startswith("/") or norm.startswith("//"):
        return default
    parts = urlsplit(norm)
    if parts.scheme or parts.netloc:
        return default
    return t


# ---------- CSRF: Origin / Referer check ----------
# Blueprints whose POSTs come from other programs and authenticate with a key
# or signature, never with the login cookie — so a forged browser request
# gains nothing and the check would only get in the way.
CSRF_EXEMPT_BLUEPRINTS = {
    "api",       # /api/v1  — Bearer / X-API-Key
    "bridge",    # /bridge  — X-Bridge-Key from the Discord bot
    "lic_api",   # /licenses/api — license key in body, called by game servers
}
CSRF_EXEMPT_ENDPOINTS = {
    "billing.webhook",   # Stripe, signature-verified
}
_UNSAFE_METHODS = {"POST", "PUT", "PATCH", "DELETE"}


def _host_of(url):
    try:
        return (urlsplit(url).netloc or "").lower()
    except ValueError:
        return ""


def _trusted_hosts():
    hosts = {request.host.lower()}
    extra = os.environ.get("CSRF_TRUSTED_ORIGINS", "")
    for item in extra.split(","):
        item = item.strip()
        if item:
            hosts.add(_host_of(item) if "://" in item else item.lower())
    return hosts


def _csrf_check():
    if request.method not in _UNSAFE_METHODS:
        return
    if request.blueprint in CSRF_EXEMPT_BLUEPRINTS or request.endpoint in CSRF_EXEMPT_ENDPOINTS:
        return

    origin = request.headers.get("Origin")
    referer = request.headers.get("Referer")
    if origin:
        source = _host_of(origin) if origin != "null" else ""
    elif referer:
        source = _host_of(referer)
    else:
        # Browsers always send Origin on cross-site POSTs, so a request with
        # neither header isn't a forged browser request (curl, scripts, etc.).
        return

    if source and source in _trusted_hosts():
        return

    current_app.logger.warning(
        f"CSRF origin check blocked {request.method} {request.path} "
        f"from origin={origin!r} referer={referer!r}")
    if request.is_json or request.accept_mimetypes.best == "application/json":
        return jsonify({"ok": False, "error": "Cross-site request blocked."}), 403
    abort(403)


def init_csrf(app):
    app.before_request(_csrf_check)
