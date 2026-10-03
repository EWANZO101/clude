"""Generic long-poll helper — the same pattern instances.py's kiosk_status
endpoint pioneered (see that view's own docstring for the full rationale),
pulled out so every other "status-y" endpoint (fleet lists, dashboard
stat tiles, deployment progress, change-request counts) doesn't have to
hand-roll its own copy of the wait/sig/re-query loop.

Usage: build a small callable that returns a *fresh* payload dict each
time it's invoked (a fresh query every call — never something computed
once and reused, since a detached SQLAlchemy object's already-loaded
scalar attributes won't pick up a concurrent change), then:

    @bp.route("/some/status")
    def some_status():
        return long_poll_response(lambda: {"count": Thing.query.count()})

Without ?wait=<seconds>&sig=<last known sig>, this behaves as a plain
single-shot GET — passing them is what turns it into a real long-poll.
"""
import hashlib
import json
import time

from flask import request, jsonify

from app.extensions import db

MAX_WAIT_SECONDS = 25
POLL_INTERVAL_SECONDS = 0.5


def compute_sig(payload: dict) -> str:
    return hashlib.sha1(json.dumps(payload, sort_keys=True, default=str).encode()).hexdigest()


def long_poll_response(build_payload):
    """build_payload() -> dict, called fresh on every pass. Returns a Flask
    JSON response with a "sig" key added, holding the connection open
    (re-checking every ~0.5s) until the signature changes or ?wait expires."""
    wait_seconds = request.args.get("wait", type=float, default=0) or 0
    wait_seconds = max(0.0, min(wait_seconds, MAX_WAIT_SECONDS))
    known_sig = request.args.get("sig", type=str, default=None)
    deadline = time.monotonic() + wait_seconds

    while True:
        payload = build_payload()
        payload["sig"] = compute_sig(payload)
        if payload["sig"] != known_sig or time.monotonic() >= deadline:
            return jsonify(payload)
        db.session.remove()
        time.sleep(POLL_INTERVAL_SECONDS)
