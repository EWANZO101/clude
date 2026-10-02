from flask import Flask
from config import Config

# ── Reused directly from stocktool-admin (see config.py — it puts that
#    codebase on sys.path) ────────────────────────────────────────────────
# This is the point of the "shared DB, no HTTP hop" choice: one set of
# SQLAlchemy model definitions, imported here rather than copy-pasted, so
# there is nothing to keep in sync by hand.
from app.extensions import db  # noqa: E402


def create_app(config_class=Config) -> Flask:
    kiosk_app = Flask(__name__)
    kiosk_app.config.from_object(config_class)

    db.init_app(kiosk_app)

    from kiosk.routes import kiosk_bp
    kiosk_app.register_blueprint(kiosk_bp)

    @kiosk_app.after_request
    def set_security_headers(response):
        response.headers.setdefault("X-Content-Type-Options", "nosniff")
        response.headers.setdefault("X-Frame-Options", "DENY")
        return response

    if not kiosk_app.debug and not kiosk_app.testing:
        if kiosk_app.config.get("SECRET_KEY") == "change-me-in-production":
            kiosk_app.logger.warning(
                "SECRET_KEY is set to the insecure default. Set the SECRET_KEY "
                "environment variable before exposing this app on a network."
            )

    return kiosk_app
