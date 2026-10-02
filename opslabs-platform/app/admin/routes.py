import json
from datetime import datetime, timedelta
from functools import wraps

from flask import Blueprint, render_template, redirect, url_for, flash, abort, request
from flask_login import login_required, current_user

from ..extensions import db
from ..models import (User, Company, Invitation, Product, Plan, Subscription,
                       CreditLedger, CreditUsageRule)
from ..billing import credits as credits_lib
from ..audit import log as audit_log

admin_bp = Blueprint('admin', __name__, url_prefix='/admin')


def platform_admin_required(view):
    @wraps(view)
    @login_required
    def wrapped(*args, **kwargs):
        if not current_user.is_platform_admin:
            abort(404)  # don't reveal the admin area exists to non-admins
        return view(*args, **kwargs)
    return wrapped


@admin_bp.route('/')
@platform_admin_required
def overview():
    return render_template('admin/overview.html',
                            user_count=User.query.count(),
                            company_count=Company.query.count())


@admin_bp.route('/users')
@platform_admin_required
def users():
    all_users = User.query.order_by(User.created_at.desc()).all()
    return render_template('admin/users.html', users=all_users)


@admin_bp.route('/users/<int:user_id>/suspend', methods=['POST'])
@platform_admin_required
def suspend_user(user_id):
    user = db.session.get(User, user_id) or abort(404)
    user.status = 'suspended'
    audit_log('suspend_user', actor_user_id=current_user.id, target_type='user',
               target_id=user.id, email=user.email)
    db.session.commit()
    flash(f'{user.email} suspended.', 'success')
    return redirect(url_for('admin.users'))


@admin_bp.route('/users/<int:user_id>/activate', methods=['POST'])
@platform_admin_required
def activate_user(user_id):
    user = db.session.get(User, user_id) or abort(404)
    user.status = 'active'
    audit_log('activate_user', actor_user_id=current_user.id, target_type='user',
               target_id=user.id, email=user.email)
    db.session.commit()
    flash(f'{user.email} activated.', 'success')
    return redirect(url_for('admin.users'))


@admin_bp.route('/users/<int:user_id>/remove', methods=['POST'])
@platform_admin_required
def remove_user(user_id):
    user = db.session.get(User, user_id) or abort(404)
    is_owner = user.company and user.company.owner_user_id == user.id

    if is_owner and user.company.is_personal:
        # A personal company only ever has this one user — remove both together
        # rather than leaving an orphaned, ownerless personal company behind.
        company = user.company
        company.owner_user_id = None
        db.session.flush()
        Invitation.query.filter_by(company_id=company.id).delete()
        audit_log('remove_user', actor_user_id=current_user.id, target_type='user',
                   target_id=user.id, email=user.email, note='cascaded personal company')
        db.session.delete(user)
        db.session.delete(company)
        db.session.commit()
        flash('User and their personal account removed.', 'success')
        return redirect(url_for('admin.users'))

    if is_owner:
        flash('Can\'t remove a company owner directly — remove the company instead, '
              'or reassign ownership first (not yet built).', 'error')
        return redirect(url_for('admin.users'))

    audit_log('remove_user', actor_user_id=current_user.id, target_type='user',
               target_id=user.id, email=user.email)
    db.session.delete(user)
    db.session.commit()
    flash('User removed.', 'success')
    return redirect(url_for('admin.users'))


@admin_bp.route('/companies')
@platform_admin_required
def companies():
    all_companies = Company.query.order_by(Company.created_at.desc()).all()
    return render_template('admin/companies.html', companies=all_companies)


@admin_bp.route('/companies/<int:company_id>/suspend', methods=['POST'])
@platform_admin_required
def suspend_company(company_id):
    company = db.session.get(Company, company_id) or abort(404)
    company.status = 'suspended'
    audit_log('suspend_company', actor_user_id=current_user.id, target_type='company',
               target_id=company.id, name=company.name)
    db.session.commit()
    flash(f'{company.name} suspended — all its users are locked out.', 'success')
    return redirect(url_for('admin.companies'))


