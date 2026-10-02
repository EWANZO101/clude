from flask import Blueprint, current_app, send_from_directory, make_response

pwa_bp = Blueprint("pwa", __name__)


@pwa_bp.route("/manifest.json")
def manifest():
    return send_from_directory(current_app.static_folder, "manifest.json", mimetype="application/manifest+json")


@pwa_bp.route("/sw.js")
def service_worker():
    resp = make_response(send_from_directory(current_app.static_folder, "sw.js", mimetype="application/javascript"))
    # Without this header, a service worker served from /static/sw.js would
    # only be allowed to control /static/* — we need it to control the app.
    resp.headers["Service-Worker-Allowed"] = "/"
    return resp
