import hashlib
import hmac
import secrets

from flask import request, g

from app.extensions import db
from app.api.v1 import api_v1_bp
from app.api.v1.helpers import api_success, api_error, pagination_meta
from app.api.v1.auth import require_api_key
from app.models.api import Webhook, WebhookDelivery

WEBHOOK_EVENTS = [
    "order.created", "order.paid", "order.cancelled",
    "server.created", "server.updated", "inventory.updated",
    "invoice.paid", "shipment.created", "shipment.delivered", "request.updated",
]


def sign_payload(secret, body_bytes):
    return hmac.new(secret.encode("utf-8"), body_bytes, hashlib.sha256).hexdigest()


def dispatch_webhook(event, payload):
    """Queues delivery to every active webhook subscribed to this event.
    Call sites don't need an app/request context beyond the current one —
    actual HTTP delivery happens in the RQ worker via deliver_webhook_delivery."""
    webhooks = Webhook.query.filter_by(is_active=True).all()
    for webhook in webhooks:
        if not webhook.subscribes_to(event):
            continue
        delivery = WebhookDelivery(webhook_id=webhook.id, event=event, payload=payload, success=False, attempt=1)
        db.session.add(delivery)
        db.session.flush()

        from app.tasks.queue import enqueue

        enqueue(deliver_webhook_delivery, delivery.id, queue_name="webhooks")


def deliver_webhook_delivery(delivery_id):
    """Runs in an RQ worker process; builds its own app context."""
    import json
    import requests

    from app import create_app

    app = create_app()
    with app.app_context():
        delivery = db.session.get(WebhookDelivery, delivery_id)
        if delivery is None:
            return
        webhook = delivery.webhook

        body = json.dumps({"event": delivery.event, "data": delivery.payload}).encode("utf-8")
        signature = sign_payload(webhook.secret, body)

        try:
            resp = requests.post(
                webhook.url, data=body, timeout=10,
                headers={"Content-Type": "application/json", "X-Webhook-Signature": signature},
            )
            delivery.status_code = resp.status_code
            delivery.success = 200 <= resp.status_code < 300
        except Exception as exc:  # noqa: BLE001
            delivery.error = str(exc)
            delivery.success = False

        from app.models.base import utcnow

        delivery.delivered_at = utcnow()
        db.session.commit()


@api_v1_bp.route("/webhooks", methods=["GET", "POST"])
@require_api_key(scope="webhooks:manage")
def webhooks_list_create():
    if request.method == "POST":
        payload = request.get_json(silent=True) or {}
        url = payload.get("url")
        events = payload.get("events", [])
        if not url:
            return api_error("VALIDATION_ERROR", "url is required.", 400)

        webhook = Webhook(
            owner_user_id=g.api_user.id, url=url, secret=secrets.token_hex(32), events=events,
        )
        if g.api_key.seller_id:
            webhook.seller_id = g.api_key.seller_id
        db.session.add(webhook)
        db.session.commit()
        return api_success(
            {"id": webhook.id, "url": webhook.url, "secret": webhook.secret, "events": webhook.events}, status=201
        )

    page = request.args.get("page", 1, type=int)
    per_page = min(request.args.get("per_page", 25, type=int), 100)
    query = Webhook.query.filter_by(owner_user_id=g.api_user.id).order_by(Webhook.created_at.desc())
    pagination = query.paginate(page=page, per_page=per_page, error_out=False)
    return api_success(
        [
            {"id": w.id, "url": w.url, "events": w.events, "is_active": w.is_active}
            for w in pagination.items
        ],
        meta=pagination_meta(pagination),
    )


@api_v1_bp.route("/webhooks/<int:webhook_id>", methods=["DELETE"])
@require_api_key(scope="webhooks:manage")
def webhooks_delete(webhook_id):
    webhook = Webhook.query.filter_by(id=webhook_id, owner_user_id=g.api_user.id).first()
    if webhook is None:
        return api_error("NOT_FOUND", "Webhook not found.", 404)
    db.session.delete(webhook)
    db.session.commit()
    return api_success({"deleted": True})