@admin_bp.route('/companies/<int:company_id>/activate', methods=['POST'])
@platform_admin_required
def activate_company(company_id):
    company = db.session.get(Company, company_id) or abort(404)
    company.status = 'active'
    audit_log('activate_company', actor_user_id=current_user.id, target_type='company',
               target_id=company.id, name=company.name)
    db.session.commit()
    flash(f'{company.name} activated.', 'success')
    return redirect(url_for('admin.companies'))


@admin_bp.route('/companies/<int:company_id>/remove', methods=['POST'])
@platform_admin_required
def remove_company(company_id):
    company = db.session.get(Company, company_id) or abort(404)
    # Break the owner_user_id -> user FK cycle before cascading, then delete
    # invitations (both sent by this company's users and sent to join it) and all
    # members, then the company itself.
    company.owner_user_id = None
    db.session.flush()
    Invitation.query.filter_by(company_id=company.id).delete()
    User.query.filter_by(company_id=company.id).delete()
    audit_log('remove_company', actor_user_id=current_user.id, target_type='company',
               target_id=company.id, name=company.name)
    db.session.delete(company)
    db.session.commit()
    flash('Company and all its users removed.', 'success')
    return redirect(url_for('admin.companies'))


@admin_bp.route('/companies/<int:company_id>')
@platform_admin_required
def company_detail(company_id):
    company = db.session.get(Company, company_id) or abort(404)
    subscriptions = (Subscription.query.filter_by(company_id=company.id)
                      .order_by(Subscription.started_at.desc()).all())
    plans = Plan.query.filter_by(is_active=True).order_by(Plan.id).all()
    ledger = (CreditLedger.query.filter_by(company_id=company.id)
              .order_by(CreditLedger.created_at.desc()).limit(50).all())
    return render_template('admin/company_detail.html', company=company,
                            subscriptions=subscriptions, plans=plans, ledger=ledger)


@admin_bp.route('/companies/<int:company_id>/api-key/generate', methods=['POST'])
@platform_admin_required
def generate_api_key(company_id):
    import secrets
    company = db.session.get(Company, company_id) or abort(404)
    company.api_key = secrets.token_hex(32)
    audit_log('generate_api_key', actor_user_id=current_user.id, target_type='company',
               target_id=company.id)
    db.session.commit()
    flash(f'New API key generated for {company.name}.', 'success')
    return redirect(url_for('admin.company_detail', company_id=company.id))


@admin_bp.route('/companies/<int:company_id>/api-key/revoke', methods=['POST'])
@platform_admin_required
def revoke_api_key(company_id):
    company = db.session.get(Company, company_id) or abort(404)
    company.api_key = None
    audit_log('revoke_api_key', actor_user_id=current_user.id, target_type='company',
               target_id=company.id)
    db.session.commit()
    flash(f'API key revoked for {company.name}.', 'success')
    return redirect(url_for('admin.company_detail', company_id=company.id))


@admin_bp.route('/companies/<int:company_id>/assign-plan', methods=['POST'])
@platform_admin_required
def assign_plan(company_id):
    company = db.session.get(Company, company_id) or abort(404)
    plan = db.session.get(Plan, request.form.get('plan_id', type=int)) or abort(404)

    # End whatever's currently active before starting the new one — a company has
    # at most one current subscription.
    current = company.current_subscription
    if current:
        current.status = 'canceled'
        current.canceled_at = datetime.utcnow()
        current.ended_at = datetime.utcnow()

    sub = Subscription(company_id=company.id, plan_id=plan.id, status='active')
    db.session.add(sub)
    if plan.credit_allowance:
        credits_lib.grant(company.id, plan.credit_allowance,
                           f'manually assigned plan: {plan.name}', source_type='manual')
    audit_log('assign_plan', actor_user_id=current_user.id, target_type='company',
               target_id=company.id, plan=plan.name)
    db.session.commit()
    flash(f'{company.name} assigned to plan "{plan.name}".', 'success')
    return redirect(url_for('admin.company_detail', company_id=company.id))


