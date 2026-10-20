import os

from flask import Flask
from werkzeug.middleware.proxy_fix import ProxyFix

from .config import Config
from .extensions import csrf, db, limiter, login_manager


def create_app():
    app = Flask(__name__, instance_relative_config=True)
    app.config.from_object(Config)

    # This app sits behind nginx (1 hop), which sets X-Forwarded-For/-Proto.
    # Without this, request.remote_addr is always nginx's own IP for every
    # visitor - which would make Flask-Limiter's per-IP rate limit on the
    # Community Request form apply to all visitors collectively instead of
    # individually.
    app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1, x_host=1)

    if not app.config["SQLALCHEMY_DATABASE_URI"]:
        os.makedirs(app.instance_path, exist_ok=True)
        db_path = os.path.join(app.instance_path, "xonsight.db")
        app.config["SQLALCHEMY_DATABASE_URI"] = f"sqlite:///{db_path}"

    db.init_app(app)
    login_manager.init_app(app)
    login_manager.login_view = "auth.login"
    limiter.init_app(app)
    csrf.init_app(app)

    from . import models, tenancy  # noqa: F401
    from .admin import admin_bp
    from .api import api_bp
    from .auth import auth_bp
    from .community import community_bp
    from .migrations import run_light_migrations
    from .models import User
    from .seed import run_seed
    from .site import site_bp
    from .tenant_resolve import resolve_tenant
    from .views import views_bp
    from .webhooks import webhooks_bp

    @login_manager.user_loader
    def load_user(user_id):
        return User.query.get(int(user_id))

    app.teardown_appcontext(tenancy.remove_all_sessions)
    app.before_request(resolve_tenant)

    # Keyed/tokened machine-to-machine auth (X-XonSight-Key / X-XonSight-Token), not session cookies - CSRF
    # protection doesn't apply (there's no ambient browser credential being ridden) and would just break every
    # FiveM resource that posts here, since they have no session/CSRF token to send.
    csrf.exempt(webhooks_bp)

    app.register_blueprint(webhooks_bp)
    app.register_blueprint(api_bp)
    app.register_blueprint(auth_bp)
    app.register_blueprint(admin_bp)
    app.register_blueprint(site_bp)
    app.register_blueprint(community_bp)
    app.register_blueprint(views_bp)

    with app.app_context():
        run_light_migrations()
        db.create_all()
        run_seed()

    return app
