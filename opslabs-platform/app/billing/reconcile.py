"""Safety net for missed/delayed Stripe webhooks. `invoice.paid` driving credit resets
(see routes.py) is the primary path — this only matters if a webhook delivery is lost
(Stripe retries for a while, but not forever) or this app was down when it arrived.

Run periodically (e.g. hourly, via the opslabs-platform-reconcile systemd timer):
    flask reconcile-credits

For each subscription whose local current_period_end has already passed, re-fetch its
real state from Stripe directly (source of truth) rather than guessing from what we
have locally, and if the period actually advanced, apply the same reset_to() used by
the invoice.paid handler — keyed on the real invoice id, so if the "missing" webhook
actually arrives later (just late, not lost), reset_to's unique constraint makes that a
harmless no-op instead of a double reset.
"""
from datetime import datetime, timedelta

import stripe
from sqlalchemy.exc import IntegrityError

from ..extensions import db
from ..models import Subscription
from . import credits as credits_lib

GRACE_PERIOD = timedelta(hours=1)  # give the normal webhook a chance to land first


def reconcile(stripe_secret_key):
    if not stripe_secret_key:
        print('[reconcile] STRIPE_SECRET_KEY not set — nothing to do.')
        return

    stripe.api_key = stripe_secret_key
    cutoff = datetime.utcnow() - GRACE_PERIOD

    stale = (Subscription.query
             .filter(Subscription.status.in_(('trialing', 'active', 'past_due')))
             .filter(Subscription.current_period_end.isnot(None))
             .filter(Subscription.current_period_end < cutoff)
             .filter(Subscription.stripe_subscription_id.isnot(None))
             .all())

    if not stale:
        print('[reconcile] Nothing to check — no subscriptions past their local period end.')
        return

    for sub in stale:
        try:
            _reconcile_one(sub)
        except Exception as e:
            db.session.rollback()
            print(f'[reconcile] FAILED for subscription {sub.id} '
                  f'({sub.stripe_subscription_id}): {e} — will retry next run.')


def _reconcile_one(sub):
    remote = stripe.Subscription.retrieve(sub.stripe_subscription_id)

    old_period_end = sub.current_period_end
    new_period_end_ts = remote.get('current_period_end')
    new_period_end = datetime.utcfromtimestamp(new_period_end_ts) if new_period_end_ts else None
    period_advanced = new_period_end and (not old_period_end or new_period_end > old_period_end)

    # Settle credits for the new period FIRST, and don't advance current_period_end in
    # our own DB until that's actually settled — otherwise a transient failure here
    # followed by a retry would see "no further advancement" and silently skip the
    # credit reset forever, since the comparison above is against our own last-synced
    # value, not Stripe's.
    if period_advanced:
        invoices = stripe.Invoice.list(subscription=sub.stripe_subscription_id, status='paid', limit=1)
        if not invoices.data:
            print(f'[reconcile] Subscription {sub.id}: period advanced but no paid invoice '
                  'found yet — leaving current_period_end as-is, will retry next run.')
            return  # don't touch current_period_end; retry from the same starting point

        latest_invoice = invoices.data[0]
        if sub.plan.credit_allowance:
            try:
                credits_lib.reset_to(
                    sub.company_id, sub.plan.credit_allowance,
                    f'plan renewal (reconciled): {sub.plan.name}',
                    source_type='renewal', source_event_id=latest_invoice['id'],
                )
            except IntegrityError:
                # Already applied — the "missing" webhook was actually just late, not
                # lost. That's fine, credits are correctly settled either way.
                db.session.rollback()
        print(f'[reconcile] Subscription {sub.id}: reconciled renewal '
              f'(invoice {latest_invoice["id"]}).')

    status_map = {
        'trialing': 'trialing', 'active': 'active', 'past_due': 'past_due',
        'canceled': 'canceled', 'unpaid': 'past_due', 'incomplete': 'incomplete',
        'incomplete_expired': 'canceled',
    }
    sub.status = status_map.get(remote.get('status'), sub.status)
    if new_period_end:
        sub.current_period_end = new_period_end
    db.session.commit()
