import os
import secrets
from datetime import timedelta

from dotenv import load_dotenv

BASE_DIR = os.path.abspath(os.path.dirname(__file__))

# Everything persistent (secret key, ssh whitelist, the sqlite db) lives
# outside BASE_DIR on purpose. BASE_DIR is the code folder — it gets
# overwritten/re-extracted on every deploy. DATA_DIR does not, so a new zip
# landing on top of server-panel/ never wipes the database or forces the
# signup/setup wizard to run again. Override with SERVER_PANEL_DATA_DIR if
# you want it somewhere else.
DATA_DIR = os.environ.get("SERVER_PANEL_DATA_DIR", "/root/server-panel-data")
os.makedirs(DATA_DIR, exist_ok=True)
ENV_PATH = os.path.join(DATA_DIR, ".env")


def _ensure_persistent_secret_key():
    """Make sure a SECRET_KEY exists in .env and is loaded into the environment.

    Without this, session/remember-me cookies only stay valid for as long as the
    Python process stays alive with the same in-memory default — anything that
    restarts the process (systemd restart, reboot, crash) invalidates every
    signed cookie and forces everyone back through login (or setup, if it also
    happens to coincide with a fresh/empty database).
    """
    if os.path.exists(ENV_PATH):
        load_dotenv(ENV_PATH)

    if os.environ.get("SECRET_KEY"):
        return

    # No key yet anywhere — generate one and persist it so future restarts reuse it.
    generated = secrets.token_hex(32)
    os.environ["SECRET_KEY"] = generated
    try:
        with open(ENV_PATH, "a", encoding="utf-8") as f:
            f.write(f"SECRET_KEY={generated}\n")
    except OSError:
        pass  # worst case: stays in-memory for this process only


_ensure_persistent_secret_key()


def _read_ssh_whitelist():
    raw = os.environ.get("SSH_WHITELIST_IPS", "")
    return [ip.strip() for ip in raw.split(",") if ip.strip()]


def _write_env_line(key, value):
    """Rewrite (or append) a single KEY=value line in the persistent .env
    file, then update the live env var for this process. Shared by every
    persisted setting (SSH whitelist, Cloudflare credentials, ...) so they
    all survive a restart the same way SECRET_KEY does."""
    os.environ[key] = value

    lines = []
    found = False
    if os.path.exists(ENV_PATH):
        with open(ENV_PATH, "r", encoding="utf-8") as f:
            lines = f.readlines()

    for i, line in enumerate(lines):
        if line.startswith(f"{key}="):
            lines[i] = f"{key}={value}\n"
            found = True
            break
    if not found:
        lines.append(f"{key}={value}\n")

    with open(ENV_PATH, "w", encoding="utf-8") as f:
        f.writelines(lines)


def persist_cloudflare_token(token):
    """Stored the same way SECRET_KEY is: plaintext in the panel's private
    .env file under DATA_DIR (outside the web root, not the code folder
    that gets overwritten on every deploy). Anyone with shell access to
    this box could already read ufw rules, SSH config, etc., so this
    matches the trust model the rest of the panel already assumes."""
    _write_env_line("CLOUDFLARE_API_TOKEN", token)


def persist_cloudflare_zone(zone_id):
    _write_env_line("CLOUDFLARE_ZONE_ID", zone_id)


def persist_namecheap_credentials(api_user, api_key, username, client_ip):
    """Same plaintext-in-.env pattern as the Cloudflare token — see
    persist_cloudflare_token's note on the trust model this assumes."""
    _write_env_line("NAMECHEAP_API_USER", api_user or "")
    _write_env_line("NAMECHEAP_API_KEY", api_key or "")
    _write_env_line("NAMECHEAP_USERNAME", username or "")
    _write_env_line("NAMECHEAP_CLIENT_IP", client_ip or "")


def persist_namecheap_domain(domain):
    _write_env_line("NAMECHEAP_ACTIVE_DOMAIN", domain or "")


