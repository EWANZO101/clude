"""
Legacy entry routes.

  GET /enter             old Cloud-vs-Onsite chooser link — now just
                          redirects home (the gateway screen was removed
                          once On-Site became its own dedicated subdomain)
  GET /onsitesupport      on-site call-out booking page (in-person visits,
                          phone/WhatsApp) — still lives on the hub since it
                          shares the callouts/reviews backend. The
                          onsite.<PUBLIC_DOMAIN> subsite links back here.
"""
from flask import redirect, url_for, request, render_template, make_response

from . import site_bp


@site_bp.route("/enter")
def enter():
    return redirect(url_for("main.index"))


@site_bp.route("/onsitesupport")
def onsitesupport():
    return render_template("onsitesupport.html")