@admin_bp.route('/companies/<int:company_id>/credits/grant', methods=['POST'])
@platform_admin_required
def grant_credits(company_id):
    company = db.session.get(Company, company_id) or abort(404)
    amount = request.form.get('amount', type=int)
    reason = request.form.get('reason', '').strip() or 'manual admin grant'
    if not amount or amount <= 0:
        flash('Enter a positive number of credits to grant.', 'error')
        return redirect(url_for('admin.company_detail', company_id=company.id))

    credits_lib.grant(company.id, amount, reason, source_type='bonus')
    audit_log('grant_credits', actor_user_id=current_user.id, target_type='company',
               target_id=company.id, amount=amount, reason=reason)
    db.session.commit()
    flash(f'Granted {amount} credits to {company.name}.', 'success')
    return redirect(url_for('admin.company_detail', company_id=company.id))


@admin_bp.route('/companies/<int:company_id>/credits/remove', methods=['POST'])
@platform_admin_required
def remove_credits(company_id):
    company = db.session.get(Company, company_id) or abort(404)
    amount = request.form.get('amount', type=int)
    reason = request.form.get('reason', '').strip() or 'manual admin removal'
    if not amount or amount <= 0:
        flash('Enter a positive number of credits to remove.', 'error')
        return redirect(url_for('admin.company_detail', company_id=company.id))

    try:
        credits_lib.spend(company.id, amount, reason, source_type='manual')
    except credits_lib.InsufficientCredits:
        flash(f'{company.name} only has {company.credit_balance} credits — can\'t remove {amount}.', 'error')
        return redirect(url_for('admin.company_detail', company_id=company.id))

    audit_log('remove_credits', actor_user_id=current_user.id, target_type='company',
               target_id=company.id, amount=amount, reason=reason)
    db.session.commit()
    flash(f'Removed {amount} credits from {company.name}.', 'success')
    return redirect(url_for('admin.company_detail', company_id=company.id))


@admin_bp.route('/companies/<int:company_id>/cancel-subscription', methods=['POST'])
@platform_admin_required
def cancel_subscription(company_id):
    company = db.session.get(Company, company_id) or abort(404)
    sub = company.current_subscription
    if not sub:
        flash(f'{company.name} has no active subscription to cancel.', 'error')
        return redirect(url_for('admin.company_detail', company_id=company.id))

    sub.status = 'canceled'
    sub.canceled_at = datetime.utcnow()
    sub.ended_at = datetime.utcnow()
    audit_log('cancel_subscription', actor_user_id=current_user.id, target_type='company',
               target_id=company.id, plan=sub.plan.name)
    db.session.commit()
    flash(f'Canceled {company.name}\'s subscription to "{sub.plan.name}".', 'success')
    return redirect(url_for('admin.company_detail', company_id=company.id))


# ─── PRODUCTS ────────────────────────────────────────────────────────────────

def _parse_feature_flags(raw):
    keys = [k.strip() for k in raw.split(',') if k.strip()]
    return json.dumps(keys)


def _parse_usage_limits(raw):
    raw = raw.strip() or '{}'
    try:
        parsed = json.loads(raw)
        if not isinstance(parsed, dict):
            raise ValueError
    except ValueError:
        return None
    return json.dumps(parsed)


@admin_bp.route('/products')
@platform_admin_required
def products():
    all_products = Product.query.order_by(Product.created_at.desc()).all()
    return render_template('admin/products.html', products=all_products)


@admin_bp.route('/products/new', methods=['GET', 'POST'])
@platform_admin_required
def new_product():
    if request.method == 'POST':
        name = request.form.get('name', '').strip()
        if not name:
            flash('Enter a product name.', 'error')
            return render_template('admin/product_form.html', product=None)

        product = Product(
            name=name,
            description=request.form.get('description', '').strip(),
            type=request.form.get('type', 'subscription'),
            feature_flags=_parse_feature_flags(request.form.get('feature_flags', '')),
            is_active=request.form.get('is_active') == 'on',
        )
        db.session.add(product)
        db.session.flush()
        audit_log('create_product', actor_user_id=current_user.id, target_type='product',
                   target_id=product.id, name=product.name)
        db.session.commit()
        flash(f'Product "{product.name}" created.', 'success')
        return redirect(url_for('admin.products'))

    return render_template('admin/product_form.html', product=None)


