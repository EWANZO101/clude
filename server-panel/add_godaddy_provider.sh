#!/usr/bin/env bash
# Adds GoDaddy as a third DNS provider (alongside Cloudflare and
# Namecheap), using the GoDaddy Domains v3 API
# (https://developer.godaddy.com/en/docs/references/rest/domains/v3).
#
# New files:
#   services/dns_providers/godaddy_service.py   - thin v3 REST client
#   services/dns_providers/godaddy_provider.py  - DNSProvider adapter
#
# Modified files (backed up before overwrite):
#   services/dns_providers/registry.py  - registers GoDaddyProvider
#   config.py                           - GODADDY_API_TOKEN / GODADDY_DOMAIN
#   modules/dns/forms.py                - GoDaddyCredentialsForm
#   modules/dns/routes.py               - save/remove credential routes
#   modules/dns/templates/dns_index.html - Connect GoDaddy card + tab
#
# Note: GoDaddy's v3 API has no "list all domains" endpoint, so unlike
# Cloudflare/Namecheap you enter the one domain to manage at connect
# time (token + domain together). It also has no per-record update
# endpoint, so edits are done as delete-then-create under the hood.
set -euo pipefail

APP_DIR="/root/server-panel"
SERVICE_NAME="SERVERPANEL.service"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="$APP_DIR/backups/godaddy-provider-${TIMESTAMP}"

if [[ ! -d "$APP_DIR" ]]; then
    echo "ERROR: $APP_DIR not found. Check APP_DIR at the top of this script." >&2
    exit 1
fi

mkdir -p "$BACKUP_DIR"

backup_if_exists() {
    local rel="$1"
    local src="$APP_DIR/$rel"
    if [[ -f "$src" ]]; then
        local dest="$BACKUP_DIR/$rel"
        mkdir -p "$(dirname "$dest")"
        cp "$src" "$dest"
        echo "Backed up $rel"
    fi
}

backup_if_exists "services/dns_providers/registry.py"
backup_if_exists "config.py"
backup_if_exists "modules/dns/forms.py"
backup_if_exists "modules/dns/routes.py"
backup_if_exists "modules/dns/templates/dns_index.html"

mkdir -p "$APP_DIR/$(dirname services/dns_providers/godaddy_service.py)"
cat > "$APP_DIR/services/dns_providers/godaddy_service.py" << 'GODADDY_EOF'
"""Thin client for the GoDaddy Domains v3 REST API
(https://developer.godaddy.com/en/docs/references/rest/domains/v3).

Bearer-token auth (a Personal Access Token from the GoDaddy developer
dashboard) — same shape as cloudflare_service.py: every function here
takes the token explicitly as its first argument rather than reading
one out of app config.

Two things make this meaningfully different from the other two provider
services in this codebase:

1. v3 has no "list every domain I own" endpoint — that operation is
   still v1-only (see the API's own "what v3 does not cover" table).
   So this panel can't populate a zone dropdown for GoDaddy the way it
   does for Cloudflare and Namecheap. Instead the domain is entered
   once, alongside the token, when GoDaddy is connected (see
   godaddy_provider.py / GoDaddyCredentialsForm), and get_domain() is
   used to confirm it's real and owned by this account before it's
   saved. list_domains() below just re-confirms that one saved domain
   afterward, so the panel's zone picker always renders (a dropdown of
   exactly one item is expected here, not a bug).

2. v3 has no per-record update endpoint — only list, create, and delete
   (https://developer.godaddy.com/en/docs/references/rest/domains/v3/records).
   update_dns_record() below is delete-then-create composed from those
   two primitives, same spirit as namecheap_service's getHosts/setHosts
   dance, just a two-call version instead of a full-zone replace. If
   the create half fails after the delete half succeeds, the record is
   gone rather than reverted — a failed update should be treated as
   "go check the zone", not "the original record is still there".
"""
import requests

API_BASE = "https://api.godaddy.com/v3/domains"
TIMEOUT = 15

# Record types the panel's Add/Edit form exposes. GoDaddy also supports
# structured types like SRV and CAA that use fields (service/port/
# weight/protocol, or flag/tag) this form doesn't collect — deliberately
# left out here rather than half-supporting them with a form that can't
# represent their real shape. GoDaddy-managed SOA and NS records are
# read-only at the zone apex (the API returns 409 dns_record_not_mutable
# on any attempt to touch them), so those are left out too. Those can
# still be managed directly in the GoDaddy dashboard.
RECORD_TYPES = ["A", "AAAA", "CNAME", "TXT", "MX", "ALIAS"]

# GoDaddy has no concept of edge-proxying a record (that's a Cloudflare
# thing) — this stays empty so the shared template's Proxy column just
# renders "—" for every row, same as Namecheap.
PROXYABLE_TYPES = set()

# The API rejects any ttl below this; there's no "Auto" TTL concept like
# Cloudflare's 1. DEFAULT_TTL is used whenever the panel's shared record
# form submits its own default of 1.
MIN_TTL = 600
DEFAULT_TTL = 3600


class GoDaddyError(Exception):
    pass


def _headers(token):
    return {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}


def _request(method, path, token, **kwargs):
    if not token:
        raise GoDaddyError("No GoDaddy API token provided for this request.")
    try:
        resp = requests.request(method, f"{API_BASE}{path}", headers=_headers(token), timeout=TIMEOUT, **kwargs)
    except requests.RequestException as exc:
        raise GoDaddyError(f"Couldn't reach GoDaddy: {exc}") from exc

    if resp.status_code == 401:
        raise GoDaddyError("GoDaddy rejected this token (401 Unauthorized). Generate a new Personal Access Token from the GoDaddy developer dashboard.")
    if resp.status_code == 403:
        raise GoDaddyError("This token doesn't have permission for that operation (403 Forbidden).")
    if resp.status_code == 404:
        raise GoDaddyError("GoDaddy returned 404 — check the domain name is correct and owned by this account.")
    if resp.status_code == 409:
        raise GoDaddyError("GoDaddy rejected this change as a conflict (409) — this is often a GoDaddy-managed system record (SOA/NS) that can't be edited here.")
    if not resp.ok:
        try:
            body = resp.json()
            message = body.get("message") or body.get("name") or resp.text
        except ValueError:
            message = resp.text
        raise GoDaddyError(f"GoDaddy API error ({resp.status_code}): {message}")

    if resp.status_code == 204 or not resp.content:
        return None
    try:
        return resp.json()
    except ValueError:
        return None


