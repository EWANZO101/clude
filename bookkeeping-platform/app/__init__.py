import os
from flask import Flask
from app.config import config
from app.extensions import db, migrate, login_manager, csrf


def create_app(config_name=None):
    config_name = config_name or os.environ.get("FLASK_CONFIG", "development")
    app = Flask(__name__, instance_relative_config=True)
    app.config.from_object(config[config_name])

    os.makedirs(app.instance_path, exist_ok=True)

    db.init_app(app)
    migrate.init_app(app, db)
    login_manager.init_app(app)
    csrf.init_app(app)

    from app.models import user, business, accounting, party, invoice, bill, expense, document, audit, backup, integrity, integration, banking, invitation, notification, recurring  # noqa: F401 register models

    from app.auth.routes import auth_bp
    from app.businesses.routes import businesses_bp
    from app.accounting.routes import accounting_bp
    from app.dashboard.routes import dashboard_bp
    from app.customers.routes import customers_bp
    from app.suppliers.routes import suppliers_bp
    from app.invoices.routes import invoices_bp
    from app.expenses.routes import expenses_bp
    from app.bills.routes import bills_bp
    from app.documents.routes import documents_bp
    from app.audit.routes import audit_bp
    from app.backups.routes import backups_bp
    from app.admin.routes import admin_bp
    from app.sync.routes import sync_bp
    from app.pwa.routes import pwa_bp
    from app.integrations.routes import integrations_bp
    from app.export.routes import export_bp
    from app.search.routes import search_bp
    from app.notifications.routes import notifications_bp
    from app.recurring.routes import recurring_bp

    app.register_blueprint(auth_bp, url_prefix="/auth")
    app.register_blueprint(businesses_bp, url_prefix="/businesses")
    app.register_blueprint(accounting_bp, url_prefix="/accounting")
    app.register_blueprint(dashboard_bp)
    app.register_blueprint(customers_bp, url_prefix="/customers")
    app.register_blueprint(suppliers_bp, url_prefix="/suppliers")
    app.register_blueprint(invoices_bp, url_prefix="/invoices")
    app.register_blueprint(expenses_bp, url_prefix="/expenses")
    app.register_blueprint(bills_bp, url_prefix="/bills")
    app.register_blueprint(documents_bp, url_prefix="/documents")
    app.register_blueprint(audit_bp, url_prefix="/audit")
    app.register_blueprint(backups_bp, url_prefix="/backups")
    app.register_blueprint(admin_bp, url_prefix="/admin")
    app.register_blueprint(sync_bp, url_prefix="/sync")
    app.register_blueprint(pwa_bp)
    app.register_blueprint(integrations_bp, url_prefix="/integrations")
    app.register_blueprint(export_bp, url_prefix="/export")
    app.register_blueprint(search_bp, url_prefix="/search")
    app.register_blueprint(notifications_bp, url_prefix="/notifications")
    app.register_blueprint(recurring_bp, url_prefix="/recurring")

    @app.context_processor
    def inject_globals():
        from flask_login import current_user
        from app.models.business import Business
        current_business = None
        businesses = []
        if current_user.is_authenticated:
            businesses = current_user.businesses()
            current_business = current_user.current_business()
        unread_count = 0
        if current_user.is_authenticated:
            from app.models.notification import Notification
            unread_count = Notification.query.filter_by(user_id=current_user.id, is_read=False).count()
        return dict(current_business=current_business, user_businesses=businesses, unread_notification_count=unread_count)

    @app.errorhandler(404)
    def not_found(e):
        from flask import render_template
        return render_template("errors/404.html"), 404

    @app.errorhandler(500)
    def server_error(e):
        from flask import render_template
        db.session.rollback()
        return render_template("errors/500.html"), 500

    # Safety net: if the configured database has no tables yet (fresh
    # install, wiped file, container with an empty volume, ...), create
    # them now instead of 500ing on the first request. create_all() only
    # adds missing tables — it never alters or drops ones that already
    # exist, so this can't clobber real data or fight with `flask db
    # upgrade`. Set AUTO_CREATE_TABLES=false to disable if you want
    # migrations to be the ONLY way schema changes happen.
    if app.config.get("AUTO_CREATE_TABLES", True):
        with app.app_context():
            db.create_all()

    if app.config.get("ENABLE_SCHEDULER"):
        from app.backups.scheduler import start_scheduler
        start_scheduler(app)

    return app
