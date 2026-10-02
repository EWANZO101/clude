import json
from datetime import datetime, timedelta

from flask import Blueprint, render_template, request, redirect, url_for, flash
from flask_login import login_user, logout_user, login_required, current_user
from werkzeug.security import generate_password_hash, check_password_hash

from ..extensions import db
from ..models import Company, User, Invitation, Plan, PlanEntitlement
from ..billing.routes import stripe_configured
from ..billing import credits as credits_lib
from .security import is_locked, record_failure, clear_failures, client_ip

auth_bp = Blueprint('auth', __name__)


@auth_bp.route('/signup', methods=['GET', 'POST'])
def signup():
    if current_user.is_authenticated:
        return redirect(url_for('auth.dashboard'))

    if request.method == 'POST':
        account_type = request.form.get('account_type', 'individual')
        email = request.form.get('email', '').strip().lower()
        password = request.form.get('password', '')
        company_name = request.form.get('company_name', '').strip()

        errors = []
        if not email or '@' not in email:
            errors.append('Enter a valid email address.')
        if len(password) < 8:
            errors.append('Password must be at least 8 characters.')
        if account_type == 'company' and not company_name:
            errors.append('Enter a company name.')
        if email and User.query.filter_by(email=email).first():
            errors.append('An account with that email already exists.')

        if errors:
            for e in errors:
                flash(e, 'error')
            return render_template('auth/signup.html', account_type=account_type,
                                    email=email, company_name=company_name)

        is_personal = account_type != 'company'
        company = Company(
            name=company_name if not is_personal else f"{email}'s account",
            is_personal=is_personal,
        )
        db.session.add(company)
        db.session.flush()  # get company.id before creating the owning user

        user = User(
            company_id=company.id,
            email=email,
            password_hash=generate_password_hash(password),
            role='owner',
        )
        db.session.add(user)
        db.session.flush()

        company.owner_user_id = user.id
        db.session.commit()

        login_user(user)
        flash('Welcome! Your account has been created.', 'success')
        return redirect(url_for('auth.dashboard'))

    return render_template('auth/signup.html', account_type='individual', email='', company_name='')


@auth_bp.route('/login', methods=['GET', 'POST'])
def login():
    if current_user.is_authenticated:
        return redirect(url_for('auth.dashboard'))

    if request.method == 'POST':
        email = request.form.get('email', '').strip().lower()
        password = request.form.get('password', '')
        ip = client_ip(request)
        email_key, ip_key = f'email:{email}', f'ip:{ip}'

        if is_locked(email_key) or is_locked(ip_key):
            flash('Too many failed attempts. Try again in a few minutes.', 'error')
            return render_template('auth/login.html'), 429

        user = User.query.filter_by(email=email).first()
        valid = user and check_password_hash(user.password_hash, password)

        if valid and user.is_active:
            clear_failures(email_key)
            clear_failures(ip_key)
            login_user(user)
            return redirect(url_for('auth.dashboard'))

        record_failure(email_key)
        record_failure(ip_key)
        if valid and user and not user.is_active:
            flash('This account or company has been suspended.', 'error')
        else:
            flash('Invalid email or password.', 'error')

    return render_template('auth/login.html')


@auth_bp.route('/logout')
@login_required
def logout():
    logout_user()
    return redirect(url_for('auth.login'))


@auth_bp.route('/dashboard')
@login_required
def dashboard():
    pending_invites = Invitation.query.filter_by(company_id=current_user.company_id).all()
    pending_invites = [i for i in pending_invites if i.is_pending]

    available_plans = (Plan.query.filter_by(is_active=True)
                        .filter(Plan.stripe_price_id.isnot(None)).order_by(Plan.id).all())
    entitlements = PlanEntitlement.query.filter_by(company_id=current_user.company_id).all()

    from ..domains.routes import domains_configured
    from ..models import CreditLedger

    company = current_user.company
    features = set(g.feature_key for g in company.active_feature_grants)
    sub = company.current_subscription
    if sub:
        features |= set(json.loads(sub.plan.product.feature_flags or '[]'))
    for ent in entitlements:
        features |= set(json.loads(ent.plan.product.feature_flags or '[]'))

    usage_entries = (CreditLedger.query.filter_by(company_id=company.id)
                      .order_by(CreditLedger.created_at.desc()).limit(10).all())
    thirty_days_ago = datetime.utcnow() - timedelta(days=30)
    spent_30d = (db.session.query(db.func.coalesce(db.func.sum(-CreditLedger.delta), 0))
                 .filter(CreditLedger.company_id == company.id,
                         CreditLedger.delta < 0,
                         CreditLedger.created_at >= thirty_days_ago)
                 .scalar())

    return render_template('auth/dashboard.html', pending_invites=pending_invites,
                            available_plans=available_plans, entitlements=entitlements,
                            billing_ready=stripe_configured(),
                            domains_ready=domains_configured(),
                            features=sorted(features),
                            usage_entries=usage_entries, spent_30d=spent_30d)


