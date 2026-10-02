"""
Domain configuration shared by the hub app and the subsites app.

PUBLIC_DOMAIN   — the root domain everything lives under.
HUB_SUBDOMAIN   — which subdomain runs the main Flask app (app/__init__.py):
                  login, tickets, admin, portal, billing, licenses, etc.

Override both with environment variables in production, e.g.:
    PUBLIC_DOMAIN=yourdomain.com
    HUB_SUBDOMAIN=web

There is deliberately no real-looking default domain here — PUBLIC_DOMAIN
must be set in the environment for a real deployment. It falls back to
"localhost" so local dev without a .env doesn't crash, not to anything
that could be mistaken for a working production value.
"""
import os

PUBLIC_DOMAIN = os.environ.get("PUBLIC_DOMAIN", "localhost")
HUB_SUBDOMAIN = os.environ.get("HUB_SUBDOMAIN", "web")
CONTACT_EMAIL = os.environ.get("CONTACT_EMAIL", "hello@example.com")


def hub_base_url():
    """Full base URL of the hub (main) site, e.g. https://web.yourdomain.com"""
    return f"https://{HUB_SUBDOMAIN}.{PUBLIC_DOMAIN}"


def hub_url(path=""):
    """Absolute URL to a path on the hub site."""
    if path and not path.startswith("/"):
        path = "/" + path
    return f"{hub_base_url()}{path}"


def subdomain_base_url(sub):
    """Full base URL of one of the six service subdomains."""
    return f"https://{sub}.{PUBLIC_DOMAIN}"


def subdomain_url(sub, path=""):
    if path and not path.startswith("/"):
        path = "/" + path
    return f"{subdomain_base_url(sub)}{path}"