def persist_godaddy_credentials(token, domain):
    """Same plaintext-in-.env pattern as the Cloudflare token — see
    persist_cloudflare_token's note on the trust model this assumes.
    Bundles the domain in with the token (rather than a separate
    persist_godaddy_domain-only flow at connect time) because GoDaddy's
    v3 API has no way to list domains, so there's no "connect first,
    pick a zone after" step here the way there is for Cloudflare and
    Namecheap — the domain has to be known before it's ever useful."""
    _write_env_line("GODADDY_API_TOKEN", token or "")
    _write_env_line("GODADDY_DOMAIN", domain or "")


def persist_godaddy_domain(domain):
    _write_env_line("GODADDY_DOMAIN", domain or "")


def persist_dns_provider(provider_key):
    """Which provider tab the DNS page opens to next time."""
    _write_env_line("DNS_PROVIDER", provider_key or "")


def persist_ssh_whitelist(ips):
    """Rewrite the SSH_WHITELIST_IPS line in .env so the list survives a
    restart, then update the live env var for this process. This is config
    persistence only — services/firewall_service.py is what actually talks
    to ufw and enforces the 'can't remove the last one' rule."""
    value = ",".join(ips)
    os.environ["SSH_WHITELIST_IPS"] = value

    lines = []
    found = False
    if os.path.exists(ENV_PATH):
        with open(ENV_PATH, "r", encoding="utf-8") as f:
            lines = f.readlines()

    for i, line in enumerate(lines):
        if line.startswith("SSH_WHITELIST_IPS="):
            lines[i] = f"SSH_WHITELIST_IPS={value}\n"
            found = True
            break
    if not found:
        lines.append(f"SSH_WHITELIST_IPS={value}\n")

    with open(ENV_PATH, "w", encoding="utf-8") as f:
        f.writelines(lines)


class Config:
    SECRET_KEY = os.environ.get("SECRET_KEY", "change-me-in-production")

    SQLALCHEMY_DATABASE_URI = os.environ.get(
        "DATABASE_URL", f"sqlite:///{os.path.join(DATA_DIR, 'panel.db')}"
    )
    SQLALCHEMY_TRACK_MODIFICATIONS = False

    WTF_CSRF_ENABLED = True

    SESSION_COOKIE_HTTPONLY = True
    SESSION_COOKIE_SAMESITE = "Lax"
    SESSION_COOKIE_SECURE = os.environ.get("SESSION_COOKIE_SECURE", "false").lower() == "true"
    PERMANENT_SESSION_LIFETIME = timedelta(days=30)
    REMEMBER_COOKIE_DURATION = timedelta(days=30)

    PANEL_PORT = int(os.environ.get("PANEL_PORT", 9500))
    PANEL_NAME = "OpsLab Server Panel"

    SSH_WHITELIST_IPS = _read_ssh_whitelist()

    CLOUDFLARE_API_TOKEN = os.environ.get("CLOUDFLARE_API_TOKEN", "")
    CLOUDFLARE_ZONE_ID = os.environ.get("CLOUDFLARE_ZONE_ID", "")

    NAMECHEAP_API_USER = os.environ.get("NAMECHEAP_API_USER", "")
    NAMECHEAP_API_KEY = os.environ.get("NAMECHEAP_API_KEY", "")
    NAMECHEAP_USERNAME = os.environ.get("NAMECHEAP_USERNAME", "")
    NAMECHEAP_CLIENT_IP = os.environ.get("NAMECHEAP_CLIENT_IP", "")
    NAMECHEAP_ACTIVE_DOMAIN = os.environ.get("NAMECHEAP_ACTIVE_DOMAIN", "")

    GODADDY_API_TOKEN = os.environ.get("GODADDY_API_TOKEN", "")
    GODADDY_DOMAIN = os.environ.get("GODADDY_DOMAIN", "")

    # Which provider tab the DNS page defaults to. Per-request ?provider=
    # switches don't persist this — only an explicit "make this the
    # default" action does (see dns.select_provider).
    DNS_PROVIDER = os.environ.get("DNS_PROVIDER", "cloudflare")

    LOG_DIR = os.path.join(BASE_DIR, "logs")

    # Static assets (css/js/fonts) are now same-origin and content doesn't
    # change between deploys without a filename/hash change in practice, so
    # let the browser cache them hard instead of re-validating on every nav.
    SEND_FILE_MAX_AGE_DEFAULT = int(os.environ.get("STATIC_CACHE_SECONDS", 604800))  # 7 days

