import os
from datetime import timedelta

BASE_DIR = os.path.abspath(os.path.dirname(__file__))


class Config:
    # ── Core ──────────────────────────────────────────────────────────────────
    SECRET_KEY = os.environ.get("SECRET_KEY", "change-me-in-production")

    # ── Database — this app is the ONLY one that connects to it ────────────────
    SQLALCHEMY_DATABASE_URI = os.environ.get(
        "DATABASE_URL",
        f"sqlite:///{os.path.join(BASE_DIR, 'instance', 'stocktool.db')}"
    )
    SQLALCHEMY_TRACK_MODIFICATIONS = False

    # ── JWT (API auth — used by the admin frontend and, for badge logins, by
    #    the kiosk touch-UI's own fetch() calls too) ────────────────────────────
    JWT_SECRET_KEY = os.environ.get("JWT_SECRET_KEY", "jwt-change-me-in-production")
    JWT_ACCESS_TOKEN_EXPIRES = timedelta(hours=8)
    JWT_TOKEN_LOCATION = ["headers"]
    JWT_HEADER_NAME = "Authorization"
    JWT_HEADER_TYPE = "Bearer"

    # Badge-scan logins get a much shorter-lived token than a normal
    # username/password login.
    KIOSK_TOKEN_EXPIRES = timedelta(minutes=15)

    # ── Barcodes ──────────────────────────────────────────────────────────────
    BARCODE_OUTPUT_DIR = os.path.join(BASE_DIR, "static", "barcodes")

    # ── Kiosk touch-UI session (this app also serves the kiosk screens
    #    directly, using a plain server-side cookie session — separate
    #    concern from the JWT-based REST API) ──────────────────────────────────
    KIOSK_NAME = os.environ.get("KIOSK_NAME", "kiosk-1")
    PERMANENT_SESSION_LIFETIME = timedelta(hours=12)
    SESSION_COOKIE_HTTPONLY = True
    SESSION_COOKIE_SAMESITE = "Lax"

    # ── Server ────────────────────────────────────────────────────────────────
    HOST = os.environ.get("HOST", "0.0.0.0")
    PORT = int(os.environ.get("PORT", 5000))

    APP_NAME = "StockTool API"
    APP_VERSION = "2.0.0"