def _clamp_ttl(ttl):
    """The shared record-form default (1, meaning "Auto" on Cloudflare/
    Namecheap) is below GoDaddy's minimum — fall back to a sane default
    instead of letting the API 400 on it."""
    if not ttl or ttl < MIN_TTL:
        return DEFAULT_TTL
    return ttl


def verify_token(token, domain=None):
    """Cheapest real call that proves the token authenticates: check
    availability of a domain. This doesn't require the token to own
    anything — check-availability works for any domain name, so it's a
    clean way to confirm the token itself is valid before also checking
    ownership of the specific domain the user entered."""
    probe = domain or "example.com"
    _request("GET", "/check-availability", token, params={"domain": probe})
    return True


def get_domain(token, domain):
    """Confirms `domain` is real and owned by this account, and returns
    its status. Used both to validate the domain entered at connect
    time and to populate list_domains()'s single-entry result."""
    data = _request("GET", f"/domain-names/{domain}", token)
    name = (data or {}).get("domain", domain)
    status = ((data or {}).get("status") or "unknown").lower()
    return {"id": name, "name": name, "status": status}


def list_domains(token, domain):
    """v3 has no bulk domain list — this just re-confirms the one saved
    domain still resolves, so the panel's zone dropdown (a dropdown of
    one) behaves the same shape as every other provider's."""
    if not domain:
        return []
    try:
        return [get_domain(token, domain)]
    except GoDaddyError:
        return []


def list_dns_records(token, zone):
    """Pages through every record in the zone — v3 caps pageSize at 100,
    so a zone with more records than that needs more than one call."""
    records = []
    page = 1
    while True:
        data = _request("GET", f"/zones/{zone}/dns-records", token, params={"page": page, "pageSize": 100}) or {}
        items = data.get("items", [])
        for item in items:
            records.append({
                "id": item.get("recordId"),
                "type": item.get("type"),
                "name": item.get("name"),
                "content": item.get("data"),
                "ttl": item.get("ttl"),
                "proxied": False,
                "priority": item.get("priority"),
            })
        if len(items) < 100:
            break
        page += 1
    records.sort(key=lambda r: (r["type"], r["name"]))
    return records


def _record_body(record_type, name, content, ttl, priority):
    body = {"name": name or "@", "type": record_type, "data": content, "ttl": _clamp_ttl(ttl)}
    if record_type == "MX" and priority is not None:
        body["priority"] = priority
    return body


def create_dns_record(token, zone, record_type, name, content, ttl=1, proxied=False, priority=None):
    # proxied is accepted for signature parity with the other providers'
    # create_record calls — GoDaddy has nothing corresponding to it.
    body = _record_body(record_type, name, content, ttl, priority)
    return _request("POST", f"/zones/{zone}/dns-records", token, json=body)


def delete_dns_record(token, zone, record_id):
    return _request("DELETE", f"/zones/{zone}/dns-records/{record_id}", token)


def update_dns_record(token, zone, record_id, record_type, name, content, ttl=1, proxied=False, priority=None):
    """v3 has no PUT/PATCH for a single record (see module docstring) —
    delete the old one, then create its replacement."""
    delete_dns_record(token, zone, record_id)
    return create_dns_record(token, zone, record_type, name, content, ttl=ttl, proxied=proxied, priority=priority)

GODADDY_EOF
echo "Wrote services/dns_providers/godaddy_service.py"

mkdir -p "$APP_DIR/$(dirname services/dns_providers/godaddy_provider.py)"
cat > "$APP_DIR/services/dns_providers/godaddy_provider.py" << 'GODADDY_EOF'
"""GoDaddy adapter — implements DNSProvider by delegating to
services/dns_providers/godaddy_service.py.

Unlike Cloudflare and Namecheap, the GoDaddy Domains v3 API has no
"list every domain on this account" endpoint (that's still v1-only —
see godaddy_service.py's docstring), so this panel can't discover zones
automatically the way it does for the other two providers. Instead the
domain is entered once, alongside the API token, when GoDaddy is
connected, and list_domains() just re-confirms that one domain still
resolves. The zone-picker dropdown in the template ends up with exactly
one option for GoDaddy — that's expected here, not a bug.
"""
from flask import current_app

from services.dns_providers import godaddy_service as gd
from services.dns_providers.base import DNSProvider, DNSProviderError
from config import persist_godaddy_credentials, persist_godaddy_domain


