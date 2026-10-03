import json
import uuid
from datetime import datetime, timedelta

from flask_login import UserMixin

from .extensions import db


def gen_token():
    return uuid.uuid4().hex


class Company(db.Model):
    __tablename__ = 'company'

    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(200), nullable=False)
    is_personal = db.Column(db.Boolean, nullable=False, default=False)
    owner_user_id = db.Column(db.Integer, db.ForeignKey('user.id', use_alter=True), nullable=True)
    status = db.Column(db.String(20), nullable=False, default='active')  # active | suspended
    stripe_customer_id = db.Column(db.String(100), nullable=True)
    # Server-to-server auth for products the company subscribes to (see app/api/) —
    # not a customer-facing OAuth thing, just a bearer token their product instance
    # presents to check entitlement/spend credits. Generated on demand, not at signup.
    api_key = db.Column(db.String(64), nullable=True, unique=True)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)

    users = db.relationship('User', back_populates='company', foreign_keys='User.company_id')
    owner = db.relationship('User', foreign_keys=[owner_user_id], post_update=True)

    @property
    def is_active_company(self):
        return self.status == 'active'

    @property
    def current_subscription(self):
        # Subscription is defined later in this module — fine, this only runs at call
        # time (once the module is fully loaded), not at class-definition time.
        return (Subscription.query.filter_by(company_id=self.id)
                .filter(Subscription.status.in_(('trialing', 'active', 'past_due')))
                .order_by(Subscription.started_at.desc()).first())

    @property
    def credit_balance(self):
        account = CompanyCreditAccount.query.get(self.id)
        return account.balance if account else 0

    @property
    def domains(self):
        return Domain.query.filter_by(company_id=self.id).order_by(Domain.created_at.desc()).all()

    @property
    def active_feature_grants(self):
        grants = FeatureGrant.query.filter_by(company_id=self.id).all()
        return [g for g in grants if g.is_active]

    def has_feature(self, feature_key):
        """True if this company's current plan's product includes this feature, or
        they have an active ad-hoc FeatureGrant for it (whichever comes first)."""
        if any(g.feature_key == feature_key for g in self.active_feature_grants):
            return True
        sub = self.current_subscription
        if sub and feature_key in json.loads(sub.plan.product.feature_flags or '[]'):
            return True
        for ent in PlanEntitlement.query.filter_by(company_id=self.id).all():
            if feature_key in json.loads(ent.plan.product.feature_flags or '[]'):
                return True
        return False


class User(UserMixin, db.Model):
    __tablename__ = 'user'

    id = db.Column(db.Integer, primary_key=True)
    company_id = db.Column(db.Integer, db.ForeignKey('company.id'), nullable=False)
    email = db.Column(db.String(255), nullable=False, unique=True, index=True)
    password_hash = db.Column(db.String(255), nullable=False)
    role = db.Column(db.String(20), nullable=False, default='member')  # owner | admin | member
    is_platform_admin = db.Column(db.Boolean, nullable=False, default=False)
    status = db.Column(db.String(20), nullable=False, default='active')  # active | suspended
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)

    company = db.relationship('Company', back_populates='users', foreign_keys=[company_id])

    # Flask-Login: a suspended user, or a user whose company is suspended, can't log in.
    @property
    def is_active(self):
        return self.status == 'active' and self.company is not None and self.company.is_active_company

    def has_company_role(self, *roles):
        return self.role in roles


class Invitation(db.Model):
    __tablename__ = 'invitation'

    id = db.Column(db.Integer, primary_key=True)
    company_id = db.Column(db.Integer, db.ForeignKey('company.id'), nullable=False)
    email = db.Column(db.String(255), nullable=False)
    role = db.Column(db.String(20), nullable=False, default='member')
    token = db.Column(db.String(64), nullable=False, unique=True, default=gen_token)
    # Nullable + SET NULL: removing a user who previously sent invites must not be
    # blocked by (or cascade-delete) the invitations they sent.
    invited_by_user_id = db.Column(db.Integer, db.ForeignKey('user.id', ondelete='SET NULL'), nullable=True)
    expires_at = db.Column(db.DateTime, nullable=False,
                            default=lambda: datetime.utcnow() + timedelta(days=7))
    accepted_at = db.Column(db.DateTime, nullable=True)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)

    company = db.relationship('Company')
    invited_by = db.relationship('User')

    @property
    def is_expired(self):
        return datetime.utcnow() > self.expires_at

    @property
    def is_pending(self):
        return self.accepted_at is None and not self.is_expired


