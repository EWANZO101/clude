"""Multi-provider SSO (Google, Microsoft, GitHub, Discord, Facebook, GitLab,
generic OIDC). Providers enable themselves when their env credentials exist."""
import os
from flask import Blueprint
from authlib.integrations.flask_client import OAuth

from .providers import PROVIDERS

sso_bp = Blueprint("sso", __name__)
oauth = OAuth()

# providers successfully registered at startup (id -> meta), for the login page
ENABLED = {}


def _env(key, suffix):
    return os.environ.get(f"{key.upper()}_{suffix}")


def init_sso(app):
    """Register OAuth clients for every provider that has credentials set."""
    oauth.init_app(app)
    ENABLED.clear()

    for pid, meta in PROVIDERS.items():
        cid = _env(pid, "CLIENT_ID")
        secret = _env(pid, "CLIENT_SECRET")
        if not cid or not secret:
            continue
        kwargs = {"client_id": cid, "client_secret": secret,
                  "client_kwargs": {"scope": meta["scope"]}}
        if meta["kind"] == "oidc":
            kwargs["server_metadata_url"] = meta["server_metadata_url"]
        else:
            kwargs["authorize_url"] = meta["authorize_url"]
            kwargs["access_token_url"] = meta["access_token_url"]
            kwargs["api_base_url"] = meta.get("api_base_url")
        try:
            oauth.register(name=pid, **kwargs)
            ENABLED[pid] = meta
        except Exception:
            pass

    # Generic OIDC (any provider) via OIDC_* env
    oidc_id = os.environ.get("OIDC_CLIENT_ID")
    oidc_secret = os.environ.get("OIDC_CLIENT_SECRET")
    oidc_meta = os.environ.get("OIDC_METADATA_URL")
    if oidc_id and oidc_secret and oidc_meta:
        try:
            oauth.register(name="oidc", client_id=oidc_id, client_secret=oidc_secret,
                           server_metadata_url=oidc_meta,
                           client_kwargs={"scope": os.environ.get("OIDC_SCOPE", "openid email profile")})
            ENABLED["oidc"] = {"label": os.environ.get("OIDC_NAME", "SSO"),
                               "color": "#334155", "text": "#ffffff", "kind": "oidc",
                               "icon": "M12 2a10 10 0 100 20 10 10 0 000-20zm0 4a3 3 0 110 6 3 3 0 010-6zm0 14a8 8 0 01-5.3-2c.1-1.6 3.5-2.5 5.3-2.5s5.2.9 5.3 2.5A8 8 0 0112 20z"}
        except Exception:
            pass

    app.config["SSO_ENABLED"] = ENABLED

from . import routes  # noqa: E402,F401
