import logging
import os

from dotenv import load_dotenv

BASEDIR = os.path.abspath(os.path.dirname(__file__))
# inventory_ops/.env — one level up from this file, same convention as
# kiosk_app/app/config.py.
load_dotenv(os.path.join(BASEDIR, "..", ".env"))

_INSECURE_DEFAULT_SECRET_KEY = "dev-insecure-key-change-me"  # never use this outside a throwaway local copy


class Config:
    SECRET_KEY = os.environ.get("SECRET_KEY", _INSECURE_DEFAULT_SECRET_KEY)
    SQLALCHEMY_DATABASE_URI = os.environ.get(
        "DATABASE_URL", f"sqlite:///{os.path.join(BASEDIR, '..', 'inventory_ops.db')}"
    )
    SQLALCHEMY_TRACK_MODIFICATIONS = False

    SESSION_COOKIE_HTTPONLY = True
    SESSION_COOKIE_SAMESITE = "Lax"

    TENANT_NAME = os.environ.get("TENANT_NAME", "Inventory Ops")


if Config.SECRET_KEY == _INSECURE_DEFAULT_SECRET_KEY:
    # Loud on purpose — this key signs session cookies. Real fix: set
    # SECRET_KEY in inventory_ops/.env before this runs anywhere but a
    # throwaway local copy.
    logging.getLogger(__name__).warning(
        "SECRET_KEY is still the insecure built-in default — set a real one in "
        "inventory_ops/.env before this runs anywhere but a throwaway local copy."
    )
