"""Signed, stateless viewer tokens for live video playback.

A browser never gets a MediaMTX credential it could reuse elsewhere or that
MediaMTX itself has to look up - api.py's list_live_streams signs one of
these into the WHEP/HLS URL it hands a logged-in, authorized viewer, and
webhooks.py's mediamtx_auth verifies it when MediaMTX's external auth
webhook asks whether to let that viewer read the stream. MediaMTX never
needs to understand an Xon Sight session or hit the database for this -
everything it needs to check is already in the token.
"""

import hashlib
import hmac
import time

from flask import current_app


def sign_viewer_token(path):
    secret = current_app.config["SECRET_KEY"]
    ttl = current_app.config.get("LIVE_VIEWER_TOKEN_SECONDS", 21600)
    expires = int(time.time()) + ttl
    mac = hmac.new(secret.encode(), f"{path}:{expires}".encode(), hashlib.sha256).hexdigest()[:32]
    return f"{expires}.{mac}"


def verify_viewer_token(path, token):
    secret = current_app.config["SECRET_KEY"]
    try:
        expires_s, mac = (token or "").split(".", 1)
        expires = int(expires_s)
    except ValueError:
        return False
    if expires < int(time.time()):
        return False
    expected = hmac.new(secret.encode(), f"{path}:{expires}".encode(), hashlib.sha256).hexdigest()[:32]
    return hmac.compare_digest(mac, expected)
