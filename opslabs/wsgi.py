"""
Combined production WSGI entrypoint.

Serves the whole OpsLab Systems platform — the hub app (login, tickets,
admin, portal, billing, licenses — everything in app/__init__.py) AND the
six dedicated service subsites (subsites/__init__.py) — from a single
process, dispatching by the incoming Host header:

    web.yourdomain.com                 -> hub app
    websites.yourdomain.com            -> subsites app (website-development)
    fivem.yourdomain.com               -> subsites app (fivem-development)
    techsupport.yourdomain.com         -> subsites app (tech-support)
    hosting.yourdomain.com             -> subsites app (hosting)
    sys-setup.yourdomain.com           -> subsites app (system-setup)
    onsite.yourdomain.com              -> subsites app (onsite-it-networking)
    yourdomain.com (bare, no subdomain) -> redirected to the hub

Run with a production WSGI server, e.g.:

    gunicorn -w 4 -b 0.0.0.0:8000 wsgi:application

Put this behind a reverse proxy (nginx/Caddy) that terminates TLS for all
seven hostnames and forwards to this one process — DNS just needs an A/AAAA
(or CNAME) record per subdomain pointing at the same server; this file
handles the actual routing once requests arrive.

If you'd rather run two separate processes/servers instead (e.g. the hub
on one box and the subsites on a cheaper static-ish box), you don't need
this file at all — just run `run.py` and `run_subsites.py` separately and
point DNS + your reverse proxy at each directly.
"""
import os
from werkzeug.wrappers import Request, Response
from werkzeug.exceptions import NotFound

from app import create_app
from subsites import create_subsite_app
from subsites.config import PUBLIC_DOMAIN, HUB_SUBDOMAIN
from app.services_data import SUBDOMAINS

hub_app = create_app()
subsite_app = create_subsite_app()


def _label_from_host(host):
    if not host:
        return None
    host = host.split(":")[0]
    parts = host.split(".")
    if len(parts) < 3:
        return ""  # bare domain, e.g. "yourdomain.com" or "localhost"
    return parts[0]


class HostRouter:
    """Minimal WSGI app that dispatches to the hub or subsites app based
    on the subdomain label in the Host header."""

    def __init__(self, hub, subsites):
        self.hub = hub
        self.subsites = subsites

    def __call__(self, environ, start_response):
        host = environ.get("HTTP_HOST", "")
        label = _label_from_host(host)

        if label == HUB_SUBDOMAIN:
            return self.hub(environ, start_response)

        if label in SUBDOMAINS:
            return self.subsites(environ, start_response)

        if label == "":
            # Bare domain hit directly (no subdomain) — send to the hub.
            request = Request(environ)
            resp = Response(status=302)
            resp.headers["Location"] = f"https://{HUB_SUBDOMAIN}.{PUBLIC_DOMAIN}{request.path}"
            return resp(environ, start_response)

        # Unknown subdomain — fall back to the subsites app's own directory
        # page rather than a bare 404.
        return self.subsites(environ, start_response)


application = HostRouter(hub_app, subsite_app)

if __name__ == "__main__":
    from werkzeug.serving import run_simple
    port = int(os.environ.get("PORT", 8000))
    run_simple("0.0.0.0", port, application, use_reloader=True)