@admin_bp.route('/products/<int:product_id>/edit', methods=['GET', 'POST'])
@platform_admin_required
def edit_product(product_id):
    product = db.session.get(Product, product_id) or abort(404)
    if request.method == 'POST':
        product.name = request.form.get('name', '').strip() or product.name
        product.description = request.form.get('description', '').strip()
        product.type = request.form.get('type', product.type)
        product.feature_flags = _parse_feature_flags(request.form.get('feature_flags', ''))
        product.is_active = request.form.get('is_active') == 'on'
        audit_log('edit_product', actor_user_id=current_user.id, target_type='product',
                   target_id=product.id, name=product.name)
        db.session.commit()
        flash(f'Product "{product.name}" updated.', 'success')
        return redirect(url_for('admin.products'))

    return render_template('admin/product_form.html', product=product)


@admin_bp.route('/products/<int:product_id>/delete', methods=['POST'])
@platform_admin_required
def delete_product(product_id):
    product = db.session.get(Product, product_id) or abort(404)
    if Plan.query.filter_by(product_id=product.id).count():
        flash('Can\'t delete a product that still has plans — archive it instead, '
              'or delete its plans first.', 'error')
        return redirect(url_for('admin.products'))
    audit_log('delete_product', actor_user_id=current_user.id, target_type='product',
               target_id=product.id, name=product.name)
    db.session.delete(product)
    db.session.commit()
    flash('Product deleted.', 'success')
    return redirect(url_for('admin.products'))


# ─── PLANS ───────────────────────────────────────────────────────────────────

@admin_bp.route('/plans')
@platform_admin_required
def plans():
    all_plans = Plan.query.order_by(Plan.product_id, Plan.id).all()
    return render_template('admin/plans.html', plans=all_plans)


@admin_bp.route('/plans/new', methods=['GET', 'POST'])
@platform_admin_required
def new_plan():
    all_products = Product.query.order_by(Product.name).all()
    if request.method == 'POST':
        usage_limits = _parse_usage_limits(request.form.get('usage_limits', ''))
        if usage_limits is None:
            flash('Usage limits must be valid JSON (an object), e.g. {}', 'error')
            return render_template('admin/plan_form.html', plan=None, products=all_products)

        plan = Plan(
            product_id=request.form.get('product_id', type=int),
            name=request.form.get('name', '').strip(),
            billing_period=request.form.get('billing_period', 'monthly'),
            price_cents=request.form.get('price_cents', type=int, default=0),
            currency=request.form.get('currency', 'usd').strip().lower() or 'usd',
            credit_allowance=request.form.get('credit_allowance', type=int, default=0),
            trial_days=request.form.get('trial_days', type=int, default=0),
            user_limit=request.form.get('user_limit', type=int, default=0),
            company_limit=request.form.get('company_limit', type=int, default=0),
            usage_limits=usage_limits,
            stripe_price_id=request.form.get('stripe_price_id', '').strip() or None,
            stripe_product_id=request.form.get('stripe_product_id', '').strip() or None,
            is_active=request.form.get('is_active') == 'on',
        )
        if not plan.name or not plan.product_id:
            flash('Enter a plan name and choose a product.', 'error')
            return render_template('admin/plan_form.html', plan=None, products=all_products)

        db.session.add(plan)
        db.session.flush()
        audit_log('create_plan', actor_user_id=current_user.id, target_type='plan',
                   target_id=plan.id, name=plan.name)
        db.session.commit()
        flash(f'Plan "{plan.name}" created.', 'success')
        return redirect(url_for('admin.plans'))

    return render_template('admin/plan_form.html', plan=None, products=all_products)


