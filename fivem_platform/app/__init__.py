import os
from flask import Flask

from app.config import config_map
from app.extensions import db, migrate, login_manager, limiter, csrf, init_redis


def create_app(config_name="default"):
    app = Flask(__name__)
    app.config.from_object(config_map[config_name])

    db.init_app(app)
    migrate.init_app(app, db)
    login_manager.init_app(app)
    limiter.init_app(app)
    csrf.init_app(app)
    init_redis(app)

    os.makedirs(app.config["UPLOAD_FOLDER"], exist_ok=True)

    login_manager.login_view = "auth.login"
    login_manager.login_message = "Please log in to continue."
    login_manager.login_message_category = "info"

    from app.models.user import User

    @login_manager.user_loader
    def load_user(user_id):
        return User.query.get(int(user_id))

    from app.auth import auth_bp
    from app.dashboard import dashboard_bp
    from app.developer import developer_bp
    from app.api import api_bp
    from app.cloudloader import cloudloader_bp
    from app.portal import portal_bp
    from app.admin import admin_bp
    from app.marketplace import marketplace_bp
    from app.docs import docs_bp

    app.register_blueprint(auth_bp, url_prefix="/auth")
    app.register_blueprint(dashboard_bp)
    app.register_blueprint(developer_bp)
    app.register_blueprint(api_bp)
    app.register_blueprint(cloudloader_bp)
    app.register_blueprint(portal_bp)
    app.register_blueprint(admin_bp)
    app.register_blueprint(marketplace_bp)
    app.register_blueprint(docs_bp)

    # /api/* is called by CloudLoader, Tebex webhooks, and external
    # integrations - none of them are browser sessions with a CSRF
    # cookie to send a token from. They authenticate with explicit
    # credentials (api_key/secret_key/server_token) in the JSON body,
    # which isn't the "ambient credential" CSRF protects against in the
    # first place. Enforcing tokens here would break every real
    # integration without adding any actual protection.
    csrf.exempt(api_bp)

    return app
