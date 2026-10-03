"""Tiny TTL memoizer for functions that shell out (systemctl/ufw/nginx -v etc).

Every page navigation in this panel re-renders server-side, and several
routes call subprocess-backed service functions just to answer "is X
installed?" or "what's the status?" on every single load. Those spawns
(fork+exec, plus whatever the target binary itself does) add real,
noticeable latency to *every* page change, on top of anything else slow
on the page. Most of that data doesn't change between one click and the
next, so a short cache removes the repeat cost without meaningfully
changing correctness.

Use ttl_cache(seconds) for read-only "does this change rarely" calls
(e.g. is nginx/ufw installed). Don't use it for anything the user just
mutated and expects to see reflected immediately (e.g. right after
starting/stopping a service) — call .invalidate() on those instead, or
just don't cache them at all.
"""
import time
from functools import wraps


def ttl_cache(seconds):
    def decorator(func):
        cache = {}

        @wraps(func)
        def wrapper(*args, **kwargs):
            key = (args, tuple(sorted(kwargs.items())))
            now = time.monotonic()
            hit = cache.get(key)
            if hit is not None and now - hit[0] < seconds:
                return hit[1]
            value = func(*args, **kwargs)
            cache[key] = (now, value)
            return value

        def invalidate():
            cache.clear()

        wrapper.invalidate = invalidate
        return wrapper

    return decorator