@admin_bp.route('/plans/<int:plan_id>/edit', methods=['GET', 'POST'])
@platform_admin_required
def edit_plan(plan_id):
    plan = db.session.get(Plan, plan_id) or abort(404)
    all_products = Product.query.order_by(Product.name).all()
    if request.method == 'POST':
        usage_limits = _parse_usage_limits(request.form.get('usage_limits', ''))
        if usage_limits is None:
            flash('Usage limits must be valid JSON (an object), e.g. {}', 'error')
            return render_template('admin/plan_form.html', plan=plan, products=all_products)

        plan.product_id = request.form.get('product_id', type=int)
        plan.name = request.form.get('name', '').strip() or plan.name
        plan.billing_period = request.form.get('billing_period', plan.billing_period)
        plan.price_cents = request.form.get('price_cents', type=int, default=0)
        plan.currency = request.form.get('currency', 'usd').strip().lower() or 'usd'
        plan.credit_allowance = request.form.get('credit_allowance', type=int, default=0)
        plan.trial_days = request.form.get('trial_days', type=int, default=0)
        plan.user_limit = request.form.get('user_limit', type=int, default=0)
        plan.company_limit = request.form.get('company_limit', type=int, default=0)
        plan.usage_limits = usage_limits
        plan.stripe_price_id = request.form.get('stripe_price_id', '').strip() or None
        plan.stripe_product_id = request.form.get('stripe_product_id', '').strip() or None
        plan.is_active = request.form.get('is_active') == 'on'
        audit_log('edit_plan', actor_user_id=current_user.id, target_type='plan',
                   target_id=plan.id, name=plan.name)
        db.session.commit()
        flash(f'Plan "{plan.name}" updated.', 'success')
        return redirect(url_for('admin.plans'))

    return render_template('admin/plan_form.html', plan=plan, products=all_products)


@admin_bp.route('/plans/<int:plan_id>/archive', methods=['POST'])
@platform_admin_required
def archive_plan(plan_id):
    plan = db.session.get(Plan, plan_id) or abort(404)
    plan.is_active = False
    plan.archived_at = datetime.utcnow()
    audit_log('archive_plan', actor_user_id=current_user.id, target_type='plan',
               target_id=plan.id, name=plan.name)
    db.session.commit()
    flash(f'Plan "{plan.name}" archived — existing subscribers keep it, but it can\'t '
          'be assigned to new companies.', 'success')
    return redirect(url_for('admin.plans'))


# ─── CREDIT USAGE RULES ──────────────────────────────────────────────────────

@admin_bp.route('/usage-rules')
@platform_admin_required
def usage_rules():
    rules = CreditUsageRule.query.order_by(CreditUsageRule.feature_key).all()
    return render_template('admin/usage_rules.html', rules=rules)


@admin_bp.route('/usage-rules/new', methods=['POST'])
@platform_admin_required
def new_usage_rule():
    feature_key = request.form.get('feature_key', '').strip()
    cost = request.form.get('credits_cost', type=int, default=1)
    product_id = request.form.get('product_id', type=int) or None

    if not feature_key:
        flash('Enter a feature key.', 'error')
        return redirect(url_for('admin.usage_rules'))
    if CreditUsageRule.query.filter_by(feature_key=feature_key).first():
        flash(f'A rule for "{feature_key}" already exists — edit it instead.', 'error')
        return redirect(url_for('admin.usage_rules'))

    rule = CreditUsageRule(feature_key=feature_key, credits_cost=max(cost, 0), product_id=product_id)
    db.session.add(rule)
    db.session.flush()
    audit_log('create_usage_rule', actor_user_id=current_user.id, target_type='usage_rule',
               target_id=rule.id, feature_key=feature_key, cost=rule.credits_cost)
    db.session.commit()
    flash(f'Usage rule for "{feature_key}" created.', 'success')
    return redirect(url_for('admin.usage_rules'))


@admin_bp.route('/usage-rules/<int:rule_id>/update', methods=['POST'])
@platform_admin_required
def update_usage_rule(rule_id):
    rule = db.session.get(CreditUsageRule, rule_id) or abort(404)
    rule.credits_cost = max(request.form.get('credits_cost', type=int, default=1), 0)
    db.session.commit()
    flash(f'"{rule.feature_key}" now costs {rule.credits_cost} credit(s).', 'success')
    return redirect(url_for('admin.usage_rules'))


@admin_bp.route('/usage-rules/<int:rule_id>/delete', methods=['POST'])
@platform_admin_required
def delete_usage_rule(rule_id):
    rule = db.session.get(CreditUsageRule, rule_id) or abort(404)
    db.session.delete(rule)
    db.session.commit()
    flash('Usage rule deleted — that feature now falls back to the 1-credit default.', 'success')
    return redirect(url_for('admin.usage_rules'))


# ─── DOMAINS ─────────────────────────────────────────────────────────────────

@admin_bp.route('/domains')
@platform_admin_required
def domains():
    from ..models import Domain
    all_domains = Domain.query.order_by(Domain.created_at.desc()).all()
    return render_template('admin/domains.html', domains=all_domains)