class Product(db.Model):
    __tablename__ = 'product'

    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(200), nullable=False)
    description = db.Column(db.Text, nullable=False, default='')
    type = db.Column(db.String(20), nullable=False, default='subscription')
    # subscription | one_off | lifetime | free | trial
    feature_flags = db.Column(db.Text, nullable=False, default='[]')  # JSON list of feature keys
    is_active = db.Column(db.Boolean, nullable=False, default=True)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)

    plans = db.relationship('Plan', back_populates='product', order_by='Plan.id')


class Plan(db.Model):
    __tablename__ = 'plan'

    id = db.Column(db.Integer, primary_key=True)
    product_id = db.Column(db.Integer, db.ForeignKey('product.id'), nullable=False)
    name = db.Column(db.String(200), nullable=False)
    billing_period = db.Column(db.String(20), nullable=False, default='monthly')
    # monthly | yearly | one_off | lifetime
    price_cents = db.Column(db.Integer, nullable=False, default=0)
    currency = db.Column(db.String(10), nullable=False, default='usd')
    credit_allowance = db.Column(db.Integer, nullable=False, default=0)
    trial_days = db.Column(db.Integer, nullable=False, default=0)
    stripe_price_id = db.Column(db.String(100), nullable=True)
    stripe_product_id = db.Column(db.String(100), nullable=True)
    user_limit = db.Column(db.Integer, nullable=False, default=0)      # 0 = unlimited
    company_limit = db.Column(db.Integer, nullable=False, default=0)   # 0 = unlimited
    usage_limits = db.Column(db.Text, nullable=False, default='{}')    # JSON object
    is_active = db.Column(db.Boolean, nullable=False, default=True)
    archived_at = db.Column(db.DateTime, nullable=True)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)

    product = db.relationship('Product', back_populates='plans')


class Subscription(db.Model):
    """A company's current plan assignment. In this phase it's assigned manually by a
    platform admin (stripe_* fields stay null); Phase 3 wires Stripe webhooks to create
    and update these the same way instead."""
    __tablename__ = 'subscription'

    id = db.Column(db.Integer, primary_key=True)
    company_id = db.Column(db.Integer, db.ForeignKey('company.id'), nullable=False)
    plan_id = db.Column(db.Integer, db.ForeignKey('plan.id'), nullable=False)
    status = db.Column(db.String(20), nullable=False, default='active')
    # trialing | active | past_due | canceled | incomplete
    stripe_subscription_id = db.Column(db.String(100), nullable=True)
    stripe_customer_id = db.Column(db.String(100), nullable=True)
    current_period_end = db.Column(db.DateTime, nullable=True)
    cancel_at_period_end = db.Column(db.Boolean, nullable=False, default=False)
    started_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    canceled_at = db.Column(db.DateTime, nullable=True)
    ended_at = db.Column(db.DateTime, nullable=True)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)

    company = db.relationship('Company')
    plan = db.relationship('Plan')

    @property
    def is_current(self):
        return self.status in ('trialing', 'active', 'past_due') and self.ended_at is None


class PlanEntitlement(db.Model):
    """Durable access grant for one-off/lifetime purchases — deliberately NOT modeled as
    a Subscription, since those don't renew/expire/have a billing period the way a real
    Stripe subscription does. A checkout.session.completed webhook for a one_off/lifetime
    plan creates one of these instead of a Subscription."""
    __tablename__ = 'plan_entitlement'

    id = db.Column(db.Integer, primary_key=True)
    company_id = db.Column(db.Integer, db.ForeignKey('company.id'), nullable=False)
    plan_id = db.Column(db.Integer, db.ForeignKey('plan.id'), nullable=False)
    granted_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    source = db.Column(db.String(50), nullable=False, default='stripe_checkout')

    company = db.relationship('Company')
    plan = db.relationship('Plan')