@auth_bp.route('/demo/use-credit', methods=['POST'])
@login_required
def demo_use_credit():
    """Proves the credit-spend plumbing end-to-end: DB-backed atomic deduction, ledger
    entry, updated cached balance — all through the same spend_for_feature() path a
    real product feature would use once one exists (Phase 7: OpsLabs Commission)."""
    try:
        new_balance = credits_lib.spend_for_feature(
            current_user.company_id, 'demo_action', reason='Dashboard demo action')
        db.session.commit()
        flash(f'Used 1 credit (demo). New balance: {new_balance}.', 'success')
    except credits_lib.InsufficientCredits:
        flash('Not enough credits — ask an admin to grant some, or subscribe to a plan with a credit allowance.', 'error')
    return redirect(url_for('auth.dashboard'))


@auth_bp.route('/profile', methods=['GET', 'POST'])
@login_required
def profile():
    if request.method == 'POST':
        new_password = request.form.get('new_password', '')
        company_name = request.form.get('company_name', '').strip()

        if company_name and current_user.has_company_role('owner', 'admin'):
            current_user.company.name = company_name

        if new_password:
            if len(new_password) < 8:
                flash('New password must be at least 8 characters.', 'error')
                return render_template('auth/profile.html')
            current_user.password_hash = generate_password_hash(new_password)

        db.session.commit()
        flash('Profile updated.', 'success')
        return redirect(url_for('auth.profile'))

    return render_template('auth/profile.html')


@auth_bp.route('/team/invite', methods=['POST'])
@login_required
def invite_member():
    if not current_user.has_company_role('owner', 'admin'):
        flash('Only company owners/admins can invite members.', 'error')
        return redirect(url_for('auth.dashboard'))

    email = request.form.get('email', '').strip().lower()
    role = request.form.get('role', 'member')
    if role not in ('admin', 'member'):
        role = 'member'

    if not email or '@' not in email:
        flash('Enter a valid email address.', 'error')
        return redirect(url_for('auth.dashboard'))

    invite = Invitation(
        company_id=current_user.company_id,
        email=email,
        role=role,
        invited_by_user_id=current_user.id,
    )
    db.session.add(invite)
    db.session.commit()

    # Email delivery isn't wired up yet in this phase — the inviter copies the link manually.
    invite_url = url_for('auth.accept_invite', token=invite.token, _external=True)
    flash(f'Invite created. Send this link to {email}: {invite_url}', 'success')
    return redirect(url_for('auth.dashboard'))


@auth_bp.route('/invite/<token>', methods=['GET', 'POST'])
def accept_invite(token):
    invite = Invitation.query.filter_by(token=token).first()
    if not invite or not invite.is_pending:
        flash('This invite link is invalid or has expired.', 'error')
        return redirect(url_for('auth.login'))

    if current_user.is_authenticated:
        flash('Log out first to accept a team invite with a new account.', 'error')
        return redirect(url_for('auth.dashboard'))

    if User.query.filter_by(email=invite.email).first():
        flash('An account already exists for this invite email — log in instead.', 'error')
        return redirect(url_for('auth.login'))

    if request.method == 'POST':
        password = request.form.get('password', '')
        if len(password) < 8:
            flash('Password must be at least 8 characters.', 'error')
            return render_template('auth/accept_invite.html', invite=invite)

        user = User(
            company_id=invite.company_id,
            email=invite.email,
            password_hash=generate_password_hash(password),
            role=invite.role,
        )
        db.session.add(user)
        invite.accepted_at = datetime.utcnow()
        db.session.commit()

        login_user(user)
        flash(f'Welcome to {invite.company.name}!', 'success')
        return redirect(url_for('auth.dashboard'))

    return render_template('auth/accept_invite.html', invite=invite)
