"""
Entry gateway routes.

  GET /enter?to=cloud|onsite   remember the visitor's choice, then send them on
  GET /onsitesupport           on-site / in-person services page

The gateway screen itself is shown by a before_request hook in app/__init__.py
whenever an anonymous visitor hits "/" without having chosen yet.
"""
from flask import redirect, url_for, request, render_template, make_response

from . import site_bp

# How long to remember the choice (seconds). Session-length feel: re-ask on a
# brand-new visit but never nag while they browse. ~12 hours.
ENTRY_COOKIE = "ols_entry"
ENTRY_MAXAGE = 60 * 60 * 12


@site_bp.route("/enter")
def enter():
    to = request.args.get("to")
    if to == "onsite":
        resp = make_response(redirect(url_for("site.onsitesupport")))
    else:
        resp = make_response(redirect(url_for("main.index")))
    resp.set_cookie(ENTRY_COOKIE, to or "cloud", max_age=ENTRY_MAXAGE, samesite="Lax")
    return resp


@site_bp.route("/onsitesupport")
def onsitesupport():
    # mark as entered so returning to "/" doesn't re-show the gateway
    resp = make_response(render_template("onsitesupport.html"))
    if not request.cookies.get(ENTRY_COOKIE):
        resp.set_cookie(ENTRY_COOKIE, "onsite", max_age=ENTRY_MAXAGE, samesite="Lax")
    return resp
