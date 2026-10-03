from datetime import datetime, timedelta

import stripe
from flask import Blueprint, current_app, redirect, url_for, flash, request, abort
from flask_login import login_required, current_user
from sqlalchemy.exc import IntegrityError

from ..extensions import db
from ..models import Plan, Subscription, PlanEntitlement, Payment, WebhookEvent
from . import credits as credits_lib

billing_bp = Blueprint('billing', __name__)


def stripe_configured():
    return bool(current_app.config['STRIPE_SECRET_KEY'])


def _stripe():
    stripe.api_key = current_app.config['STRIPE_SECRET_KEY']
    return stripe


def _get_or_create_stripe_customer(company):
    if company.stripe_customer_id:
        return company.stripe_customer_id
    customer = _stripe().Customer.create(
        name=company.name,
        email=current_user.email,
        metadata={'company_id': str(company.id)},
    )
    company.stripe_customer_id = customer.id
    db.session.commit()
    return customer.id


@billing_bp.route('/billing/checkout/<int:plan_id>', methods=['POST'])
@login_required
def checkout(plan_id):
    if not current_user.has_company_role('owner', 'admin'):
        flash('Only company owners/admins can change the subscription.', 'error')
        return redirect(url_for('auth.dashboard'))

    if not stripe_configured():
        flash('Billing isn\'t configured yet — ask the platform admin to add Stripe keys.', 'error')
        return redirect(url_for('auth.dashboard'))

    plan = db.session.get(Plan, plan_id) or abort(404)
    if not plan.is_active:
        flash('This plan is no longer available.', 'error')
        return redirect(url_for('auth.dashboard'))

    company = current_user.company
    customer_id = _get_or_create_stripe_customer(company)

    if plan.billing_period in ('monthly', 'yearly'):
        mode = 'subscription'
        line_items = [{'price': plan.stripe_price_id, 'quantity': 1}]
        subscription_data = {}
        if plan.trial_days:
            subscription_data['trial_period_days'] = plan.trial_days
        kwargs = {'subscription_data': subscription_data} if subscription_data else {}
    else:  # one_off | lifetime
        mode = 'payment'
        line_items = [{'price': plan.stripe_price_id, 'quantity': 1}]
        kwargs = {}

    if not plan.stripe_price_id:
        flash(f'Plan "{plan.name}" has no Stripe price attached yet — '
              'set stripe_price_id in the admin plan editor first.', 'error')
        return redirect(url_for('auth.dashboard'))

    session = _stripe().checkout.Session.create(
        customer=customer_id,
        mode=mode,
        line_items=line_items,
        success_url=url_for('billing.checkout_success', _external=True) + '?session_id={CHECKOUT_SESSION_ID}',
        cancel_url=url_for('auth.dashboard', _external=True),
        client_reference_id=str(company.id),
        metadata={'company_id': str(company.id), 'plan_id': str(plan.id)},
        **kwargs,
    )
    return redirect(session.url, code=303)


@billing_bp.route('/billing/success')
@login_required
def checkout_success():
    # The webhook is the source of truth for actually granting access — this page is
    # just UX so the customer isn't left staring at Stripe's domain after paying.
    flash('Payment received — your plan will update within a few seconds.', 'success')
    return redirect(url_for('auth.dashboard'))


@billing_bp.route('/billing/portal', methods=['POST'])
@login_required
def portal():
    if not current_user.has_company_role('owner', 'admin'):
        flash('Only company owners/admins can manage billing.', 'error')
        return redirect(url_for('auth.dashboard'))

    if not stripe_configured():
        flash('Billing isn\'t configured yet.', 'error')
        return redirect(url_for('auth.dashboard'))

    company = current_user.company
    if not company.stripe_customer_id:
        flash('No billing account yet — subscribe to a plan first.', 'error')
        return redirect(url_for('auth.dashboard'))

    session = _stripe().billing_portal.Session.create(
        customer=company.stripe_customer_id,
        return_url=url_for('auth.dashboard', _external=True),
    )
    return redirect(session.url, code=303)


