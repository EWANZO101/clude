"""In-process pub/sub for the SSE stream at /api/stream.

Server-Sent Events rather than WebSockets: this app runs as a single
synchronous Flask process (app.py's dev server, threaded=True - see the
comment there), not behind eventlet/gevent. SSE is a plain long-lived HTTP
response, so it works unmodified on that stack; real WebSockets would need
a protocol upgrade most WSGI servers here can't do without monkey-patching
the whole app's blocking pymysql/requests calls, which is a much bigger
and riskier change than this feature needs.

Subscribers live in memory only - a single `queue.Queue` per open browser
tab - so this only fans out within one process. Fine today (app.py is one
process); revisit if this ever runs under multiple worker processes.

Scope: control-plane events only, same boundary as api.py's analytics
endpoints - webhook writes that resolved a tenant community (g.community
is not None) don't publish here, since there's no tenant-aware browser UI
to receive them yet.
"""

import json
import queue
import threading

_subscribers = set()
_lock = threading.Lock()


def subscribe():
    q = queue.Queue(maxsize=100)
    with _lock:
        _subscribers.add(q)
    return q


def unsubscribe(q):
    with _lock:
        _subscribers.discard(q)


def publish(event_type, **data):
    payload = json.dumps({"type": event_type, **data}, default=str)
    with _lock:
        subs = list(_subscribers)
    for q in subs:
        try:
            q.put_nowait(payload)
        except queue.Full:
            pass
