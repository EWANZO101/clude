import json

from flask import Flask
from werkzeug.middleware.proxy_fix import ProxyFix

from .config import Config
from .extensions import db, migrate, login_manager


def create_app(config_class=Config):
    app = Flask(__name__)
    app.config.from_object(config_class)
    app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1, x_host=1)

    @app.template_filter('from_json')
    def from_json_filter(value):
        try:
            return json.loads(value)
        except (TypeError, ValueError):
            return []

    db.init_app(app)
    migrate.init_app(app, db)
    login_manager.init_app(app)
    login_manager.login_view = 'auth.login'

    from .models import User

    @login_manager.user_loader
    def load_user(user_id):
        return db.session.get(User, int(user_id))

    from .auth.routes import auth_bp
    from .admin.routes import admin_bp
    from .billing.routes import billing_bp
    from .domains.routes import domains_bp
    from .api.routes import api_bp
    app.register_blueprint(auth_bp)
    app.register_blueprint(admin_bp)
    app.register_blueprint(billing_bp)
    app.register_blueprint(domains_bp)
    app.register_blueprint(api_bp)

    @app.get('/')
    def index():
        from flask import redirect, url_for
        from flask_login import current_user
        if current_user.is_authenticated:
            return redirect(url_for('auth.dashboard'))
        return redirect(url_for('auth.login'))

    @app.cli.command('seed-admin')
    def seed_admin():
        """Create the first platform-admin user from PLATFORM_ADMIN_EMAIL/PASSWORD_HASH
        in .env, if one doesn't already exist. Run once after `flask db upgrade`."""
        from .models import Company, User

        email = app.config['PLATFORM_ADMIN_EMAIL']
        existing = User.query.filter_by(email=email).first()
        if existing:
            if not existing.is_platform_admin:
                existing.is_platform_admin = True
                db.session.commit()
                print(f'Granted platform-admin to existing user {email}.')
            else:
                print(f'{email} is already a platform admin — nothing to do.')
            return

        company = Company(name='OpsLabs Platform', is_personal=True)
        db.session.add(company)
        db.session.flush()

        user = User(
            company_id=company.id,
            email=email,
            password_hash=app.config['PLATFORM_ADMIN_PASSWORD_HASH'],
            role='owner',
            is_platform_admin=True,
        )
        db.session.add(user)
        db.session.flush()
        company.owner_user_id = user.id
        db.session.commit()
        print(f'Created platform-admin user {email}.')

    @app.cli.command('reconcile-credits')
    def reconcile_credits():
        """Safety net for missed/delayed Stripe renewal webhooks — see billing/reconcile.py.
        Meant to run periodically (opslabs-platform-reconcile.timer installs this hourly)."""
        from .billing.reconcile import reconcile
        reconcile(app.config['STRIPE_SECRET_KEY'])

    @app.cli.command('verify-domains')
    def verify_domains():
        """Polls every domain that isn't already active/failed and re-runs
        domains.verification.check() — the "verified twice in a row -> active"
        promotion needs this to run periodically even if nobody clicks the manual
        Verify button. Meant to run every few minutes (opslabs-platform-verify-domains.timer)."""
        from .models import Domain
        from .domains import verification
        from datetime import datetime

        pending = Domain.query.filter(Domain.status.in_(('pending', 'verified'))).all()
        if not pending:
            print('[verify-domains] Nothing pending.')
            return
        for domain in pending:
            new_status, reason = verification.check(domain)
            domain.status = new_status
            domain.failure_reason = reason
            if new_status == 'active' and not domain.verified_at:
                domain.verified_at = datetime.utcnow()
            db.session.commit()
            print(f'[verify-domains] {domain.hostname}: {new_status}'
                  + (f' ({reason})' if reason else ''))

    return app
