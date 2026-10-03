import json
import logging
import os
import sys
from pathlib import Path

from dotenv import load_dotenv

BASEDIR = os.path.abspath(os.path.dirname(__file__))
# kiosk_app/.env — one level up from this file (kiosk_app/app/config.py),
# same convention as the Admin Panel's own config.py loading a repo-root
# .env. Was previously never loaded at all, so SECRET_KEY had no way to
# be overridden here short of a real OS-level env var — see the fallback
# warning below.
load_dotenv(os.path.join(BASEDIR, "..", ".env"))

# Where the Instance Agent's config sync (Admin Panel Part 3 / Agent Part 1)
# writes applied kiosk configuration — read once at startup, same as the
# original StockTool Kiosk's settings.json read pattern (see the technical
# reference doc, Section 3: "written by the MSI Setup Wizard").
#
# The Agent normally passes OPSLAB_KIOSK_CONFIG_PATH explicitly to this
# process (see agent/main.py, matching its own settings.kiosk_config_path),
# so this fallback only matters if kiosk_app is started some other way. It
# must still be OS-aware: install.ps1's DataDir is always
# %ProgramData%\OpsLabAgent, so a Linux-only default here silently resolved
# to a nonexistent path on Windows — kiosk_app would load {} and every
# agent-pushed override (tenant_name included) would look "applied" in the
# Admin Panel while never actually reaching the kiosk.
_PLATFORM_DEFAULT_KIOSK_CONFIG_PATH = (
    r"C:\ProgramData\OpsLabAgent\kiosk_config.json" if sys.platform == "win32"
    else "/etc/opslab-agent/kiosk_config.json"
)
DEFAULT_KIOSK_CONFIG_PATH = os.environ.get(
    "OPSLAB_KIOSK_CONFIG_PATH", _PLATFORM_DEFAULT_KIOSK_CONFIG_PATH
)


def load_agent_config(path: str = None) -> dict:
    """Reads the Agent-applied config file if present. Returns {} if the
    file doesn't exist yet (fresh install, no config pushed) or is
    malformed — a bad/missing config file must never prevent the kiosk
    from starting, since spec Section 37 explicitly requires the kiosk to
    keep operating through connectivity/config problems."""
    path = path or DEFAULT_KIOSK_CONFIG_PATH
    if not os.path.isfile(path):
        return {}
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except (ValueError, OSError):
        return {}


_INSECURE_DEFAULT_SECRET_KEY = "dev-insecure-key-change-me"  # never use this outside a throwaway local copy


class Config:
    SECRET_KEY = os.environ.get("SECRET_KEY", _INSECURE_DEFAULT_SECRET_KEY)
    SQLALCHEMY_DATABASE_URI = os.environ.get(
        "DATABASE_URL", f"sqlite:///{os.path.join(BASEDIR, '..', 'kiosk_local.db')}"
    )
    SQLALCHEMY_TRACK_MODIFICATIONS = False

    SESSION_COOKIE_HTTPONLY = True
    SESSION_COOKIE_SAMESITE = "Lax"


    # Agent-applied overrides, loaded once at process start. Deliberately
    # unconditional class attributes — these were previously nested inside
    # the "SECRET_KEY is still insecure" warning block below, which meant
    # they were (a) only ever set on an *insecure* install and (b) even
    # then landed as bare module globals rather than Config attributes, so
    # app.config.from_object(Config) never actually picked them up at all.
    # That left app.config["TENANT_NAME"] undefined unconditionally,
    # crashing every single template render (base.html's title/brand both
    # read tenant_name) the moment a real SECRET_KEY was configured.
    AGENT_CONFIG = load_agent_config()
    TENANT_NAME = AGENT_CONFIG.get("tenant_name", "OpsLab Kiosk")
    AUTO_LOGOUT_MINUTES = AGENT_CONFIG.get("auto_logout_minutes", 2)

    # LAN-facing Local Client Portal (see app/blueprints/client.py) — unset
    # (None) by default, meaning it's not exposed at all: the kiosk's main
    # port stays loopback-only (127.0.0.1) as it always has, and nothing
    # extra listens on the network. Agent-pushed config (client_portal_port
    # in kiosk_config.json, same pipeline as tenant_name above) takes
    # precedence since it's the only way to set this remotely on an
    # already-enrolled instance; OPSLAB_CLIENT_PORTAL_PORT remains for
    # local/manual runs (no Agent involved at all, e.g. a dev copy).
    CLIENT_PORTAL_PORT = AGENT_CONFIG.get("client_portal_port") or (
        int(os.environ["OPSLAB_CLIENT_PORTAL_PORT"])
        if os.environ.get("OPSLAB_CLIENT_PORTAL_PORT") else None
    )


if Config.SECRET_KEY == _INSECURE_DEFAULT_SECRET_KEY:
    # Loud on purpose — this key signs session cookies. Anyone who's ever
    # seen this source (and it's been zipped/shared repeatedly per this
    # project's own progress notes) can forge a valid session for any
    # account if a real deploy ever runs with the fallback still in place.
    # Real fix: set SECRET_KEY in kiosk_app/.env.
    logging.getLogger(__name__).warning(
        "SECRET_KEY is still the insecure built-in default — set a real one in "
        "kiosk_app/.env before this runs anywhere but a throwaway local copy."
    )