# ─── WEBHOOK ─────────────────────────────────────────────────────────────────

def _end_current_subscription(company_id, *, status='canceled'):
    current = (Subscription.query.filter_by(company_id=company_id)
               .filter(Subscription.status.in_(('trialing', 'active', 'past_due')))
               .order_by(Subscription.started_at.desc()).first())
    if current:
        current.status = status
        current.canceled_at = datetime.utcnow()
        current.ended_at = datetime.utcnow()
    return current


def _handle_checkout_completed(event):
    session = event['data']['object']
    company_id = int(session['metadata']['company_id'])
    plan_id = int(session['metadata']['plan_id'])
    plan = db.session.get(Plan, plan_id)
    if not plan:
        return

    if session.get('mode') == 'subscription':
        stripe_sub_id = session.get('subscription')
        sub = Subscription.query.filter_by(stripe_subscription_id=stripe_sub_id).first()
        if not sub:
            _end_current_subscription(company_id)
            sub = Subscription(
                company_id=company_id, plan_id=plan_id, status='active',
                stripe_subscription_id=stripe_sub_id,
                stripe_customer_id=session.get('customer'),
            )
            db.session.add(sub)
    else:
        # one_off / lifetime purchase — a durable entitlement, not a renewing subscription
        exists = PlanEntitlement.query.filter_by(company_id=company_id, plan_id=plan_id).first()
        if not exists:
            db.session.add(PlanEntitlement(company_id=company_id, plan_id=plan_id,
                                            source='stripe_checkout'))

    if session.get('payment_intent') or session.get('amount_total'):
        db.session.add(Payment(
            company_id=company_id,
            stripe_payment_intent_id=session.get('payment_intent'),
            amount_cents=session.get('amount_total') or 0,
            currency=(session.get('currency') or 'usd'),
            status='paid',
        ))

    # Subscriptions get their credits from _handle_invoice_paid instead (Stripe fires
    # invoice.paid for the first period too, right after checkout — handling it in one
    # place instead of two avoids double-crediting the first period).
    if session.get('mode') != 'subscription' and plan.credit_allowance:
        credits_lib.grant(
            company_id, plan.credit_allowance, f'purchased plan: {plan.name}',
            source_type='purchase', source_event_id=session['id'],
        )


def _handle_invoice_paid(event):
    invoice = event['data']['object']
    stripe_sub_id = invoice.get('subscription')
    if not stripe_sub_id:
        return  # one-off invoice, not tied to a recurring subscription
    sub = Subscription.query.filter_by(stripe_subscription_id=stripe_sub_id).first()
    if not sub:
        return  # checkout.session.completed hasn't landed yet — safe to skip, it'll create it

    sub.status = 'active'
    period_end = invoice.get('lines', {}).get('data', [{}])[0].get('period', {}).get('end')
    if period_end:
        sub.current_period_end = datetime.utcfromtimestamp(period_end)

    stripe_invoice_id = invoice.get('id')
    already = Payment.query.filter_by(stripe_invoice_id=stripe_invoice_id).first()
    if not already:
        db.session.add(Payment(
            company_id=sub.company_id,
            stripe_invoice_id=stripe_invoice_id,
            amount_cents=invoice.get('amount_paid') or 0,
            currency=(invoice.get('currency') or 'usd'),
            status='paid',
        ))
        # Reset (not add) — non-rollover credits, this period's balance becomes exactly
        # the plan's allowance. Covers both the subscription's first period and every
        # renewal after it, since Stripe fires invoice.paid for both. Idempotent per
        # invoice via CreditLedger's unique constraint (see credits.reset_to).
        if sub.plan.credit_allowance:
            credits_lib.reset_to(
                sub.company_id, sub.plan.credit_allowance,
                f'plan renewal: {sub.plan.name}',
                source_type='renewal', source_event_id=stripe_invoice_id,
            )


