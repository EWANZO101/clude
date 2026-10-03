"""Configuration. All tunables come from environment variables so the
installer / systemd unit can drive them without editing code."""
import os

BASE_DIR = os.path.abspath(os.path.dirname(os.path.dirname(__file__)))


def _bool(name, default=False):
    return os.environ.get(name, str(default)).strip().lower() in ("1", "true", "yes", "on")


class Config:
    SECRET_KEY = os.environ.get("SECRET_KEY", "change-me-in-production")
    PREFERRED_URL_SCHEME = "https"

    SQLALCHEMY_DATABASE_URI = os.environ.get(
        "DATABASE_URL", f"sqlite:///{os.path.join(BASE_DIR, 'instance', 'motoguard.db')}"
    )
    SQLALCHEMY_TRACK_MODIFICATIONS = False

    # Uploads
    UPLOAD_FOLDER = os.environ.get(
        "UPLOAD_FOLDER", os.path.join(BASE_DIR, "motoguard", "static", "uploads")
    )
    MAX_CONTENT_LENGTH = int(os.environ.get("MAX_UPLOAD_MB", "8")) * 1024 * 1024
    ALLOWED_IMAGE_EXT = {"png", "jpg", "jpeg", "webp", "gif"}

    # Alert engine
    ALERT_RADIUS_MILES = float(os.environ.get("ALERT_RADIUS_MILES", "40"))
    ALERT_PER_EVENT_CAP = int(os.environ.get("ALERT_PER_EVENT_CAP", "1"))  # emails per stolen event
    MESSAGE_RATE_PER_MIN = int(os.environ.get("MESSAGE_RATE_PER_MIN", "20"))

    # SMTP (optional — if unset, emails are logged to console instead of sent)
    SMTP_HOST = os.environ.get("SMTP_HOST", "")
    SMTP_PORT = int(os.environ.get("SMTP_PORT", "587"))
    SMTP_USER = os.environ.get("SMTP_USER", "")
    SMTP_PASS = os.environ.get("SMTP_PASS", "")
    SMTP_TLS = _bool("SMTP_TLS", True)
    MAIL_FROM = os.environ.get("MAIL_FROM", "alerts@motoguard.local")
    MAIL_SENDER_NAME = os.environ.get("MAIL_SENDER_NAME", "MotoGuard Recovery")

    PUBLIC_BASE_URL = os.environ.get("PUBLIC_BASE_URL", "http://localhost:5060")

    GOOGLE_MAPS_API_KEY = os.environ.get("GOOGLE_MAPS_API_KEY", "")

    # DVSA MOT History API (reg lookup -> autofill). Secrets via env only.
    # OAuth2 client-credentials via Microsoft Entra; token URL contains the
    # DVSA tenant id and ships in your credentials email.
    MOT_CLIENT_ID = os.environ.get("MOT_CLIENT_ID", "")
    MOT_CLIENT_SECRET = os.environ.get("MOT_CLIENT_SECRET", "")
    MOT_API_KEY = os.environ.get("MOT_API_KEY", "")
    MOT_TOKEN_URL = os.environ.get(
        "MOT_TOKEN_URL",
        "https://login.microsoftonline.com/"
        "a455b827-244f-4c97-b5b4-ce5d13b4d00c/oauth2/v2.0/token")
    MOT_SCOPE = os.environ.get("MOT_SCOPE", "https://tapi.dvsa.gov.uk/.default")
    MOT_API_BASE = os.environ.get("MOT_API_BASE", "https://history.mot.api.gov.uk")

    # DVLA Vehicle Enquiry Service (tax + MOT status). Free, separate key.
    VES_API_KEY = os.environ.get("VES_API_KEY", "")
    VES_API_URL = os.environ.get(
        "VES_API_URL",
        "https://driver-vehicle-licensing.api.gov.uk/vehicle-enquiry/v1/vehicles")

    # GeoNames web services (location search). Free — needs a username.
    GEONAMES_USERNAME = os.environ.get("GEONAMES_USERNAME", "")
    GEONAMES_BASE = os.environ.get("GEONAMES_BASE", "https://secure.geonames.org")

    # --- security / cookies ---
    SESSION_COOKIE_HTTPONLY = True
    SESSION_COOKIE_SAMESITE = "Lax"
    # Secure cookies on by default when served over HTTPS; override with env.
    SESSION_COOKIE_SECURE = (os.environ.get(
        "SESSION_COOKIE_SECURE",
        "true" if os.environ.get("PUBLIC_BASE_URL", "").startswith("https") else "false"
    ).lower() == "true")
    REMEMBER_COOKIE_HTTPONLY = True
    REMEMBER_COOKIE_SAMESITE = "Lax"
    REMEMBER_COOKIE_SECURE = SESSION_COOKIE_SECURE
    MAX_CONTENT_LENGTH = int(os.environ.get("MAX_CONTENT_LENGTH", str(16 * 1024 * 1024)))
