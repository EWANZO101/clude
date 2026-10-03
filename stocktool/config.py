import os
import sys
from datetime import timedelta

# Path to the stocktool-admin codebase. The kiosk imports its SQLAlchemy
# models, db session, and helper functions directly (see kiosk/__init__.py)
# rather than redefining them — that way the two apps can never drift into
# disagreeing about the schema. Only stocktool-admin/app/models/*.py is
# ever edited; the kiosk always reads through to whatever it currently says.
#
# Defaults to a sibling directory, i.e. stocktool-admin and stocktool-kiosk
# checked out next to each other:
#   /opt/stocktool/          (this is ADMIN_APP_PATH)
#   /opt/stocktool-kiosk/
# Override with the ADMIN_APP_PATH env var if deployed differently.
ADMIN_APP_PATH = os.environ.get(
    "ADMIN_APP_PATH",
    os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "stocktool"))
)
if ADMIN_APP_PATH not in sys.path:
    sys.path.insert(0, ADMIN_APP_PATH)


class Config:
    SECRET_KEY = os.environ.get("SECRET_KEY", "change-me-in-production")

    # Must point at the SAME .db file stocktool-admin uses — this is what
    # actually makes the two apps "share one database". Defaults to
    # stocktool-admin's own default location (instance/stocktool.db under
    # ADMIN_APP_PATH). Override with DATABASE_URL if either app's default
    # has been changed, and make sure both apps agree.
    SQLALCHEMY_DATABASE_URI = os.environ.get(
        "DATABASE_URL",
        f"sqlite:///{os.path.join(ADMIN_APP_PATH, 'instance', 'stocktool.db')}"
    )
    SQLALCHEMY_TRACK_MODIFICATIONS = False

    # Identifies this terminal in the audit log's `device` column — set a
    # distinct value per physical kiosk if you run more than one.
    KIOSK_NAME = os.environ.get("KIOSK_NAME", "kiosk-1")

    # Seconds of no scan/action before the kiosk drops back to the idle
    # "Scan your badge" screen.
    IDLE_TIMEOUT_SECONDS = int(os.environ.get("IDLE_TIMEOUT_SECONDS", 60))

    HOST = os.environ.get("HOST", "0.0.0.0")
    PORT = int(os.environ.get("PORT", 5050))

    PERMANENT_SESSION_LIFETIME = timedelta(hours=12)
    SESSION_COOKIE_HTTPONLY = True
    SESSION_COOKIE_SAMESITE = "Lax"

    APP_NAME = "StockTool Kiosk"