def _handle_invoice_payment_failed(event):
    invoice = event['data']['object']
    stripe_sub_id = invoice.get('subscription')
    if not stripe_sub_id:
        return
    sub = Subscription.query.filter_by(stripe_subscription_id=stripe_sub_id).first()
    if sub:
        sub.status = 'past_due'


def _handle_subscription_updated(event):
    stripe_sub = event['data']['object']
    sub = Subscription.query.filter_by(stripe_subscription_id=stripe_sub['id']).first()
    if not sub:
        return
    status_map = {
        'trialing': 'trialing', 'active': 'active', 'past_due': 'past_due',
        'canceled': 'canceled', 'unpaid': 'past_due', 'incomplete': 'incomplete',
        'incomplete_expired': 'canceled',
    }
    sub.status = status_map.get(stripe_sub.get('status'), sub.status)
    sub.cancel_at_period_end = bool(stripe_sub.get('cancel_at_period_end'))
    period_end = stripe_sub.get('current_period_end')
    if period_end:
        sub.current_period_end = datetime.utcfromtimestamp(period_end)


def _handle_subscription_deleted(event):
    stripe_sub = event['data']['object']
    sub = Subscription.query.filter_by(stripe_subscription_id=stripe_sub['id']).first()
    if sub:
        sub.status = 'canceled'
        sub.canceled_at = datetime.utcnow()
        sub.ended_at = datetime.utcnow()


def _handle_charge_refunded(event):
    charge = event['data']['object']
    payment = Payment.query.filter_by(stripe_charge_id=charge['id']).first()
    if not payment:
        # We may only have the payment_intent id stored, not the charge id — try that.
        pi = charge.get('payment_intent')
        payment = Payment.query.filter_by(stripe_payment_intent_id=pi).first() if pi else None
    if not payment:
        return
    payment.stripe_charge_id = payment.stripe_charge_id or charge['id']
    payment.refunded_amount_cents = charge.get('amount_refunded') or 0
    payment.status = 'refunded' if payment.refunded_amount_cents >= payment.amount_cents else 'partially_refunded'


_HANDLERS = {
    'checkout.session.completed': _handle_checkout_completed,
    'invoice.paid': _handle_invoice_paid,
    'invoice.payment_failed': _handle_invoice_payment_failed,
    'customer.subscription.updated': _handle_subscription_updated,
    'customer.subscription.deleted': _handle_subscription_deleted,
    'charge.refunded': _handle_charge_refunded,
}


@billing_bp.route('/webhooks/stripe', methods=['POST'])
def stripe_webhook():
    if not stripe_configured() or not current_app.config['STRIPE_WEBHOOK_SECRET']:
        abort(503)

    payload = request.get_data()
    sig_header = request.headers.get('Stripe-Signature', '')
    try:
        event = stripe.Webhook.construct_event(
            payload, sig_header, current_app.config['STRIPE_WEBHOOK_SECRET'])
    except (ValueError, stripe.error.SignatureVerificationError):
        abort(400)

    # Event-level dedup: insert-or-skip.
    if WebhookEvent.query.filter_by(stripe_event_id=event['id']).first():
        return '', 200

    # Handler + the WebhookEvent row commit together as one unit: either both land or
    # neither does, so a crash mid-handler never leaves an event marked processed with
    # partial side effects. A handler can flush (via credits.grant/reset_to, or the
    # Payment unique constraints) and hit IntegrityError partway through if a
    # concurrent/duplicate delivery already recorded the same business-level effect —
    # that means an equivalent effect is already applied, so roll back everything from
    # this delivery and report success, rather than erroring (which would just make
    # Stripe retry the same conflict forever).
    try:
        handler = _HANDLERS.get(event['type'])
        if handler:
            handler(event)
        db.session.add(WebhookEvent(stripe_event_id=event['id'], event_type=event['type']))
        db.session.commit()
    except IntegrityError:
        db.session.rollback()
    return '', 200
