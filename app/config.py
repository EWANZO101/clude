import os
from datetime import timedelta

BASE_DIR = os.path.abspath(os.path.dirname(os.path.dirname(__file__)))


def _resolve_db_uri():
    raw = os.environ.get("DATABASE_URL")
    if not raw:
        return f"sqlite:///{os.path.join(BASE_DIR, 'instance', 'app.db')}"

    # Only sqlite relative paths need fixing — postgres/mysql URLs pass through untouched.
    if raw.startswith("sqlite:///") and not raw.startswith("sqlite:////"):
        rel_path = raw[len("sqlite:///"):]
        if not os.path.isabs(rel_path):
            abs_path = os.path.join(BASE_DIR, rel_path)
            return f"sqlite:///{abs_path}"
    return raw


def _resolve_dir(env_var, default_rel):
    raw = os.environ.get(env_var, default_rel)
    if os.path.isabs(raw):
        return raw
    return os.path.join(BASE_DIR, raw)


class Config:
    SECRET_KEY = os.environ.get("SECRET_KEY", "change-me-in-env")
    SQLALCHEMY_DATABASE_URI = _resolve_db_uri()
    SQLALCHEMY_TRACK_MODIFICATIONS = False

    EXPORTS_DIR = _resolve_dir("EXPORTS_DIR", os.path.join("instance", "exports"))
    UPLOADS_DIR = _resolve_dir("UPLOADS_DIR", os.path.join("instance", "uploads"))
    MAX_CONTENT_LENGTH = 1024 * 1024 * 1024 * 4  # 4GB uploads

    TEMP_ACCOUNT_LIFETIME = timedelta(hours=12)

    SESSION_COOKIE_HTTPONLY = True
    SESSION_COOKIE_SAMESITE = "Lax"
    REMEMBER_COOKIE_DURATION = timedelta(days=14)

    WTF_CSRF_ENABLED = True

    MAIL_SERVER = os.environ.get("MAIL_SERVER", "")
    MAIL_PORT = int(os.environ.get("MAIL_PORT", 587))
    MAIL_USE_TLS = os.environ.get("MAIL_USE_TLS", "true").lower() == "true"
    MAIL_USERNAME = os.environ.get("MAIL_USERNAME", "")
    MAIL_PASSWORD = os.environ.get("MAIL_PASSWORD", "")
    MAIL_DEFAULT_SENDER = os.environ.get("MAIL_DEFAULT_SENDER", "no-reply@example.com")

    RATELIMIT_STORAGE_URI = os.environ.get("RATELIMIT_STORAGE_URI", "memory://")


class DevConfig(Config):
    DEBUG = True


class ProdConfig(Config):
    DEBUG = False
    SESSION_COOKIE_SECURE = True
