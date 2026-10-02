from flask import render_template, redirect, url_for, abort

from . import services_bp
from ..services_data import SERVICES, SERVICES_ORDERED, get_service

# Slugs that already have a bespoke, real-contact-details page elsewhere in
# the app — send visitors there instead of the generic content template.
_REDIRECTS = {
    "onsite-it-networking": "site.onsitesupport",
}


@services_bp.route("/")
def index():
    """Service directory — same six cards as the homepage, standalone page."""
    return render_template("services/index.html", services=SERVICES_ORDERED)


@services_bp.route("/<slug>")
def detail(slug):
    if slug in _REDIRECTS:
        return redirect(url_for(_REDIRECTS[slug]))
    service = get_service(slug)
    if not service:
        abort(404)
    others = [(s, d) for s, d in SERVICES_ORDERED if s != slug]
    return render_template("services/detail.html", slug=slug, s=service, others=others)
