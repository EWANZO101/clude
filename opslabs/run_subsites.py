"""
Entrypoint for the subsites app (the six dedicated service websites)
on its own during local development.

    python3 run_subsites.py

Then visit, e.g.:
    http://127.0.0.1:5050/preview/websites
    http://127.0.0.1:5050/preview/fivem
    http://127.0.0.1:5050/preview/techsupport
    http://127.0.0.1:5050/preview/hosting
    http://127.0.0.1:5050/preview/sys-setup
    http://127.0.0.1:5050/preview/onsite

In production, this app is served on the six subdomains (see wsgi.py /
DEPLOYMENT.md for how it's combined with the hub app behind one process).
"""
import os
from subsites import create_subsite_app

app = create_subsite_app()

if __name__ == "__main__":
    port = int(os.environ.get("SUBSITES_PORT", 5050))
    debug = os.environ.get("FLASK_DEBUG", "true").lower() == "true"
    app.run(host="0.0.0.0", port=port, debug=debug)
