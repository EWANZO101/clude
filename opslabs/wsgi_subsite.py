"""
Single-service WSGI entrypoint.

Each of the six subdomains gets its OWN independent process running THIS
file, with a different SITE_KEY and a different port — not one shared
process guessing which site to serve from the Host header. That means
there is no routing/dispatch logic that could ever serve the wrong
subdomain's content: the process for fivem.<domain> can only ever render
the FiveM Development site, full stop.

SITE_KEY must be one of (see app/services_data.py -> SUBDOMAINS):
    websites | fivem | techsupport | hosting | sys-setup | onsite

Run directly (dev):
    SITE_KEY=fivem PORT=8002 python3 wsgi_subsite.py

Run in production (this is what deploy/fix_ssl.sh's systemd units use):
    SITE_KEY=fivem gunicorn -w 2 -b 127.0.0.1:8002 wsgi_subsite:application
"""
import os
from subsites import create_subsite_app

SITE_KEY = os.environ.get("SITE_KEY")
if not SITE_KEY:
    raise RuntimeError(
        "SITE_KEY environment variable is required, e.g. SITE_KEY=fivem "
        "(one of: websites, fivem, techsupport, hosting, sys-setup, onsite)"
    )

application = create_subsite_app(site_key=SITE_KEY)

if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8001))
    debug = os.environ.get("FLASK_DEBUG", "false").lower() == "true"
    application.run(host="0.0.0.0", port=port, debug=debug)
