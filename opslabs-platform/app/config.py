import os


class Config:
    SECRET_KEY = os.environ['FLASK_SECRET_KEY']
    SQLALCHEMY_DATABASE_URI = os.environ['DATABASE_URL']
    SQLALCHEMY_TRACK_MODIFICATIONS = False

    SESSION_COOKIE_SECURE = os.environ.get('SESSION_COOKIE_SECURE', '1') == '1'
    SESSION_COOKIE_HTTPONLY = True
    SESSION_COOKIE_SAMESITE = 'Lax'

    PLATFORM_ADMIN_EMAIL = os.environ['PLATFORM_ADMIN_EMAIL']
    PLATFORM_ADMIN_PASSWORD_HASH = os.environ['PLATFORM_ADMIN_PASSWORD_HASH']

    # Optional (not `os.environ[...]`, deliberately) — the app must keep running while
    # billing isn't configured yet; routes that need it check stripe_configured() first.
    STRIPE_SECRET_KEY = os.environ.get('STRIPE_SECRET_KEY', '')
    STRIPE_WEBHOOK_SECRET = os.environ.get('STRIPE_WEBHOOK_SECRET', '')

    # Same pattern for custom domains — routes check domains_configured() first.
    CLOUDFLARE_API_TOKEN = os.environ.get('CLOUDFLARE_API_TOKEN', '')
    CLOUDFLARE_ZONE_ID = os.environ.get('CLOUDFLARE_ZONE_ID', '')
    # The hostname customers CNAME to — your platform's edge, e.g. "edge.opslabsystems.cloud".
    CUSTOM_DOMAIN_CNAME_TARGET = os.environ.get('CUSTOM_DOMAIN_CNAME_TARGET', '')
