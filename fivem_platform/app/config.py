import os
from datetime import timedelta

basedir = os.path.abspath(os.path.dirname(os.path.dirname(__file__)))


class Config:
    SECRET_KEY = os.environ.get("SECRET_KEY", "dev-key-change-me")

    SQLALCHEMY_DATABASE_URI = os.environ.get(
        "DATABASE_URL", f"sqlite:///{os.path.join(basedir, 'platform.db')}"
    )
    SQLALCHEMY_TRACK_MODIFICATIONS = False
    SQLALCHEMY_ENGINE_OPTIONS = {"pool_pre_ping": True}

    REDIS_URL = os.environ.get("REDIS_URL", "redis://localhost:6379/0")

    # Where protected script builds are stored. Swap for real object storage
    # (S3-compatible) later by changing how app/developer/routes.py reads
    # and writes files - the DB only stores a relative path either way.
    UPLOAD_FOLDER = os.environ.get(
        "UPLOAD_FOLDER", os.path.join(basedir, "instance", "uploads")
    )
    MAX_CONTENT_LENGTH = 60 * 1024 * 1024  # 60MB hard cap at the Flask level

    SITE_NAME = os.environ.get("SITE_NAME", "CloudLoader Platform")
    SITE_URL = os.environ.get("SITE_URL", "http://localhost:5000").rstrip("/")

    MAIL_SERVER = os.environ.get("MAIL_SERVER")
    MAIL_PORT = int(os.environ.get("MAIL_PORT", 587))
    MAIL_USE_TLS = os.environ.get("MAIL_USE_TLS", "True") == "True"
    MAIL_USERNAME = os.environ.get("MAIL_USERNAME")
    MAIL_PASSWORD = os.environ.get("MAIL_PASSWORD")
    MAIL_DEFAULT_SENDER = os.environ.get("MAIL_DEFAULT_SENDER")

    # Session / cookies
    SESSION_COOKIE_HTTPONLY = True
    SESSION_COOKIE_SAMESITE = "Lax"
    PERMANENT_SESSION_LIFETIME = timedelta(days=14)

    # Password reset token expiry (seconds)
    RESET_TOKEN_MAX_AGE = 3600

    # Rate limiting defaults. If Redis is unreachable, fail OPEN (allow the
    # request) instead of 500ing the whole site - swappable_storage below
    # handles the actual fallback logic.
    RATELIMIT_DEFAULT = "200 per hour"
    RATELIMIT_STORAGE_URI = REDIS_URL
    RATELIMIT_SWALLOW_ERRORS = True  # don't crash requests if the limiter backend errors
    RATELIMIT_IN_MEMORY_FALLBACK_ENABLED = True
    RATELIMIT_IN_MEMORY_FALLBACK = "200 per hour"


class DevelopmentConfig(Config):
    DEBUG = True


class ProductionConfig(Config):
    DEBUG = False
    SESSION_COOKIE_SECURE = True


config_map = {
    "development": DevelopmentConfig,
    "production": ProductionConfig,
    "default": DevelopmentConfig,
}