class GoDaddyProvider(DNSProvider):
    key = "godaddy"
    label = "GoDaddy"
    record_types = gd.RECORD_TYPES
    proxyable_types = gd.PROXYABLE_TYPES
    supports_nameserver_switch = False

    def _token(self):
        return current_app.config.get("GODADDY_API_TOKEN", "")

    def _domain(self):
        return current_app.config.get("GODADDY_DOMAIN", "")

    def is_configured(self):
        return bool(self._token() and self._domain())

    def verify_credentials(self, token=None, domain=None, **_):
        try:
            gd.verify_token(token, domain=domain)
            if domain:
                gd.get_domain(token, domain)
        except gd.GoDaddyError as exc:
            raise DNSProviderError(str(exc)) from exc
        return True

    def save_credentials(self, token=None, domain=None, **_):
        persist_godaddy_credentials(token, domain)
        current_app.config["GODADDY_API_TOKEN"] = token
        current_app.config["GODADDY_DOMAIN"] = domain

    def remove_credentials(self):
        persist_godaddy_credentials("", "")
        current_app.config["GODADDY_API_TOKEN"] = ""
        current_app.config["GODADDY_DOMAIN"] = ""

    def active_domain_id(self):
        return self._domain()

    def persist_active_domain(self, domain_id):
        # There's only ever one domain here (see class docstring) — this
        # exists to satisfy the DNSProvider contract the template calls
        # unconditionally, not because GoDaddy actually supports switching
        # between multiple zones.
        persist_godaddy_domain(domain_id)
        current_app.config["GODADDY_DOMAIN"] = domain_id

    def list_domains(self):
        try:
            return gd.list_domains(self._token(), self._domain())
        except gd.GoDaddyError as exc:
            raise DNSProviderError(str(exc)) from exc

    def list_records(self, domain_id):
        try:
            return gd.list_dns_records(self._token(), domain_id)
        except gd.GoDaddyError as exc:
            raise DNSProviderError(str(exc)) from exc

    def create_record(self, domain_id, record_type, name, content, ttl=1, proxied=False, priority=None):
        try:
            return gd.create_dns_record(
                self._token(), domain_id, record_type, name, content,
                ttl=ttl, proxied=proxied, priority=priority,
            )
        except gd.GoDaddyError as exc:
            raise DNSProviderError(str(exc)) from exc

    def update_record(self, domain_id, record_id, record_type, name, content, ttl=1, proxied=False, priority=None):
        try:
            return gd.update_dns_record(
                self._token(), domain_id, record_id, record_type, name, content,
                ttl=ttl, proxied=proxied, priority=priority,
            )
        except gd.GoDaddyError as exc:
            raise DNSProviderError(str(exc)) from exc

    def delete_record(self, domain_id, record_id):
        try:
            return gd.delete_dns_record(self._token(), domain_id, record_id)
        except gd.GoDaddyError as exc:
            raise DNSProviderError(str(exc)) from exc

GODADDY_EOF
echo "Wrote services/dns_providers/godaddy_provider.py"

mkdir -p "$APP_DIR/$(dirname services/dns_providers/registry.py)"
cat > "$APP_DIR/services/dns_providers/registry.py" << 'GODADDY_EOF'
"""Registry of available DNS providers. Adding a new one (Route 53,
Porkbun, GoDaddy, DigitalOcean DNS, ...) means writing a class that
implements services.dns_providers.base.DNSProvider and adding one line
here — routes.py and the template iterate this dict/list and never need
to know a new provider exists beyond that.
"""
from services.dns_providers.cloudflare_provider import CloudflareProvider
from services.dns_providers.namecheap_provider import NamecheapProvider
from services.dns_providers.godaddy_provider import GoDaddyProvider

_PROVIDERS = {
    "cloudflare": CloudflareProvider(),
    "namecheap": NamecheapProvider(),
    "godaddy": GoDaddyProvider(),
    # "route53": Route53Provider(),
    # "porkbun": PorkbunProvider(),
    # "digitalocean": DigitalOceanDNSProvider(),
}

DEFAULT_PROVIDER = "cloudflare"


def get_provider(key):
    return _PROVIDERS.get(key)


def all_providers():
    """Ordered list for the provider picker UI."""
    return list(_PROVIDERS.values())


def is_valid(key):
    return key in _PROVIDERS

GODADDY_EOF
echo "Wrote services/dns_providers/registry.py"

mkdir -p "$APP_DIR/$(dirname config.py)"
cat > "$APP_DIR/config.py" << 'GODADDY_EOF'
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

GODADDY_EOF
echo "Wrote config.py"

mkdir -p "$APP_DIR/$(dirname modules/dns/forms.py)"
cat > "$APP_DIR/modules/dns/forms.py" << 'GODADDY_EOF'
from flask_wtf import FlaskForm
from wtforms import StringField, SelectField, IntegerField, BooleanField
from wtforms.validators import DataRequired, Length, Optional, NumberRange, IPAddress

from services.cloudflare_service import RECORD_TYPES


class TokenForm(FlaskForm):
    token = StringField("Cloudflare API Token", validators=[DataRequired(), Length(max=200)])


class NamecheapCredentialsForm(FlaskForm):
    api_user = StringField("API User", validators=[DataRequired(), Length(max=100)])
    api_key = StringField("API Key", validators=[DataRequired(), Length(max=200)])
    username = StringField("Account Username (usually same as API User)", validators=[Optional(), Length(max=100)])
    client_ip = StringField(
        "Whitelisted Client IP",
        validators=[DataRequired(), IPAddress(message="Enter a valid IPv4 address.")],
    )


class GoDaddyCredentialsForm(FlaskForm):
    token = StringField("GoDaddy API Token", validators=[DataRequired(), Length(max=200)])
    domain = StringField("Domain", validators=[DataRequired(), Length(max=255)])


class DnsRecordForm(FlaskForm):
    # Default choices are Cloudflare's; routes.py overrides form.type.choices
    # with the active provider's record_types before validate_on_submit()
    # so the form always validates against whichever provider is active.
    type = SelectField("Type", choices=[(t, t) for t in RECORD_TYPES], validators=[DataRequired()])
    name = StringField("Name", validators=[DataRequired(), Length(max=255)])
    content = StringField("Content", validators=[DataRequired(), Length(max=500)])
    ttl = IntegerField("TTL (seconds, 1 = Auto)", default=1, validators=[Optional(), NumberRange(min=1, max=86400)])
    proxied = BooleanField("Proxied (orange cloud)")
    priority = IntegerField("Priority (MX only)", validators=[Optional(), NumberRange(min=0, max=65535)])

GODADDY_EOF
echo "Wrote modules/dns/forms.py"

mkdir -p "$APP_DIR/$(dirname modules/dns/routes.py)"
cat > "$APP_DIR/modules/dns/routes.py" << 'GODADDY_EOF'
from flask import Blueprint, render_template, redirect, url_for, flash, request, current_app

from services.dns_providers.registry import get_provider, all_providers, is_valid, DEFAULT_PROVIDER
from services.dns_providers.base import DNSProviderError
from modules.dns.forms import TokenForm, NamecheapCredentialsForm, GoDaddyCredentialsForm, DnsRecordForm
from utils.permissions import require_permission
from config import persist_dns_provider

