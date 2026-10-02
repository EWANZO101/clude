from datetime import datetime, timezone

from flask import Flask, jsonify, render_template

from app.config import Config
from app.extensions import db, login_manager
from app import version


def create_app(config_class=Config):
    app = Flask(__name__)
    app.config.from_object(config_class)

    db.init_app(app)
    login_manager.init_app(app)

    from app.models import LocalUser

    @login_manager.user_loader
    def load_user(user_id):
        return LocalUser.query.get(int(user_id))

    from app.blueprints.auth import bp as auth_bp
    from app.blueprints.dashboard import bp as dashboard_bp
    from app.blueprints.inventory import bp as inventory_bp
    from app.blueprints.settings import bp as settings_bp

    app.register_blueprint(auth_bp)
    app.register_blueprint(dashboard_bp)
    app.register_blueprint(inventory_bp)
    app.register_blueprint(settings_bp)

    @app.route("/health")
    def health():
        try:
            db.session.execute(db.text("SELECT 1"))
            db_ok = True
        except Exception:
            db_ok = False
        status = "ok" if db_ok else "degraded"
        code = 200 if db_ok else 503
        return jsonify({"status": status, "version": version.VERSION, "database": "ok" if db_ok else "unreachable"}), code

    @app.errorhandler(403)
    def forbidden(e):
        return render_template("errors/403.html"), 403

    from app.cli import register_cli
    register_cli(app)

    @app.context_processor
    def inject_globals():
        from flask_login import current_user
        from app.models import ItemType, Settings

        settings = Settings.get()
        item_types = ItemType.query.filter_by(deleted_at=None).order_by(ItemType.name).all()
        is_admin = (not settings.auth_enabled) or (
            current_user.is_authenticated and current_user.role == "admin"
        )
        return {
            "tenant_name": settings.tenant_name,
            "app_settings": settings,
            "sidebar_item_types": item_types,
            "is_admin": is_admin,
            "app_version": version.VERSION,
            "app_released": version.RELEASED,
            "current_year": datetime.now(timezone.utc).year,
        }

    return app
