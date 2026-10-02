import logging
import os
from dotenv import load_dotenv

BASEDIR = os.path.abspath(os.path.dirname(__file__))
load_dotenv(os.path.join(BASEDIR, ".env"))

_INSECURE_DEFAULT_SECRET_KEY = "dev-insecure-key-change-me"  # never use this outside a throwaway local copy


class Config:
    SECRET_KEY = os.environ.get("SECRET_KEY", _INSECURE_DEFAULT_SECRET_KEY)
    SQLALCHEMY_DATABASE_URI = os.environ.get(
        "DATABASE_URL", f"sqlite:///{os.path.join(BASEDIR, 'admin_panel.db')}"
    )
    SQLALCHEMY_TRACK_MODIFICATIONS = False

    MAIL_SERVER = os.environ.get("MAIL_SERVER", "")
    MAIL_PORT = int(os.environ.get("MAIL_PORT", 587))
    MAIL_USE_TLS = os.environ.get("MAIL_USE_TLS", "1") == "1"
    MAIL_USERNAME = os.environ.get("MAIL_USERNAME", "")
    MAIL_PASSWORD = os.environ.get("MAIL_PASSWORD", "")
    MAIL_DEFAULT_SENDER = os.environ.get("MAIL_DEFAULT_SENDER", "noreply@opslabsystems.cloud")

    REQUIRE_EMAIL_VERIFICATION = os.environ.get("REQUIRE_EMAIL_VERIFICATION", "1") == "1"
    BASE_URL = os.environ.get("BASE_URL", "https://kiosksys.opslabsystems.cloud")

    # Token expiry (seconds)
    EMAIL_VERIFY_MAX_AGE = 60 * 60 * 24  # 24h
    PASSWORD_RESET_MAX_AGE = 60 * 60  # 1h

    # Update package storage (Part 4) — on-disk, outside the DB/repo.
    UPDATE_PACKAGE_DIR = os.environ.get(
        "UPDATE_PACKAGE_DIR", os.path.join(BASEDIR, "data", "update_packages")
    )
    # Instance backup storage (see app/models.py's InstanceBackup) — one
    # subfolder per instance, same on-disk-outside-the-DB convention as
    # update packages above.
    INSTANCE_BACKUP_DIR = os.environ.get(
        "INSTANCE_BACKUP_DIR", os.path.join(BASEDIR, "data", "instance_backups")
    )
    MAX_CONTENT_LENGTH = 1024 * 1024 * 1024  # 1GB upload cap

    # Session cookie hardening
    SESSION_COOKIE_HTTPONLY = True
    SESSION_COOKIE_SAMESITE = "Lax"
    REMEMBER_COOKIE_DURATION = 60 * 60 * 24 * 14

    # Explicit, not left to follow app.debug (which just went False as
    # part of closing the exposed-debugger finding below) — this is what
    # actually makes an edited .html show up on the next request without
    # a full process restart; the OWNERSHIP.md "edits take effect
    # immediately" workflow depends on it independently of use_debugger.
    TEMPLATES_AUTO_RELOAD = True


if Config.SECRET_KEY == _INSECURE_DEFAULT_SECRET_KEY:
    # Loud on purpose — this key signs every session cookie. Anyone who's
    # ever seen this source (and it's been zipped/shared repeatedly per
    # this project's own progress notes) can forge a valid session for
    # any account, including a platform admin, if a real deploy ever runs
    # with the fallback still in place. Real fix: set SECRET_KEY in .env
    # (this file already loads one at BASEDIR/.env above).
    logging.getLogger(__name__).warning(
        "SECRET_KEY is still the insecure built-in default — set a real one in "
        ".env before this runs anywhere but a throwaway local copy."
    )
