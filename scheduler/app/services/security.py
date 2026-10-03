"""Minimal login-attempt throttling.

This is a process-local, in-memory limiter — good enough for a single
Gunicorn worker in Phase 1. Before deploying with multiple workers/replicas
(Phase 8), swap this for a shared store (e.g. Flask-Limiter backed by Redis)
so limits are enforced consistently across processes.
"""

import time
from collections import defaultdict

_MAX_ATTEMPTS = 5
_WINDOW_SECONDS = 15 * 60

_attempts = defaultdict(list)


def _prune(key: str) -> list:
    cutoff = time.time() - _WINDOW_SECONDS
    _attempts[key] = [t for t in _attempts[key] if t > cutoff]
    return _attempts[key]


def is_locked_out(key: str) -> bool:
    return len(_prune(key)) >= _MAX_ATTEMPTS


def record_failed_attempt(key: str) -> None:
    _prune(key)
    _attempts[key].append(time.time())


def clear_attempts(key: str) -> None:
    _attempts.pop(key, None)
