import os
import logging

from flask import Flask
from flask_login import current_user

from config import Config
from app.extensions import db, login_manager, csrf, migrate, limiter


def create_app(config_class=Config):
    app = Flask(__name__)
    app.config.from_object(config_class)

    for folder in [app.config["UPLOAD_FOLDER"], app.config["BACKUP_FOLDER"],
                   app.config.get("MODULE_PACKAGE_FOLDER", ""), app.config["LOG_FOLDER"]]:
        if folder:
            os.makedirs(folder, exist_ok=True)

    db.init_app(app)
    login_manager.init_app(app)
    csrf.init_app(app)
    migrate.init_app(app, db)
    limiter.init_app(app)

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        handlers=[
            logging.FileHandler(os.path.join(app.config["LOG_FOLDER"], "app.log")),
            logging.StreamHandler(),
        ],
    )

    from app.core.auth.routes import auth_bp
    from app.core.dashboard.routes import dashboard_bp
    from app.core.notifications.routes import notifications_bp
    from app.core.search.routes import search_bp
    from app.core.audit.routes import audit_bp
    from app.core.health.routes import health_bp
    from app.core.modules.routes import modules_bp
    from app.core.backup.routes import backup_bp
    from app.core.export.routes import export_bp

    app.register_blueprint(auth_bp)
    app.register_blueprint(dashboard_bp)
    app.register_blueprint(notifications_bp)
    app.register_blueprint(search_bp)
    app.register_blueprint(audit_bp)
    app.register_blueprint(health_bp)
    app.register_blueprint(modules_bp)
    app.register_blueprint(backup_bp)
    app.register_blueprint(export_bp)

    from app.core.database import models  # noqa: F401
    from app.core.permissions import models as permission_models  # noqa: F401
    from app.core.events import models as event_models  # noqa: F401
    from app.core.notifications import models as notification_models  # noqa: F401
    from app.core.jobs import models as job_models  # noqa: F401
    from app.core.storage import models as storage_models  # noqa: F401
    from app.core.audit import models as audit_models  # noqa: F401
    from app.core.modules import models as module_models  # noqa: F401
    from app.core.backup import models as backup_models  # noqa: F401

    with app.app_context():
        from app.core.modules.loader import load_enabled_modules
        load_enabled_modules(app)

    @app.context_processor
    def inject_nav():
        from app.core.database.models import NavItem
        nav_items = []
        if current_user.is_authenticated:
            nav_items = NavItem.query.filter_by(enabled=True).order_by(NavItem.position).all()
        return {"nav_items": nav_items}

    @app.errorhandler(404)
    def not_found(e):
        from flask import render_template
        return render_template("errors/404.html"), 404

    @app.errorhandler(429)
    def rate_limited(e):
        from flask import render_template
        return render_template("errors/429.html", description=str(e.description)), 429

    @app.errorhandler(500)
    def server_error(e):
        from flask import render_template
        db.session.rollback()
        return render_template("errors/500.html"), 500

    @app.cli.command("init-db")
    def init_db():
        """Creates all core tables. Run this once before seed-nav / install-builtin-modules."""
        db.create_all()
        print("Database tables created.")

    @app.cli.command("seed-nav")
    def seed_nav():
        """Seed core navigation items (idempotent)."""
        from app.core.database.models import NavItem
        core_items = [
            ("Dashboard", "layout-dashboard", "/", 0),
            ("Notifications", "bell", "/notifications/", 80),
            ("Modules", "puzzle", "/modules/", 85),
            ("Backups", "archive", "/backups/", 87),
            ("Settings", "settings", "/settings/general", 90),
            ("System Health", "activity", "/system-health/", 95),
            ("Audit Log", "list", "/audit/", 96),
        ]
        for label, icon, url, position in core_items:
            existing = NavItem.query.filter_by(label=label, module_id=None).first()
            if not existing:
                db.session.add(NavItem(label=label, icon=icon, url=url, position=position, module_id=None))
        db.session.commit()
        print("Nav seeded.")

    @app.cli.command("install-builtin-modules")
    def install_builtin_modules():
        """Packages and installs the checklist + finance modules shipped in module_packages/."""
        import subprocess
        import sys as _sys
        from app.core.modules import loader as module_loader

        for module_id in ["checklist", "finance", "merchant", "fuel"]:
            source_dir = os.path.join(app.root_path, "..", "module_packages", module_id)
            dist_dir = os.path.join(app.root_path, "..", "dist")
            subprocess.run(
                [_sys.executable, os.path.join(app.root_path, "..", "scripts", "package_module.py"),
                 source_dir, dist_dir],
                check=True,
            )
            manifest_path = os.path.join(source_dir, "manifest.yaml")
            import yaml
            with open(manifest_path) as f:
                version = yaml.safe_load(f)["version"]
            zip_path = os.path.join(dist_dir, f"{module_id}-{version}.zip")
            record = module_loader.install_from_zip(zip_path, replace_existing=True)
            module_loader.enable(app, record.id)
            print(f"Installed and enabled: {module_id}")

    return app
