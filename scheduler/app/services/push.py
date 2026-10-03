"""Push notifications to the mobile app, via Expo's (free) push service.

Like the email notifications, a push failure must never break the booking
flow: sends happen on a background thread with a short timeout, and every
error is logged rather than raised. The customer's request doesn't wait on
Expo's servers at all.
"""

import json
import logging
import threading
import urllib.request

from flask import current_app

from app import db
from app.models.push_device import PushDevice

logger = logging.getLogger(__name__)

EXPO_PUSH_URL = "https://exp.host/--/api/v2/push/send"


def _post(messages):
    req = urllib.request.Request(
        EXPO_PUSH_URL,
        data=json.dumps(messages).encode(),
        headers={"Content-Type": "application/json", "Accept": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=10) as res:
        return json.loads(res.read().decode())


def _deliver(app, messages):
    try:
        result = _post(messages)
    except Exception:  # noqa: BLE001 - a push failure must never surface to the booker
        logger.exception("Expo push send failed")
        return

    # Tickets come back in the same order as the messages. A phone that
    # uninstalled the app (or revoked permission) reports DeviceNotRegistered —
    # drop its token so we stop sending to it.
    dead = [
        msg["to"]
        for msg, ticket in zip(messages, result.get("data", []))
        if ticket.get("status") == "error" and (ticket.get("details") or {}).get("error") == "DeviceNotRegistered"
    ]
    if dead:
        with app.app_context():
            PushDevice.query.filter(PushDevice.token.in_(dead)).delete(synchronize_session=False)
            db.session.commit()


def send_push(user, title, body, data=None):
    """Push to every phone the user has registered. Returns immediately."""
    if current_app.config.get("TESTING") and not current_app.config.get("PUSH_SEND_IN_TESTS"):
        return
    tokens = [d.token for d in PushDevice.query.filter_by(user_id=user.id).all()]
    if not tokens:
        return

    messages = [
        {"to": t, "title": title, "body": body, "data": data or {}, "sound": "default", "priority": "high"}
        for t in tokens
    ]
    app = current_app._get_current_object()
    threading.Thread(target=_deliver, args=(app, messages), daemon=True).start()


def _when(booking):
    return f"{booking.start_datetime.strftime('%a %d %b')} at {booking.start_datetime.strftime('%H:%M')}"


def push_new_booking(booking):
    type_name = booking.booking_type.name if booking.booking_type else "Booking"
    extra = " (out of hours)" if booking.is_out_of_hours else ""
    send_push(
        booking.user,
        f"New booking: {booking.name}",
        f"{type_name} · {_when(booking)}{extra}",
        {"booking_id": booking.id, "kind": "new_booking"},
    )


def push_cancelled_booking(booking):
    send_push(
        booking.user,
        f"Cancelled: {booking.name}",
        f"{_when(booking)} was cancelled by the customer.",
        {"booking_id": booking.id, "kind": "cancelled_booking"},
    )
