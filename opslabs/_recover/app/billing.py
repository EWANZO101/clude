"""
═══════════════════════════════════════════════════════════════════════════
  billing.py — Stripe integration (safe when unconfigured)
═══════════════════════════════════════════════════════════════════════════
  Set these env vars to go live:
      STRIPE_SECRET_KEY        sk_live_… / sk_test_…
      STRIPE_PUBLISHABLE_KEY   pk_…           (used in templates)
      STRIPE_WEBHOOK_SECRET    whsec_…        (verifies webhook signatures)

  Without STRIPE_SECRET_KEY everything no-ops with a clear message, so the
  rest of the portal still runs. Webhook endpoint is /billing/webhook.
═══════════════════════════════════════════════════════════════════════════
"""
import os
from datetime import datetime
from flask import Blueprint, request, current_app, url_for

from . import db
from .models_business import Invoice, Payment, Service, Notification, AuditLog, QuickJob

billing_bp = Blueprint("billing", __name__)

try:
    import stripe  # noqa
except Exception:  # library not installed yet
    stripe = None


def _secret():
    return os.environ.get("STRIPE_SECRET_KEY", "").strip()


def is_configured() -> bool:
    return bool(stripe and _secret())


def publishable_key() -> str:
    return os.environ.get("STRIPE_PUBLISHABLE_KEY", "").strip()


def create_checkout_session(invoice: Invoice, success_url: str, cancel_url: str):
    """Return (session, error). On success `session.url` is the redirect."""
    if not is_configured():
        return None, "Stripe is not configured yet — add STRIPE_SECRET_KEY."
    stripe.api_key = _secret()
    try:
        session = stripe.checkout.Session.create(
            mode="payment",
            success_url=success_url,
            cancel_url=cancel_url,
            client_reference_id=str(invoice.id),
            customer_email=invoice.owner.email,
            line_items=[{
                "quantity": li.quantity,
                "price_data": {
                    "currency": invoice.currency.lower(),
                    "unit_amount": li.unit_cents,
                    "product_data": {"name": li.description[:120] or "Item"},
                },
            } for li in invoice.line_items],
            metadata={"invoice_id": invoice.id, "invoice_number": invoice.number},
        )
        invoice.stripe_session_id = session.id
        db.session.commit()
        return session, None
    except Exception as e:  # surface Stripe errors without crashing
        return None, str(e)


def _mark_invoice_paid(invoice: Invoice, payment_intent=None):
    invoice.status = "paid"
    invoice.paid_at = datetime.utcnow()
    if payment_intent:
        invoice.stripe_payment_intent = payment_intent
    db.session.add(Payment(
        invoice_id=invoice.id, owner_id=invoice.owner_id,
        amount_cents=invoice.total_cents, currency=invoice.currency,
        method="stripe", status="succeeded", stripe_payment_intent=payment_intent,
    ))
    Notification.push(invoice.owner_id, "Payment received",
                      f"Invoice {invoice.number} is now paid.",
                      url=f"/portal/invoices/{invoice.id}", category="billing")
    AuditLog.log("invoice.paid", target_type="invoice", target_id=invoice.id,
                 meta={"number": invoice.number})


def create_checkout_for_quickjob(job: QuickJob, success_url: str, cancel_url: str):
    """Stripe Checkout session to pay a Quick Job. Returns (session, error)."""
    if not is_configured():
        return None, "Stripe is not configured yet — add STRIPE_SECRET_KEY."
    if not job.is_payable_online:
        return None, "This job isn't payable."
    stripe.api_key = _secret()
    cur = (job.currency or "GBP").lower()
    if job.has_items:
        line_items = [{
            "quantity": (it.quantity or 1),
            "price_data": {
                "currency": cur,
                "unit_amount": it.unit_cents,
                "product_data": {"name": (it.label or "Item")[:120]},
            },
        } for it in job.items if it.unit_cents and it.quantity]
    else:
        line_items = [{
            "quantity": 1,
            "price_data": {
                "currency": cur,
                "unit_amount": job.total_cents,
                "product_data": {"name": (job.title or "Job")[:120]},
            },
        }]
    try:
        session = stripe.checkout.Session.create(
            mode="payment",
            success_url=success_url,
            cancel_url=cancel_url,
            client_reference_id=f"job:{job.id}",
            customer_email=(job.client_email or None),
            line_items=line_items,
            metadata={"quickjob_id": job.id, "quickjob_token": job.token},
        )
        job.stripe_session_id = session.id
        db.session.commit()
        return session, None
    except Exception as e:
        return None, str(e)


def _mark_quickjob_paid(job: QuickJob, payment_intent=None):
    job.is_paid = True
    job.paid_at = datetime.utcnow()
    job.paid_via = "stripe"
    if payment_intent:
        job.stripe_payment_intent = payment_intent
    if job.created_by_id:
        Notification.push(job.created_by_id, "Job payment received",
                          f"“{job.title}” has been paid ({job.price_display}).",
                          url=f"/admin/jobs/{job.id}", category="job")
    AuditLog.log("quickjob.paid", target_type="quick_job", target_id=job.id,
                 meta={"amount_cents": job.total_cents})


@billing_bp.route("/webhook", methods=["POST"])
def webhook():
    """Stripe → us. Verifies signature when STRIPE_WEBHOOK_SECRET is set."""
    if not (stripe and _secret()):
        return ("stripe not configured", 503)

    payload = request.get_data()
    sig = request.headers.get("Stripe-Signature", "")
    wh_secret = os.environ.get("STRIPE_WEBHOOK_SECRET", "").strip()
    stripe.api_key = _secret()

    try:
        if wh_secret:
            event = stripe.Webhook.construct_event(payload, sig, wh_secret)
        else:  # dev: trust the body (set the secret in production!)
            import json
            event = json.loads(payload)
    except Exception as e:
        current_app.logger.warning("Stripe webhook verify failed: %s", e)
        return ("bad signature", 400)

    etype = event.get("type")
    obj = event.get("data", {}).get("object", {})

    if etype == "checkout.session.completed":
        meta = obj.get("metadata") or {}
        ref = obj.get("client_reference_id") or ""
        # Quick Job payment?
        qj_id = meta.get("quickjob_id") or (ref[4:] if ref.startswith("job:") else None)
        if qj_id:
            job = QuickJob.query.get(int(qj_id))
            if job and not job.is_paid:
                _mark_quickjob_paid(job, obj.get("payment_intent"))
        else:
            inv_id = meta.get("invoice_id") or ref
            if inv_id:
                inv = Invoice.query.get(int(inv_id))
                if inv and inv.status != "paid":
                    _mark_invoice_paid(inv, obj.get("payment_intent"))

    elif etype in ("invoice.paid", "invoice.payment_succeeded"):
        sub = obj.get("subscription")
        if sub:
            svc = Service.query.filter_by(stripe_subscription_id=sub).first()
            if svc:
                svc.status = "active"

    elif etype == "customer.subscription.deleted":
        sub = obj.get("id")
        svc = Service.query.filter_by(stripe_subscription_id=sub).first()
        if svc:
            svc.status = "expired"

    db.session.commit()
    return ("", 200)