dns_bp = Blueprint("dns", __name__, template_folder="templates")


def _active_provider_key():
    requested = request.args.get("provider")
    if requested and is_valid(requested):
        return requested
    key = current_app.config.get("DNS_PROVIDER", DEFAULT_PROVIDER)
    return key if is_valid(key) else DEFAULT_PROVIDER


@dns_bp.route("/dns")
@require_permission("dns.view")
def index():
    provider_key = _active_provider_key()
    # Clicking a provider tab is "select this as my DNS provider" — persist
    # it so the page opens here next time too, not just for this request.
    if request.args.get("provider") == provider_key:
        persist_dns_provider(provider_key)
        current_app.config["DNS_PROVIDER"] = provider_key

    provider = get_provider(provider_key)
    providers = all_providers()

    if not provider.is_configured():
        return render_template(
            "dns_index.html",
            configured=False,
            provider_key=provider_key,
            provider=provider,
            providers=providers,
            token_form=TokenForm(),
            namecheap_form=NamecheapCredentialsForm(),
            godaddy_form=GoDaddyCredentialsForm(),
        )

    zones, records, active_zone, error, nameserver_mode = [], [], None, None, None
    zone_id = provider.active_domain_id()
    try:
        zones = provider.list_domains()
        if zones and not any(z["id"] == zone_id for z in zones):
            # Previously-selected domain no longer visible to these
            # credentials — fall back to the first one rather than
            # silently showing an empty/broken page.
            zone_id = zones[0]["id"]
            provider.persist_active_domain(zone_id)
        active_zone = next((z for z in zones if z["id"] == zone_id), None)
        if zone_id:
            records = provider.list_records(zone_id)
            if provider.supports_nameserver_switch:
                nameserver_mode = provider.get_nameserver_mode(zone_id)
    except DNSProviderError as exc:
        error = str(exc)

    record_form = DnsRecordForm()
    record_form.type.choices = [(t, t) for t in provider.record_types]

    return render_template(
        "dns_index.html",
        configured=True,
        provider_key=provider_key,
        provider=provider,
        providers=providers,
        zones=zones,
        zone_id=zone_id,
        active_zone=active_zone,
        records=records,
        error=error,
        record_form=record_form,
        proxyable_types=provider.proxyable_types,
        nameserver_mode=nameserver_mode,
    )


# ---------------------------------------------------------------------------
# Cloudflare credentials (kept at their original URLs for compatibility)
# ---------------------------------------------------------------------------

@dns_bp.route("/dns/token", methods=["POST"])
@require_permission("dns.manage")
def save_token():
    provider = get_provider("cloudflare")
    form = TokenForm()
    if form.validate_on_submit():
        token = form.token.data.strip()
        try:
            provider.verify_credentials(token=token)
            provider.save_credentials(token=token)
            flash("Cloudflare API token saved and verified.", "success")
        except DNSProviderError as exc:
            flash(f"Token rejected: {exc}", "error")
    else:
        flash("Enter an API token.", "error")
    return redirect(url_for("dns.index", provider="cloudflare"))


@dns_bp.route("/dns/token/remove", methods=["POST"])
@require_permission("dns.manage")
def remove_token():
    get_provider("cloudflare").remove_credentials()
    flash("Cloudflare disconnected. The token was removed from this panel.", "success")
    return redirect(url_for("dns.index", provider="cloudflare"))


# ---------------------------------------------------------------------------
# Namecheap credentials
# ---------------------------------------------------------------------------

@dns_bp.route("/dns/namecheap/credentials", methods=["POST"])
@require_permission("dns.manage")
def save_namecheap_credentials():
    provider = get_provider("namecheap")
    form = NamecheapCredentialsForm()
    if form.validate_on_submit():
        creds = dict(
            api_user=form.api_user.data.strip(),
            api_key=form.api_key.data.strip(),
            username=(form.username.data or "").strip(),
            client_ip=form.client_ip.data.strip(),
        )
        try:
            provider.verify_credentials(**creds)
            provider.save_credentials(**creds)
            flash("Namecheap API credentials saved and verified.", "success")
        except DNSProviderError as exc:
            flash(
                f"Namecheap rejected these credentials: {exc}. "
                "Double check the client IP is whitelisted under Profile → Tools → API Access on Namecheap.",
                "error",
            )
    else:
        flash("Check the Namecheap credential fields and try again.", "error")
    return redirect(url_for("dns.index", provider="namecheap"))


@dns_bp.route("/dns/namecheap/credentials/remove", methods=["POST"])
@require_permission("dns.manage")
def remove_namecheap_credentials():
    get_provider("namecheap").remove_credentials()
    flash("Namecheap disconnected. Credentials were removed from this panel.", "success")
    return redirect(url_for("dns.index", provider="namecheap"))


@dns_bp.route("/dns/namecheap/nameservers", methods=["POST"])
@require_permission("dns.manage")
def switch_namecheap_nameservers():
    provider = get_provider("namecheap")
    domain = provider.active_domain_id()
    action = request.form.get("action", "")
    if not domain:
        flash("Select a domain first.", "error")
        return redirect(url_for("dns.index", provider="namecheap"))
    try:
        if action == "default":
            provider.use_provider_dns(domain)
            flash(f"{domain} is now using Namecheap's DNS — records managed here will resolve.", "success")
        elif action == "custom":
            raw = request.form.get("nameservers", "")
            nameservers = [n.strip() for n in raw.split(",") if n.strip()]
            if not nameservers:
                flash("Enter at least one nameserver.", "error")
            else:
                provider.use_custom_nameservers(domain, nameservers)
                flash(f"{domain} switched to custom nameservers. Records managed here will no longer resolve until it's switched back.", "success")
        else:
            flash("Unknown nameserver action.", "error")
    except DNSProviderError as exc:
        flash(str(exc), "error")
    return redirect(url_for("dns.index", provider="namecheap"))


# ---------------------------------------------------------------------------
# GoDaddy credentials
# ---------------------------------------------------------------------------

