"""In-process live-update broadcaster for Server-Sent Events.

Topic -> set of subscriber queues, entirely in memory. This only works
correctly with a single OS process (gunicorn run with one worker + threads,
not multiple sync workers) -- see payment.service. At this app's scale
(one user, a handful of browser tabs) that's the simple, dependency-free
choice; a multi-worker deployment would need a real broker (Redis pub/sub)
instead, which isn't part of this stack.

Wired into app.core.events.bus.emit() so every existing/future event fans
out live for free -- individual routes don't need to know this exists.
"""
import queue
import threading

_lock = threading.Lock()
_subscribers = {}  # topic -> set[Queue]


def subscribe(topic):
    q = queue.Queue(maxsize=50)
    with _lock:
        _subscribers.setdefault(topic, set()).add(q)
    return q


def unsubscribe(topic, q):
    with _lock:
        subs = _subscribers.get(topic)
        if subs:
            subs.discard(q)
            if not subs:
                _subscribers.pop(topic, None)


def publish(topic, event, data=None):
    with _lock:
        subs = list(_subscribers.get(topic, ()))
    for q in subs:
        try:
            q.put_nowait({"event": event, "data": data or {}})
        except queue.Full:
            pass  # a slow/stuck client shouldn't back up the publisher
