"""
Exposure/runtime settings for StockTool Kiosk.

This is deliberately separate from Flask's app.config: settings.json is
written by the MSI setup wizard (installer/SetupWizard.ps1) *before* the
app ever runs, and can be re-run later from the "StockTool Kiosk Setup"
Start Menu shortcut without reinstalling. main.py/server_supervisor.py read it at
startup to decide what host to bind to.

BIND MODES
  "local"  - bind 127.0.0.1 only. Nothing outside this machine can reach
             the API. This is the original, default-safe behavior.
  "tunnel" - still bind 127.0.0.1 only. A separate `cloudflared` Windows
             service (installed by the setup wizard) is what actually
             exposes the app, by reverse-proxying a Cloudflare Tunnel
             hostname to 127.0.0.1:<port>. The app itself never listens
             on a public interface in this mode.
  "public" - bind 0.0.0.0. The app listens directly on every interface,
             reachable at the machine's public IP on <port>. No
             encryption or perimeter auth beyond what the app itself
             provides.

SECURITY NOTE: /api/auth/login accepts a bare username or badge code
with no password (see app/routes_auth.py), and most /api/items,
/api/tools endpoints have no auth at all — that's fine on a
loopback-only local network, but it means "tunnel" and "public" modes
expose an effectively unauthenticated inventory API to whoever can
reach the hostname/IP. The setup wizard prints a warning about this;
it is not repeated/enforced here.
"""
import json
import os

VALID_MODES = ("local", "tunnel", "public")

_DEFAULTS = {
    "bind_mode": "local",
    "port": 8420,

    # Local Admin AI (see app/ai_app.py) -- runs as a second, separate
    # WSGI app in this same process/service/MSI so a slow model call can
    # never block the main kiosk API's request threads. Off by default
    # (AISettings.enabled, a DB row -- see app/ai_models.py) even though
    # the port is always reserved; opening this port just means "nothing
    # is listening on it yet" if the AI has never been turned on.
    "ai_port": 8421,

    # Port the bundled llama-server.exe subprocess listens on for actual
    # inference (see app/ai_engine.py). Separate from ai_port (the Flask
    # AI API's own port) since they're two different processes -- the
    # Flask AI app is what the Admin Panel/relay talk to; it talks to
    # this port internally on 127.0.0.1 only.
    "llama_server_port": 8422,

    # Admin Panel -- separate embedded Flask app/port, same process (see
    # app/admin_app.py / server_supervisor.py). Loopback only, same as
    # the main API and the AI ports above.
    "admin_port": 8423,
    "public_bind_host": "0.0.0.0",
    "cloudflare_tunnel_hostname": None,  # informational only; the tunnel
                                          # itself is configured in the
                                          # Cloudflare dashboard against
                                          # the token used at install time

    # --- stocktoolsetup.opslabsystems.cloud pairing/backup state ---
    # See app/cloud_setup.py and backup_loop.py. installation_token is
    # this kiosk's long-lived Bearer credential for backup uploads --
    # treat it like a password; it is never printed or logged.
    "setup_api_base": "https://stocktoolsetup.opslabsystems.cloud",
    "setup_installation_id": None,
    "setup_installation_token": None,
    "setup_paired_at": None,

    # Remote-access relay (remote.opslabsystems.cloud) — see
    # relay_client.py. Reuses the same setup_installation_token above;
    # this is just a different base URL, since the relay runs as its
    # own service on its own subdomain (see stocktool-remote/app.py for
    # why it isn't folded into setup_api_base).
    "relay_api_base": "https://remote.opslabsystems.cloud",

    # --- Sage Active / Pastel accounting integration (via CloudSolve) ---
    # See app/pastel_client.py and app/pastel_sync.py. Off by default --
    # nothing here talks to Sage until an admin fills these in and flips
    # pastel_enabled on from the Admin Panel / routes_pastel.py.
    #
    # api_base / auth_url / token_url differ per Sage Active legislation
    # environment (FR/ES/DE/PT) -- copy them from the Postman environment
    # file for your org (Quick start / 5. Test your first query in
    # Postman) or from CloudSolve's onboarding docs. api_base is the
    # GraphQL host WITHOUT the /graphql suffix; the client appends it.
    "pastel_enabled": False,
    "pastel_legislation": None,          # "FR" | "ES" | "DE" | "PT"
    "pastel_api_base": None,             # e.g. https://api.fr.active.sage.com
    "pastel_auth_url": None,             # OAuth2 /connect/authorize endpoint
    "pastel_token_url": None,            # OAuth2 /connect/token endpoint
    "pastel_client_id": None,
    "pastel_client_secret": None,
    "pastel_subscription_key": None,     # x-api-key header value
    "pastel_redirect_uri": None,         # must match the callback URL registered in your Sage Active app

    # Populated automatically by the OAuth flow (app/routes_pastel.py) --
    # not meant to be hand-edited.
    "pastel_organization_id": None,
    "pastel_access_token": None,
    "pastel_refresh_token": None,
    "pastel_token_expires_at": None,     # unix timestamp

    # Accounting mapping -- which journal/account codes local usage gets
    # posted against when push_usage_entries() runs. These are business
    # codes in YOUR chart of accounts, not IDs, since createAccountingEntryUsingCodes
    # is what the sync engine uses.
    "pastel_usage_journal_code": None,   # e.g. "OD" / a general/miscellaneous operations journal
    "pastel_usage_expense_account_code": None,  # debit: consumables/stock-usage expense account
    "pastel_stock_contra_account_code": None,   # credit: stock/inventory account

    # How often the background loop runs a two-way sync, in seconds.
    "pastel_sync_interval_seconds": 900,  # 15 minutes
}


def _settings_path(data_dir: str) -> str:
    return os.path.join(data_dir, "settings.json")


def load_settings(data_dir: str) -> dict:
    path = _settings_path(data_dir)
    settings = dict(_DEFAULTS)
    if os.path.isfile(path):
        try:
            with open(path, "r", encoding="utf-8") as f:
                on_disk = json.load(f)
            # FIXED: this used to only merge on_disk into settings at
            # all if bind_mode was present and one of VALID_MODES --
            # any file missing that one key (or with an unexpected
            # value in it) silently discarded EVERYTHING else in the
            # file, including setup_installation_token, relay_api_base,
            # every setting. That's a much bigger blast radius than
            # "bind_mode was invalid" should ever cause. Now the merge
            # always happens (json.load() above already guarantees this
            # is at least syntactically valid JSON), and only bind_mode
            # itself gets validated and corrected if necessary.
            settings.update(on_disk)
            if settings.get("bind_mode") not in VALID_MODES:
                settings["bind_mode"] = _DEFAULTS["bind_mode"]
        except (OSError, ValueError):
            # Corrupt/unreadable settings.json -> fall back to safe
            # local-only defaults rather than crash the kiosk.
            pass
    return settings


def save_settings(data_dir: str, settings: dict) -> None:
    os.makedirs(data_dir, exist_ok=True)
    path = _settings_path(data_dir)
    tmp_path = path + ".tmp"
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(settings, f, indent=2)
    os.replace(tmp_path, path)  # atomic on Windows too


def resolve_bind_host(settings: dict) -> str:
    """What the embedded server should actually app.run()/serve() on."""
    mode = settings.get("bind_mode", "local")
    if mode == "public":
        return settings.get("public_bind_host", "0.0.0.0")
    # "local" and "tunnel" both stay on loopback — cloudflared is what
    # exposes "tunnel" mode, not the app's own bind address.
    return "127.0.0.1"