class Payment(db.Model):
    __tablename__ = 'payment'

    id = db.Column(db.Integer, primary_key=True)
    company_id = db.Column(db.Integer, db.ForeignKey('company.id'), nullable=False)
    # Unique (Postgres unique indexes allow any number of NULLs, so this doesn't
    # conflict between one-off rows that only set payment_intent and renewal rows that
    # only set invoice_id) — a real idempotency guard, not just the app-level check in
    # the webhook handler, in case Stripe ever delivers a business-duplicate under a
    # different event id (retries under the *same* event id are caught separately by
    # WebhookEvent).
    stripe_payment_intent_id = db.Column(db.String(100), nullable=True, unique=True)
    stripe_invoice_id = db.Column(db.String(100), nullable=True, unique=True)
    stripe_charge_id = db.Column(db.String(100), nullable=True, index=True)
    amount_cents = db.Column(db.Integer, nullable=False, default=0)
    currency = db.Column(db.String(10), nullable=False, default='usd')
    status = db.Column(db.String(20), nullable=False, default='paid')
    # paid | failed | refunded | partially_refunded
    refunded_amount_cents = db.Column(db.Integer, nullable=False, default=0)
    refund_reason = db.Column(db.String(200), nullable=True)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)

    company = db.relationship('Company')


class WebhookEvent(db.Model):
    """Event-level idempotency guard for Stripe webhooks — a duplicate delivery of the
    same event id is a no-op. This is necessary but not sufficient on its own: business-
    level idempotency (e.g. not double-granting credits on a renewal) still needs its own
    guard where that logic lives, since Stripe retries and manual replays can produce
    distinct event ids for what should be the same effect."""
    __tablename__ = 'webhook_event'

    id = db.Column(db.Integer, primary_key=True)
    stripe_event_id = db.Column(db.String(100), nullable=False, unique=True, index=True)
    event_type = db.Column(db.String(100), nullable=False)
    processed_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)


class CompanyCreditAccount(db.Model):
    """Cached balance, one row per company. The ledger (CreditLedger) is the source of
    truth/audit trail; this column exists only so reading a balance doesn't mean
    summing the whole ledger every time. It must only ever be written by the atomic
    conditional UPDATE in credits.spend()/credits.grant() — never assigned directly —
    or the cache and the ledger will drift apart."""
    __tablename__ = 'company_credit_account'

    company_id = db.Column(db.Integer, db.ForeignKey('company.id'), primary_key=True)
    balance = db.Column(db.Integer, nullable=False, default=0)

    company = db.relationship('Company')


class CreditLedger(db.Model):
    """Append-only. `(company_id, source_type, source_event_id)` is the idempotency
    guard for grants/resets — e.g. a duplicate Stripe renewal webhook attempting the
    same insert hits the unique constraint instead of double-granting credits."""
    __tablename__ = 'credit_ledger'
    __table_args__ = (
        db.UniqueConstraint('company_id', 'source_type', 'source_event_id',
                             name='uq_credit_ledger_company_source'),
    )

    id = db.Column(db.Integer, primary_key=True)
    company_id = db.Column(db.Integer, db.ForeignKey('company.id'), nullable=False)
    delta = db.Column(db.Integer, nullable=False)  # positive = grant, negative = spend
    reason = db.Column(db.String(200), nullable=False, default='')
    balance_after = db.Column(db.Integer, nullable=False)
    source_type = db.Column(db.String(20), nullable=False)
    # purchase | renewal | manual | usage | bonus
    # NULL-safe: manual/usage entries don't have a Stripe event to dedup against, so
    # source_event_id is a random per-row token for those rather than NULL (a NULL
    # wouldn't collide with anything in the unique constraint, defeating the point for
    # entries that DO need dedup — but for entries that never repeat, this is just
    # bookkeeping, not a real dedup key).
    source_event_id = db.Column(db.String(100), nullable=False)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    expires_at = db.Column(db.DateTime, nullable=True)

    company = db.relationship('Company')