@dns_bp.route("/dns/godaddy/credentials", methods=["POST"])
@require_permission("dns.manage")
def save_godaddy_credentials():
    provider = get_provider("godaddy")
    form = GoDaddyCredentialsForm()
    if form.validate_on_submit():
        token = form.token.data.strip()
        domain = form.domain.data.strip()
        try:
            provider.verify_credentials(token=token, domain=domain)
            provider.save_credentials(token=token, domain=domain)
            flash("GoDaddy API token saved and verified.", "success")
        except DNSProviderError as exc:
            flash(f"GoDaddy rejected these credentials: {exc}", "error")
    else:
        flash("Enter a GoDaddy API token and the domain to manage.", "error")
    return redirect(url_for("dns.index", provider="godaddy"))


@dns_bp.route("/dns/godaddy/credentials/remove", methods=["POST"])
@require_permission("dns.manage")
def remove_godaddy_credentials():
    get_provider("godaddy").remove_credentials()
    flash("GoDaddy disconnected. The token was removed from this panel.", "success")
    return redirect(url_for("dns.index", provider="godaddy"))


# ---------------------------------------------------------------------------
# Provider-agnostic: active domain/zone + record CRUD
# ---------------------------------------------------------------------------

@dns_bp.route("/dns/zone", methods=["POST"])
@require_permission("dns.manage")
def select_zone():
    provider_key = request.form.get("provider", _active_provider_key())
    provider = get_provider(provider_key)
    zone_id = request.form.get("zone_id", "").strip()
    provider.persist_active_domain(zone_id)
    flash("Active domain updated.", "success")
    return redirect(url_for("dns.index", provider=provider_key))


@dns_bp.route("/dns/record/add", methods=["POST"])
@require_permission("dns.manage")
def add_record():
    provider_key = request.form.get("provider", _active_provider_key())
    provider = get_provider(provider_key)
    zone_id = provider.active_domain_id()
    if not zone_id:
        flash("Select a domain before adding records.", "error")
        return redirect(url_for("dns.index", provider=provider_key))

    form = DnsRecordForm()
    form.type.choices = [(t, t) for t in provider.record_types]
    if form.validate_on_submit():
        try:
            provider.create_record(
                zone_id, form.type.data, form.name.data.strip(), form.content.data.strip(),
                ttl=form.ttl.data or 1, proxied=form.proxied.data, priority=form.priority.data,
            )
            flash(f"Created {form.type.data} record for {form.name.data}.", "success")
        except DNSProviderError as exc:
            flash(str(exc), "error")
    else:
        flash("Check the record fields and try again.", "error")
    return redirect(url_for("dns.index", provider=provider_key))


@dns_bp.route("/dns/record/<record_id>/edit", methods=["POST"])
@require_permission("dns.manage")
def edit_record(record_id):
    provider_key = request.form.get("provider", _active_provider_key())
    provider = get_provider(provider_key)
    zone_id = provider.active_domain_id()
    form = DnsRecordForm()
    form.type.choices = [(t, t) for t in provider.record_types]
    if form.validate_on_submit():
        try:
            provider.update_record(
                zone_id, record_id, form.type.data, form.name.data.strip(), form.content.data.strip(),
                ttl=form.ttl.data or 1, proxied=form.proxied.data, priority=form.priority.data,
            )
            flash(f"Updated {form.type.data} record for {form.name.data}.", "success")
        except DNSProviderError as exc:
            flash(str(exc), "error")
    else:
        flash("Check the record fields and try again.", "error")
    return redirect(url_for("dns.index", provider=provider_key))


@dns_bp.route("/dns/record/<record_id>/delete", methods=["POST"])
@require_permission("dns.manage")
def delete_record(record_id):
    provider_key = request.form.get("provider", _active_provider_key())
    provider = get_provider(provider_key)
    zone_id = provider.active_domain_id()
    try:
        provider.delete_record(zone_id, record_id)
        flash("Record deleted.", "success")
    except DNSProviderError as exc:
        flash(str(exc), "error")
    return redirect(url_for("dns.index", provider=provider_key))

GODADDY_EOF
echo "Wrote modules/dns/routes.py"

mkdir -p "$APP_DIR/$(dirname modules/dns/templates/dns_index.html)"
cat > "$APP_DIR/modules/dns/templates/dns_index.html" << 'GODADDY_EOF'
{% extends "base.html" %}
{% block title %}DNS — {{ panel_name }}{% endblock %}
{% block content %}
<div class="topbar">
  <div>
    <p class="page-eyebrow">DNS</p>
    <h1 class="page-title">DNS</h1>
    <p class="page-sub">Manage DNS records across providers, without leaving the panel</p>
  </div>
  {% if configured and zones %}
  <div class="topbar-actions">
    <form method="POST" action="{{ url_for('dns.select_zone') }}">
      <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
      <input type="hidden" name="provider" value="{{ provider_key }}">
      <select name="zone_id" onchange="this.form.submit()" style="min-width:220px;">
        {% for zone in zones %}
        <option value="{{ zone.id }}" {{ 'selected' if zone.id == zone_id }}>{{ zone.name }} ({{ zone.status }})</option>
        {% endfor %}
      </select>
      <noscript><button type="submit" class="btn btn-secondary">Switch</button></noscript>
    </form>
  </div>
  {% endif %}
</div>

<!-- Provider picker — the only thing that changes page-to-page is which
     provider is active; everything below reads generalized context
     (records/zones/provider) so this tab strip is the whole integration
     point for a new provider's UI. -->
<div class="pill" style="display:flex; gap:2px; padding:4px; margin-bottom:20px; width:fit-content;">
  {% for p in providers %}
  <a class="btn {{ 'btn-primary' if p.key == provider_key else 'btn-ghost' }} btn-sm"
     href="{{ url_for('dns.index', provider=p.key) }}" style="border:none;">{{ p.label }}</a>
  {% endfor %}
  <span class="btn btn-ghost btn-sm" style="opacity:0.5; cursor:default; border:none;" title="Route 53, Porkbun, DigitalOcean DNS, and others can be added here later">+ More soon</span>
