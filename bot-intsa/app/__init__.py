from dotenv import load_dotenv
from flask import Flask, redirect, request, session, url_for
from werkzeug.middleware.proxy_fix import ProxyFix

from .extensions import db


def create_app():
    load_dotenv()

    app = Flask(__name__)
    app.config.from_object("config.Config")
    app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1, x_host=1)

    db.init_app(app)

    from .routes.auth import bp as auth_bp
    from .routes.dashboard import bp as dashboard_bp
    from .routes.onboarding import bp as onboarding_bp
    from .routes.brand import bp as brand_bp
    from .routes.content import bp as content_bp
    from .routes.accounts import bp as accounts_bp
    from .routes.agent import bp as agent_bp

    app.register_blueprint(auth_bp)
    app.register_blueprint(dashboard_bp)
    app.register_blueprint(onboarding_bp)
    app.register_blueprint(brand_bp)
    app.register_blueprint(content_bp)
    app.register_blueprint(accounts_bp)
    app.register_blueprint(agent_bp)

    @app.before_request
    def require_login():
        if request.endpoint in (None, "auth.login", "auth.logout", "static"):
            return
        if not session.get("authenticated"):
            return redirect(url_for("auth.login", next=request.path))

    with app.app_context():
        from . import models  # noqa: F401

        db.create_all()

    @app.context_processor
    def inject_globals():
        from .models import Brand, SocialAccount

        brand = Brand.query.order_by(Brand.id.desc()).first()
        ig = SocialAccount.query.filter_by(platform="instagram").first()
        return {
            "current_brand": brand,
            "ig_status": "connected" if (ig and ig.connected) else ("pending" if ig else None),
        }

    return app
