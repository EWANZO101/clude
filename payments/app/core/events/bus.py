"""In-process event bus. Modules subscribe with @on('event.name').

Core events (fired by the platform):
  transaction.imported, transaction.updated, transaction.categorised,
  merchant.matched, merchant.created, bill.upcoming, budget.exceeded,
  checklist.created, task.completed, module.installed, module.updated,
  module.disabled
"""
import json
import logging

from app.extensions import db
from app.core.events.models import EventLog
from app.core.live import broadcaster

logger = logging.getLogger(__name__)

_subscribers = {}


def on(event_name):
    def decorator(fn):
        _subscribers.setdefault(event_name, []).append(fn)
        return fn
    return decorator


def emit(event_name, **payload):
    try:
        db.session.add(EventLog(event_name=event_name, payload_json=json.dumps(payload, default=str)))
        db.session.commit()
    except Exception:
        db.session.rollback()
        logger.exception("Failed to persist event %s", event_name)

    for handler in _subscribers.get(event_name, []):
        try:
            handler(**payload)
        except Exception:
            logger.exception("Event handler for %s failed", event_name)

    # Fan out to any live (SSE) subscribers. Every event is published under
    # its own name as a topic, plus a per-user topic when a user_id is in
    # the payload -- a page only has to know which topic(s) it cares about,
    # not which event names exist.
    try:
        broadcaster.publish(event_name, event_name, payload)
        if payload.get("user_id"):
            broadcaster.publish(f"user:{payload['user_id']}", event_name, payload)
        if payload.get("vehicle_id"):
            broadcaster.publish(f"fuel_vehicle:{payload['vehicle_id']}", event_name, payload)
    except Exception:
        logger.exception("Live broadcast for %s failed", event_name)
