import os
import logging
from dotenv import load_dotenv

load_dotenv()

basedir = os.path.abspath(os.path.dirname(__file__))

logger = logging.getLogger(__name__)


class Config:
    SECRET_KEY = os.environ.get("SECRET_KEY", "dev-secret-change-me")

    # DATABASE_URL examples:
    #   SQLite (local dev only):  sqlite:///app.db
    #   MySQL:    mysql+pymysql://user:password@localhost/platform?charset=utf8mb4
    #   Postgres: postgresql+psycopg2://user:password@localhost/platform
    #
    # For any real/public deployment, point this at a real database server
    # (MySQL or Postgres), not the SQLite default. A file-based SQLite
    # database lives inside this app's own directory tree, so if your
    # deploy process ever replaces that directory (fresh git clone, a new
    # release folder, re-extracting a zip into a new path) the "database"
    # effectively resets — a real DB server is a separate, persistent
    # process your app just connects to over the network, so redeploying
    # the app's code can never touch its data.
    SQLALCHEMY_DATABASE_URI = os.environ.get(
        "DATABASE_URL", "sqlite:///" + os.path.join(basedir, "app.db")
    )
    if SQLALCHEMY_DATABASE_URI.startswith("sqlite") and os.environ.get("FLASK_ENV") == "production":
        logger.warning(
            "Running with FLASK_ENV=production but DATABASE_URL is unset (defaulting to SQLite). "
            "For a public deployment, set DATABASE_URL to a real MySQL/Postgres server — "
            "see .env.example and README.md 'Moving to a real database' section."
        )

    SQLALCHEMY_TRACK_MODIFICATIONS = False
    UPLOAD_FOLDER = os.path.join(basedir, "uploads")
    BACKUP_FOLDER = os.path.join(basedir, "backups")
    MODULE_PACKAGE_FOLDER = os.path.join(basedir, "module_packages")
    LOG_FOLDER = os.path.join(basedir, "logs")
    MAX_CONTENT_LENGTH = 25 * 1024 * 1024
    SESSION_COOKIE_HTTPONLY = True
    SESSION_COOKIE_SAMESITE = "Lax"
    # This app is only ever served over HTTPS in production (nginx terminates
    # TLS in front of it) — Secure=True stops the session cookie from ever
    # being sent over a plain-http connection. Off for local dev, where
    # FLASK_ENV isn't "production" and there's no HTTPS to require.
    SESSION_COOKIE_SECURE = os.environ.get("FLASK_ENV") == "production"
    WTF_CSRF_ENABLED = True
