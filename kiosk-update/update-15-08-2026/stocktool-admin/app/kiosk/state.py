"""
state.py — server-side state for kiosk terminals and phone pairing.

Why this exists instead of just using Flask's cookie session: a phone
pairing to a kiosk is a genuinely different browser/device with its own
cookies. For a phone-relayed scan to show up on the *terminal's* screen,
both the terminal's own requests and the phone's requests need to mutate
the same object server-side — a signed session cookie held by the
terminal's browser can't be reached or updated by the phone's requests.
So terminal login state (who's badged in, which device name) now lives
here, keyed by a `terminal_id` cookie the terminal carries, instead of in
`session[...]`.

This is in-process memory, not the database — pairing sessions and "who's
currently badged into this terminal" are inherently short-lived and
per-process, not data anyone needs to query or report on later (the
*actions* taken, like a quick-remove, still go through the DB and audit
log exactly as before). This does mean state resets if the app restarts,
and won't be shared across multiple worker processes if you ever scale
this app beyond a single process — acceptable for a single-VPS,
handful-of-kiosks deployment; flag it if that ever needs to change.
"""
import threading
import time
import secrets
import queue

_lock = threading.Lock()

TERMINALS = {}   # terminal_id -> {device, user_id, username, role, queue}
PAIRINGS = {}    # pairing_id -> {terminal_id, status, created_at, expires_at, phone_username}

PAIRING_TTL_SECONDS = 30       # how long one QR code is valid before it must rotate
STALE_AFTER_SECONDS = 60 * 30  # garbage-collect terminals/pairings idle this long


def get_or_create_terminal(terminal_id: str, default_device: str) -> dict:
    with _lock:
        t = TERMINALS.get(terminal_id)
        if not t:
            t = {
                "device": default_device,
                "user_id": None,
                "username": None,
                "role": None,
                "last_seen": time.time(),
                "queue": queue.Queue(),
            }
            TERMINALS[terminal_id] = t
        else:
            t["last_seen"] = time.time()
        return t


def create_pairing(terminal_id: str) -> dict:
    pairing_id = secrets.token_urlsafe(12)
    now = time.time()
    with _lock:
        PAIRINGS[pairing_id] = {
            "pairing_id": pairing_id,
            "terminal_id": terminal_id,
            "status": "pending",       # pending -> paired -> expired
            "created_at": now,
            "expires_at": now + PAIRING_TTL_SECONDS,
            "phone_username": None,
        }
    return PAIRINGS[pairing_id]


def get_pairing(pairing_id: str):
    with _lock:
        p = PAIRINGS.get(pairing_id)
        if p and p["status"] == "pending" and p["expires_at"] < time.time():
            p["status"] = "expired"
        return p


def mark_paired(pairing_id: str, username: str):
    with _lock:
        p = PAIRINGS.get(pairing_id)
        if p:
            p["status"] = "paired"
            p["phone_username"] = username
            # A pairing that's actively being used for relayed scans
            # shouldn't expire out from under it — extend it generously.
            p["expires_at"] = time.time() + STALE_AFTER_SECONDS


def push_event(terminal_id: str, event_type: str, data: dict):
    with _lock:
        t = TERMINALS.get(terminal_id)
    if t:
        t["queue"].put({"event": event_type, "data": data})


def cleanup_expired():
    now = time.time()
    with _lock:
        for pid in [p for p, v in PAIRINGS.items() if v["expires_at"] < now - STALE_AFTER_SECONDS]:
            del PAIRINGS[pid]
        for tid in [t for t, v in TERMINALS.items() if v["last_seen"] < now - STALE_AFTER_SECONDS]:
            del TERMINALS[tid]
