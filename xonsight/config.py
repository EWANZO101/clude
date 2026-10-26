import os
from datetime import timedelta


class Config:
    SECRET_KEY = os.environ.get("SECRET_KEY", "dev-secret-change-me")
    SQLALCHEMY_DATABASE_URI = os.environ.get("DATABASE_URL", "")
    SQLALCHEMY_TRACK_MODIFICATIONS = False
    RECORDER_STALE_SECONDS = int(os.environ.get("RECORDER_STALE_SECONDS", "30"))

    # Live video (MediaMTX) - xonsight/webhooks.py's /live/* endpoints and
    # the mediamtx/auth external-auth webhook, xonsight/api.py's
    # list_live_streams. A row goes stale (hidden from /live, though not
    # deleted - FiveM's own heartbeat thread is what normally removes it)
    # after this many seconds without a heartbeat.
    LIVE_STREAM_STALE_SECONDS = int(os.environ.get("LIVE_STREAM_STALE_SECONDS", "20"))
    # Public base URLs MediaMTX is reachable on, no trailing slash. WebRTC
    # (WHEP) is the low-latency path the live.html player actually uses;
    # HLS is kept as a fallback for a browser/network WebRTC can't reach.
    # Blank disables the Live video panel entirely (recorders/positions on
    # the map still work either way - this only gates actual video).
    MEDIAMTX_WHEP_URL = os.environ.get("MEDIAMTX_WHEP_URL", "")
    MEDIAMTX_HLS_URL = os.environ.get("MEDIAMTX_HLS_URL", "")
    # How long a signed viewer token (query string on the WHEP/HLS URLs
    # handed to the browser) stays valid for - long enough to cover a
    # player sitting on /live mid-stream, short enough that a copied link
    # stops working soon after.
    LIVE_VIEWER_TOKEN_SECONDS = int(os.environ.get("LIVE_VIEWER_TOKEN_SECONDS", "21600"))

    # Session cookie hardening. SECURE requires the app always be served over https - true here (nginx +
    # Let's Encrypt in front) - browsers simply won't send the cookie over a plain http connection once this
    # is on, so don't enable it if you ever access this deployment without TLS in front.
    SESSION_COOKIE_SECURE = True
    SESSION_COOKIE_HTTPONLY = True
    # "None" (not "Lax") - xonsight-tablet and xonsight-lbphone both load this portal inside a FiveM NUI
    # <iframe>, which browsers treat as a cross-site/third-party embed. A Lax cookie is never sent in that
    # context, so the session the login POST lands on doesn't match the one the login page's CSRF token was
    # issued for - "CSRF error" on first login from the tablet/phone, every time. SameSite=None requires
    # Secure (already on above); the CSRF token itself (Flask-WTF, not this cookie) is still the actual
    # protection against cross-site form submission.
    SESSION_COOKIE_SAMESITE = "None"
    PERMANENT_SESSION_LIFETIME = timedelta(days=14)

    # CSRF (Flask-WTF, xonsight/extensions.py). None = tokens stay valid for the life of the session instead of
    # expiring after Flask-WTF's 1-hour default - a stale background tab shouldn't suddenly fail to submit.
    WTF_CSRF_TIME_LIMIT = None
    # Flask-WTF's default (True, since this deployment is https) also rejects any POST with no Referer header
    # at all as a CSRF failure - FiveM's NUI <iframe> (xonsight-tablet, xonsight-lbphone) doesn't reliably send
    # one. The CSRF token itself (the actual protection) still applies regardless of this setting.
    WTF_CSRF_SSL_STRICT = False

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
