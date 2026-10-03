import os
from datetime import timedelta


class Config:
    SECRET_KEY = os.environ.get("SECRET_KEY", "change-me-in-production")

    # Server-to-server: this Flask app's own backend code (adminapp/utils/api_client.py)
    # calls stocktool-api here for literally everything. There is no
    # SQLALCHEMY_DATABASE_URI in this codebase on purpose — this app never
    # touches a database directly.
    API_BASE_URL = os.environ.get("API_BASE_URL", "http://127.0.0.1:5035")

    # Browser-facing: barcode <img> tags load directly from the API (see
    # stocktool-api's /api/barcodes/image/<code>, which is deliberately
    # unauthenticated). Defaults to the same host as API_BASE_URL — override
    # this if the API is reachable from this server but not from users'
    # browsers under that same address (e.g. behind different reverse-proxy
    # paths, or API_BASE_URL pointing at an internal-only address).
    API_PUBLIC_URL = os.environ.get("API_PUBLIC_URL", API_BASE_URL)

    PERMANENT_SESSION_LIFETIME = timedelta(hours=8)
    SESSION_COOKIE_HTTPONLY = True
    SESSION_COOKIE_SAMESITE = "Lax"

    HOST = os.environ.get("HOST", "0.0.0.0")
    PORT = int(os.environ.get("PORT", 8000))

    APP_NAME = "StockTool"
    APP_VERSION = "2.0.0"