@admin_bp.route('/domains/<int:domain_id>/recheck', methods=['POST'])
@platform_admin_required
def recheck_domain(domain_id):
    from datetime import datetime
    from ..models import Domain
    from ..domains import verification

    domain = db.session.get(Domain, domain_id) or abort(404)
    new_status, reason = verification.check(domain)
    domain.status = new_status
    domain.failure_reason = reason
    if new_status == 'active' and not domain.verified_at:
        domain.verified_at = datetime.utcnow()
    db.session.commit()
    flash(f'{domain.hostname}: {new_status}' + (f' — {reason}' if reason else ''), 'success')
    return redirect(url_for('admin.domains'))


# ─── FEATURE GRANTS ──────────────────────────────────────────────────────────

@admin_bp.route('/companies/<int:company_id>/features/grant', methods=['POST'])
@platform_admin_required
def grant_feature(company_id):
    from ..models import FeatureGrant

    company = db.session.get(Company, company_id) or abort(404)
    feature_key = request.form.get('feature_key', '').strip()
    if not feature_key:
        flash('Enter a feature key.', 'error')
        return redirect(url_for('admin.company_detail', company_id=company.id))

    days = request.form.get('expires_days', type=int)
    expires_at = datetime.utcnow() + timedelta(days=days) if days else None

    grant = FeatureGrant(company_id=company.id, feature_key=feature_key,
                          granted_by_admin_id=current_user.id, expires_at=expires_at)
    db.session.add(grant)
    db.session.flush()
    audit_log('grant_feature', actor_user_id=current_user.id, target_type='company',
               target_id=company.id, feature_key=feature_key,
               expires_at=expires_at.isoformat() if expires_at else None)
    db.session.commit()
    flash(f'Granted "{feature_key}" to {company.name}' +
          (f' for {days} days' if days else ' (no expiry)') + '.', 'success')
    return redirect(url_for('admin.company_detail', company_id=company.id))


@admin_bp.route('/companies/<int:company_id>/features/<int:grant_id>/revoke', methods=['POST'])
@platform_admin_required
def revoke_feature(company_id, grant_id):
    from ..models import FeatureGrant

    grant = db.session.get(FeatureGrant, grant_id) or abort(404)
    if grant.company_id != company_id:
        abort(404)
    audit_log('revoke_feature', actor_user_id=current_user.id, target_type='company',
               target_id=company_id, feature_key=grant.feature_key)
    db.session.delete(grant)
    db.session.commit()
    flash(f'Revoked "{grant.feature_key}".', 'success')
    return redirect(url_for('admin.company_detail', company_id=company_id))


# ─── PLATFORM-WIDE OVERVIEW ──────────────────────────────────────────────────

@admin_bp.route('/subscriptions')
@platform_admin_required
def subscriptions():
    all_subs = Subscription.query.order_by(Subscription.started_at.desc()).limit(200).all()
    return render_template('admin/subscriptions.html', subscriptions=all_subs)


@admin_bp.route('/payments')
@platform_admin_required
def payments():
    from ..models import Payment
    all_payments = Payment.query.order_by(Payment.created_at.desc()).limit(200).all()
    return render_template('admin/payments.html', payments=all_payments)


@admin_bp.route('/activity')
@platform_admin_required
def activity():
    from ..models import AuditLog
    entries = AuditLog.query.order_by(AuditLog.created_at.desc()).limit(200).all()
    return render_template('admin/activity.html', entries=entries)


@admin_bp.route('/system')
@platform_admin_required
def system():
    from flask import current_app
    from ..billing.routes import stripe_configured
    from ..domains.routes import domains_configured

    db_url = current_app.config['SQLALCHEMY_DATABASE_URI']
    db_display = db_url.split('@')[-1] if '@' in db_url else db_url  # never show the password

    return render_template('admin/system.html',
                            stripe_ready=stripe_configured(),
                            domains_ready=domains_configured(),
                            db_display=db_display,
                            platform_admin_email=current_app.config['PLATFORM_ADMIN_EMAIL'],
                            user_count=User.query.count(),
                            company_count=Company.query.count(),
                            product_count=Product.query.count(),
                            plan_count=Plan.query.count())
