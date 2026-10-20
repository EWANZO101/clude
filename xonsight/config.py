import os
from datetime import timedelta


class Config:
    SECRET_KEY = os.environ.get("SECRET_KEY", "dev-secret-change-me")
    SQLALCHEMY_DATABASE_URI = os.environ.get("DATABASE_URL", "")
    SQLALCHEMY_TRACK_MODIFICATIONS = False
    XONSIGHT_WEBHOOK_KEY = os.environ.get("XONSIGHT_WEBHOOK_KEY", "")
    RECORDER_STALE_SECONDS = int(os.environ.get("RECORDER_STALE_SECONDS", "30"))

    # Session cookie hardening. SECURE requires the app always be served over https - true here (nginx +
    # Let's Encrypt in front) - browsers simply won't send the cookie over a plain http connection once this
    # is on, so don't enable it if you ever access this deployment without TLS in front.
    SESSION_COOKIE_SECURE = True
    SESSION_COOKIE_HTTPONLY = True
    SESSION_COOKIE_SAMESITE = "Lax"
    PERMANENT_SESSION_LIFETIME = timedelta(days=14)

    # CSRF (Flask-WTF, xonsight/extensions.py). None = tokens stay valid for the life of the session instead of
    # expiring after Flask-WTF's 1-hour default - a stale background tab shouldn't suddenly fail to submit.
    WTF_CSRF_TIME_LIMIT = None

    # Shown in metadata overlays burned onto the evidence viewer and passed
    # to AI-generated drafts/briefs. Set this - the default is a visible
    # placeholder, not a real agency name.
    AGENCY_NAME = os.environ.get("AGENCY_NAME", "Unconfigured Agency")

    # Draft One / Brief One / Axon Assistant analogs (xonsight/ai.py) need
    # this to do anything - without it they report "not configured" instead
    # of erroring. Get a key at https://console.anthropic.com/.
    ANTHROPIC_API_KEY = os.environ.get("ANTHROPIC_API_KEY", "")
    AI_MODEL = os.environ.get("AI_MODEL", "claude-opus-5")

    # Caps request bodies - mainly relevant to the public Community Request
    # upload form (xonsight/community.py), the only place this app accepts
    # a file from an unauthenticated visitor.
    MAX_CONTENT_LENGTH = 200 * 1024 * 1024

    # Flask-Limiter backend. In-memory is fine for this app's single-process
    # dev-server deployment; if you move to multi-worker gunicorn, point
    # this at a shared backend (e.g. redis://...) or per-worker counts will
    # under-count the real request rate.
    RATELIMIT_STORAGE_URI = os.environ.get("RATELIMIT_STORAGE_URI", "memory://")

    # Optional - enables a real hCaptcha widget on the public Community
    # Request submission form (get free keys at https://www.hcaptcha.com/).
    # Leave blank and the form falls back to a built-in math challenge, so
    # there's still some bot resistance with zero external signup.
    HCAPTCHA_SITE_KEY = os.environ.get("HCAPTCHA_SITE_KEY", "")
    HCAPTCHA_SECRET_KEY = os.environ.get("HCAPTCHA_SECRET_KEY", "")

    # Used to build clickable links in Discord notifications (xonsight/discord.py).
    # No trailing slash, e.g. https://xonsight.opslabsystems.cloud
    PORTAL_PUBLIC_URL = os.environ.get("PORTAL_PUBLIC_URL", "")

    # Multi-tenancy (xonsight/tenancy.py) - a scoped MySQL account that can only create/manage
    # xonsight_* databases, used to provision one dedicated MySQL database per community. Blank
    # password disables community creation (clear error instead of a broken attempt).
    MYSQL_PROVISIONER_HOST = os.environ.get("MYSQL_PROVISIONER_HOST", "127.0.0.1")
    MYSQL_PROVISIONER_PORT = int(os.environ.get("MYSQL_PROVISIONER_PORT", "3306"))
    MYSQL_PROVISIONER_USER = os.environ.get("MYSQL_PROVISIONER_USER", "xonsight_provisioner")
    MYSQL_PROVISIONER_PASSWORD = os.environ.get("MYSQL_PROVISIONER_PASSWORD", "")

    # Host-header tenant resolution (xonsight/tenant_resolve.py). A request to
    # "<slug>.<TENANT_BASE_DOMAIN>" resolves to that Community; anything else
    # (including the main PORTAL_PUBLIC_URL host) stays control-plane-only.
    # No wildcard DNS record exists for this yet - resolution is exercised
    # today via `curl -H "Host: <slug>.opslabsystems.cloud"`, not real traffic.
    TENANT_BASE_DOMAIN = os.environ.get("TENANT_BASE_DOMAIN", "opslabsystems.cloud")