class CreditUsageRule(db.Model):
    __tablename__ = 'credit_usage_rule'

    id = db.Column(db.Integer, primary_key=True)
    feature_key = db.Column(db.String(100), nullable=False, unique=True)
    credits_cost = db.Column(db.Integer, nullable=False, default=1)
    product_id = db.Column(db.Integer, db.ForeignKey('product.id'), nullable=True)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)

    product = db.relationship('Product')


class Domain(db.Model):
    """A custom domain a company has connected. `status` moves pending -> verified ->
    active (or -> failed), driven by verification.check() — see app/domains/."""
    __tablename__ = 'domain'

    id = db.Column(db.Integer, primary_key=True)
    company_id = db.Column(db.Integer, db.ForeignKey('company.id'), nullable=False)
    hostname = db.Column(db.String(255), nullable=False, unique=True, index=True)
    cname_target = db.Column(db.String(255), nullable=False)
    cloudflare_zone_id = db.Column(db.String(100), nullable=True)
    cloudflare_record_id = db.Column(db.String(100), nullable=True)
    status = db.Column(db.String(20), nullable=False, default='pending')
    # pending | verified | active | failed
    failure_reason = db.Column(db.String(300), nullable=True)
    verify_token = db.Column(db.String(64), nullable=False, default=gen_token)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    verified_at = db.Column(db.DateTime, nullable=True)

    company = db.relationship('Company')


class FeatureGrant(db.Model):
    """Ad-hoc extra access for a specific company, outside/on top of whatever their
    plan includes — "give this one company early access to X" or "comp them Y as a
    goodwill gesture" without having to create a one-off plan for it. Orthogonal to
    plan/role, intentionally not a full Role/Permission system (YAGNI until there's
    more than this one axis of "extra access")."""
    __tablename__ = 'feature_grant'

    id = db.Column(db.Integer, primary_key=True)
    company_id = db.Column(db.Integer, db.ForeignKey('company.id'), nullable=False)
    feature_key = db.Column(db.String(100), nullable=False)
    granted_by_admin_id = db.Column(db.Integer, db.ForeignKey('user.id'), nullable=True)
    expires_at = db.Column(db.DateTime, nullable=True)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)

    company = db.relationship('Company')
    granted_by = db.relationship('User')

    @property
    def is_active(self):
        return self.expires_at is None or self.expires_at > datetime.utcnow()


class AuditLog(db.Model):
    """Platform-wide activity log — every admin-mutating action lands here. `actor_user_id`
    is nullable so system-driven changes (webhooks, the reconcile/verify-domains timers)
    can log too, distinguishable from a human admin action by actor being empty."""
    __tablename__ = 'audit_log'

    id = db.Column(db.Integer, primary_key=True)
    actor_user_id = db.Column(db.Integer, db.ForeignKey('user.id'), nullable=True)
    action = db.Column(db.String(100), nullable=False)
    target_type = db.Column(db.String(50), nullable=True)
    target_id = db.Column(db.Integer, nullable=True)
    details = db.Column(db.Text, nullable=False, default='{}')  # JSON
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow, index=True)

    actor = db.relationship('User')


class LoginAttempt(db.Model):
    """DB-backed brute-force lockout — deliberately not in-memory, since this app runs
    under multiple gunicorn workers that don't share process memory. Tracks both the
    email being targeted and the source IP under the same mechanism (`key` is
    'email:<addr>' or 'ip:<addr>'), so a lockout catches both "many guesses against one
    account" and "one IP spraying many accounts"."""
    __tablename__ = 'login_attempt'

    id = db.Column(db.Integer, primary_key=True)
    key = db.Column(db.String(255), nullable=False, unique=True, index=True)
    failed_count = db.Column(db.Integer, nullable=False, default=0)
    locked_until = db.Column(db.DateTime, nullable=True)
    updated_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow, onupdate=datetime.utcnow)