</div>

{% if not configured %}

  {% if provider_key == 'namecheap' %}
  <div class="card" style="max-width:560px;">
    <div class="card-label">Connect Namecheap</div>
    <p class="page-sub" style="margin:6px 0 16px;">
      Create an API key at <span class="mono">Namecheap → Profile → Tools → Namecheap API Access</span> and enable
      API access on the account. Namecheap also requires the exact IP address making these calls (this server's
      public IP) to be added to that same whitelist — the credentials will be rejected until it is, even if the
      API user/key are correct. Stored the same way this panel stores its other secrets: plaintext in its private
      data directory, never in the code folder.
    </p>
    <form method="POST" action="{{ url_for('dns.save_namecheap_credentials') }}">
      {{ namecheap_form.hidden_tag() }}
      <div class="field">
        {{ namecheap_form.api_user.label }}
        {{ namecheap_form.api_user(placeholder="Namecheap API username", autocomplete="off") }}
      </div>
      <div class="field">
        {{ namecheap_form.api_key.label }}
        {{ namecheap_form.api_key(placeholder="Namecheap API key", type="password", autocomplete="off") }}
      </div>
      <div class="field">
        {{ namecheap_form.username.label }}
        {{ namecheap_form.username(placeholder="Leave blank to reuse the API user") }}
      </div>
      <div class="field">
        {{ namecheap_form.client_ip.label }}
        {{ namecheap_form.client_ip(placeholder="This server's public IP, e.g. 203.0.113.4") }}
      </div>
      <button class="btn btn-primary btn-block" type="submit">Verify &amp; connect</button>
    </form>
  </div>
  {% elif provider_key == 'godaddy' %}
  <div class="card" style="max-width:560px;">
    <div class="card-label">Connect GoDaddy</div>
    <p class="page-sub" style="margin:6px 0 16px;">
      Create a Personal Access Token at <span class="mono">GoDaddy Developer → My Account → API Keys</span>,
      then enter it here along with the domain you want to manage. GoDaddy's v3 API has no way to list every
      domain on an account, so this panel can only manage the one domain you name — enter it exactly as it's
      registered (e.g. <span class="mono">example.com</span>). The token is verified against GoDaddy before
      it's saved, and stored the same way this panel already stores its own secret key — plaintext in its
      private data directory, never in the code folder.
    </p>
    <form method="POST" action="{{ url_for('dns.save_godaddy_credentials') }}">
      {{ godaddy_form.hidden_tag() }}
      <div class="field">
        {{ godaddy_form.token.label }}
        {{ godaddy_form.token(placeholder="GoDaddy API token", type="password", autocomplete="off") }}
      </div>
      <div class="field">
        {{ godaddy_form.domain.label }}
        {{ godaddy_form.domain(placeholder="example.com") }}
      </div>
      <button class="btn btn-primary btn-block" type="submit">Verify &amp; connect</button>
    </form>
  </div>
  {% else %}
  <div class="card" style="max-width:520px;">
    <div class="card-label">Connect Cloudflare</div>
    <p class="page-sub" style="margin:6px 0 16px;">
      Create an API token at <span class="mono">Cloudflare dashboard → My Profile → API Tokens</span> using the
      <strong>Edit zone DNS</strong> template, scoped to the zone(s) you want this panel to manage. The token is
      verified against Cloudflare before it's saved, and stored the same way this panel already stores its own
      secret key — plaintext in its private data directory, never in the code folder.
    </p>
    <form method="POST" action="{{ url_for('dns.save_token') }}">
      {{ token_form.hidden_tag() }}
      <div class="field">
        {{ token_form.token.label }}
        {{ token_form.token(placeholder="Cloudflare API token", type="password", autocomplete="off") }}
      </div>
      <button class="btn btn-primary btn-block" type="submit">Verify &amp; connect</button>
    </form>
  </div>
  {% endif %}

{% else %}

  {% if error %}
  <div class="flash flash-error">{{ error }}</div>
  {% endif %}

  {% if zones %}
  <div class="grid">
    <div class="card stat">
      <div class="card-label">{{ 'Domain' if provider_key in ('namecheap', 'godaddy') else 'Zone' }}</div>
      <div class="card-value line">
        <span class="status-dot {{ 'ok live' if active_zone and active_zone.status == 'active' else '' }}"></span>
        {{ active_zone.name if active_zone else '—' }}
      </div>
      <div class="card-meta">{{ active_zone.status | capitalize if active_zone else 'unknown' }} · via {{ provider.label }}</div>
    </div>
    <div class="card stat">
      <div class="card-label">Total Records</div>
      <div class="card-value">{{ records | length }}</div>
      <div class="card-meta">across all types</div>
    </div>
    <div class="card stat">
      <div class="card-label">Proxied</div>
      <div class="card-value">{{ records | selectattr('proxied') | list | length }}</div>
      <div class="card-meta">routed through Cloudflare's edge</div>
    </div>
    <div class="card stat">
      <div class="card-label">DNS Only</div>
      <div class="card-value">{{ records | rejectattr('proxied') | list | length }}</div>
      <div class="card-meta">resolves directly, no proxying</div>
    </div>
  </div>

  {% if provider.supports_nameserver_switch and nameserver_mode is not none %}
  <div class="card tight" style="margin-top:16px;">
    <div class="card-header">
      <div class="card-label" style="margin:0;">Nameservers</div>
      {% if nameserver_mode.using_provider_dns %}
        <span class="badge badge-ok">Using {{ provider.label }} DNS</span>
      {% else %}
        <span class="badge badge-warn">Custom nameservers — records here won't resolve</span>
      {% endif %}
    </div>
    <p class="page-sub" style="margin:6px 0 14px;">
      {% if nameserver_mode.nameservers %}Currently: <span class="mono">{{ nameserver_mode.nameservers | join(', ') }}</span>{% else %}No nameservers reported.{% endif %}
    </p>
    <div class="btn-row">
      {% if not nameserver_mode.using_provider_dns %}
      <form method="POST" action="{{ url_for('dns.switch_namecheap_nameservers') }}">
        <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
        <input type="hidden" name="action" value="default">
        <button type="submit" class="btn btn-primary btn-sm">Switch to {{ provider.label }} DNS</button>
      </form>
      {% endif %}
      <form method="POST" action="{{ url_for('dns.switch_namecheap_nameservers') }}" style="display:flex; gap:6px; align-items:center;"
            onsubmit="return confirm('Switching to custom nameservers means records managed here will stop resolving until you switch back. Continue?');">
        <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
        <input type="hidden" name="action" value="custom">
        <input type="text" name="nameservers" placeholder="ns1.example.com, ns2.example.com" style="min-width:280px; background:var(--bg-void); border:1px solid var(--border-strong); border-radius:var(--radius); padding:7px 11px; color:var(--text-primary); font-size:13px;">
        <button type="submit" class="btn btn-ghost btn-sm">Use custom nameservers</button>
      </form>
    </div>
  </div>
  {% endif %}

  <div class="card flush tight" style="margin-top:16px;">
    <div class="card-header" style="padding:16px 18px 0; flex-wrap:wrap; gap:10px;">
      <div class="card-label" style="margin:0;" id="dns-records-count">
        {{ active_zone.name if active_zone else 'Zone' }} — {{ records | length }} record{{ 's' if records | length != 1 }}
      </div>
      <div style="display:flex; gap:8px; align-items:center; margin-left:auto;">
        <input type="text" id="dns-search" placeholder="Search name, type, or content…" autocomplete="off"
               style="min-width:240px; background:var(--bg-void); border:1px solid var(--border-strong); border-radius:var(--radius); padding:7px 11px; color:var(--text-primary); font-size:13px;">
        <button type="button" class="btn btn-primary btn-sm" onclick="openRecordModal()">+ Add record</button>
      </div>
    </div>
    <div class="table-wrap">
      <table class="data-table" id="dns-records-table" style="margin-top:8px;">
        <thead><tr><th>Type</th><th>Name</th><th>Content</th><th>TTL</th><th>Proxy</th><th>Actions</th></tr></thead>
        <tbody>
          {% for r in records %}
          <tr data-search="{{ (r.type ~ ' ' ~ r.name ~ ' ' ~ r.content) | lower }}">
            <td><span class="badge badge-muted mono">{{ r.type }}</span></td>
            <td class="mono primary">{{ r.name }}</td>
            <td class="mono">{{ r.content }}{% if r.type == 'MX' and r.priority is not none %} <span class="page-sub">(pri {{ r.priority }})</span>{% endif %}</td>
            <td class="mono">{{ 'Auto' if r.ttl == 1 else r.ttl }}</td>
            <td>
              {% if r.type in proxyable_types %}
                {% if r.proxied %}<span class="badge badge-ok">Proxied</span>{% else %}<span class="badge badge-muted">DNS only</span>{% endif %}
              {% else %}
                <span class="badge badge-muted">—</span>
              {% endif %}
            </td>
            <td class="table-actions">
              <button type="button" class="btn btn-secondary btn-sm"
                      onclick='openRecordModal({{ r | tojson }})'>Edit</button>
              <form method="POST" action="{{ url_for('dns.delete_record', record_id=r.id) }}"
                    onsubmit="return confirm('Delete the {{ r.type }} record for {{ r.name }}?');">
                <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
                <input type="hidden" name="provider" value="{{ provider_key }}">
                <button type="submit" class="btn btn-danger btn-sm">Delete</button>
              </form>
            </td>
          </tr>
          {% else %}
          <tr><td colspan="6"><div class="empty-state"><strong>No DNS records on this {{ 'domain' if provider_key in ('namecheap', 'godaddy') else 'zone' }} yet.</strong>Click "+ Add record" above to create your first one.</div></td></tr>
          {% endfor %}
          <tr id="dns-no-matches" style="display:none;"><td colspan="6"><div class="empty-state"><strong>No records match your search.</strong>Try a different name, type, or content.</div></td></tr>
        </tbody>
      </table>
    </div>
  </div>
  {% else %}
  <div class="card">
    <div class="empty-state">
      <strong>No {{ 'domains' if provider_key in ('namecheap', 'godaddy') else 'zones' }} visible to these credentials</strong>
      Double check the {{ 'account and domain spelling' if provider_key in ('namecheap', 'godaddy') else "API token's zone scope" }} in the {{ provider.label }} dashboard, then reload this page.
    </div>
  </div>
  {% endif %}

  <div class="modal-overlay" id="record-modal">
    <div class="modal-box modal-browse">
      <div class="modal-header">
        <h3 id="record-modal-title">Add record</h3>
        <button class="modal-close" type="button" id="record-close">&times;</button>
      </div>
      <form method="POST" id="record-form" style="padding:18px;">
        <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
        <input type="hidden" name="provider" value="{{ provider_key }}">
        <div class="field">
          <label for="record-type">Type</label>
          <select name="type" id="record-type" onchange="toggleRecordFields()">
            {% for t in record_form.type.choices %}
            <option value="{{ t[0] }}">{{ t[1] }}</option>
            {% endfor %}
          </select>
        </div>
        <div class="field"><label for="record-name">Name</label><input type="text" name="name" id="record-name" placeholder="www or @ for root"></div>
        <div class="field"><label for="record-content">Content</label><input type="text" name="content" id="record-content" placeholder="192.0.2.1 or target host"></div>
        <div class="field"><label for="record-ttl">TTL (seconds, 1 = Auto)</label><input type="number" name="ttl" id="record-ttl" min="1" max="86400" value="1"></div>
        <div class="field field-inline" id="record-proxied-field">
          <input type="checkbox" name="proxied" id="record-proxied" value="y"> <label for="record-proxied" style="margin:0;">Proxied (orange cloud)</label>
        </div>
        <div class="field" id="record-priority-field">
          <label for="record-priority">Priority (MX only)</label>
          <input type="number" name="priority" id="record-priority" min="0" max="65535" placeholder="10">
        </div>
        <div class="editor-footer" style="padding:0; border:none;">
          <button type="button" class="btn btn-ghost" id="record-cancel">Cancel</button>
          <button type="submit" class="btn btn-primary" id="record-submit">Add record</button>
        </div>
      </form>
    </div>
  </div>

  <div class="card tight" style="margin-top:16px; max-width:520px;">
    <div class="card-label">Disconnect {{ provider.label }}</div>
    <p class="page-sub" style="margin:6px 0 14px;">Removes the saved credentials for {{ provider.label }} from this panel. Records already published stay as they are.</p>
    <form method="POST" action="{{ url_for('dns.remove_namecheap_credentials') if provider_key == 'namecheap' else (url_for('dns.remove_godaddy_credentials') if provider_key == 'godaddy' else url_for('dns.remove_token')) }}"
          onsubmit="return confirm('Disconnect {{ provider.label }}? This removes the saved credentials from the panel.');">
      <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
      <button type="submit" class="btn btn-ghost">Disconnect {{ provider.label }}</button>
    </form>
  </div>
{% endif %}
{% endblock %}

{% block scripts %}
<script>
  const PROXYABLE_TYPES = {{ (proxyable_types | list) | tojson if proxyable_types else '[]' }};
  const ADD_URL = {{ url_for('dns.add_record') | tojson if configured else '""' }};

  function toggleRecordFields() {
    const type = document.getElementById('record-type').value;
    const proxiedField = document.getElementById('record-proxied-field');
    const priorityField = document.getElementById('record-priority-field');
    proxiedField.style.display = PROXYABLE_TYPES.includes(type) ? '' : 'none';
    priorityField.style.display = type === 'MX' ? '' : 'none';
  }

  const recordModal = document.getElementById('record-modal');

  // Called with no args to add a new record, or with a record object
  // (from the row's Edit button) to pre-fill and edit that one in place.
  function openRecordModal(record) {
    const form = document.getElementById('record-form');
    const title = document.getElementById('record-modal-title');
    const submitBtn = document.getElementById('record-submit');

    if (record) {
      title.textContent = 'Edit record';
      submitBtn.textContent = 'Save changes';
      form.action = '/dns/record/' + record.id + '/edit';
      document.getElementById('record-type').value = record.type;
      document.getElementById('record-name').value = record.name;
      document.getElementById('record-content').value = record.content;
      document.getElementById('record-ttl').value = record.ttl;
      document.getElementById('record-proxied').checked = !!record.proxied;
      document.getElementById('record-priority').value = record.priority ?? '';
    } else {
      title.textContent = 'Add record';
      submitBtn.textContent = 'Add record';
      form.action = ADD_URL;
      form.reset();
      document.getElementById('record-ttl').value = 1;
    }
    toggleRecordFields();
    recordModal.classList.add('open');
  }

  if (recordModal) {
    document.getElementById('record-close').addEventListener('click', () => recordModal.classList.remove('open'));
    document.getElementById('record-cancel').addEventListener('click', () => recordModal.classList.remove('open'));
    recordModal.addEventListener('click', (e) => { if (e.target === recordModal) recordModal.classList.remove('open'); });
  }

  const dnsSearch = document.getElementById('dns-search');
  if (dnsSearch) {
    const table = document.getElementById('dns-records-table');
    const rows = Array.from(table.querySelectorAll('tbody tr[data-search]'));
    const noMatches = document.getElementById('dns-no-matches');
    const countLabel = document.getElementById('dns-records-count');
    const baseLabel = countLabel.textContent.trim();

    dnsSearch.addEventListener('input', () => {
      const q = dnsSearch.value.trim().toLowerCase();
      let visible = 0;
      rows.forEach(row => {
        const match = !q || row.dataset.search.includes(q);
        row.style.display = match ? '' : 'none';
        if (match) visible++;
      });
      noMatches.style.display = (q && visible === 0) ? '' : 'none';
      countLabel.textContent = q ? `${baseLabel} (${visible} matching)` : baseLabel;
    });
  }
</script>
{% endblock %}

GODADDY_EOF
echo "Wrote modules/dns/templates/dns_index.html"


# Sanity check: every changed/added Python file must at least parse
# before we touch the running service.
PYTHON_BIN="$APP_DIR/venv/bin/python3"
if [[ ! -x "$PYTHON_BIN" ]]; then
    PYTHON_BIN="python3"
fi

PY_FILES=(
  "services/dns_providers/godaddy_service.py"
  "services/dns_providers/godaddy_provider.py"
  "services/dns_providers/registry.py"
  "config.py"
  "modules/dns/forms.py"
  "modules/dns/routes.py"
)
for f in "${PY_FILES[@]}"; do
    if ! "$PYTHON_BIN" -m py_compile "$APP_DIR/$f"; then
        echo "ERROR: $f failed to compile. Restoring all backed-up files." >&2
        for rel in services/dns_providers/registry.py config.py modules/dns/forms.py modules/dns/routes.py modules/dns/templates/dns_index.html; do
            if [[ -f "$BACKUP_DIR/$rel" ]]; then
                cp "$BACKUP_DIR/$rel" "$APP_DIR/$rel"
            fi
        done
        rm -f "$APP_DIR/services/dns_providers/godaddy_service.py" "$APP_DIR/services/dns_providers/godaddy_provider.py"
        exit 1
    fi
done
echo "Syntax check passed."

echo "Restarting $SERVICE_NAME ..."
systemctl restart "$SERVICE_NAME"
sleep 2
systemctl --no-pager status "$SERVICE_NAME" | head -n 10

echo
echo "Done. GoDaddy should now show up as a tab at /dns?provider=godaddy."
echo "To connect it you'll need a Personal Access Token from the GoDaddy"
echo "developer dashboard (My Account -> API Keys) plus the exact domain"
echo "name to manage (v3 has no way to list domains, so it's entered once"
echo "at connect time)."
echo
echo "Tail the log to confirm it started cleanly:"
echo "  journalctl -u $SERVICE_NAME -n 20 --no-pager"

