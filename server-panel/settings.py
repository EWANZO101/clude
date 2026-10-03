"""
Settings blueprint — Appearance page.

This file only exists because base.html now links to url_for('settings.appearance').
Drop it next to your other blueprint modules (wherever systemctl.py / nginx.py /
users.py etc. live) and register it the same way you register those, e.g. in your
app factory:

    from settings import settings_bp
    app.register_blueprint(settings_bp)

If your other blueprints use a different pattern (Blueprint per package,
different login_required decorator, etc.) match that instead — this is
intentionally the smallest possible version so it's easy to fold into your
existing structure rather than fight it.
"""
from flask import Blueprint, render_template
from flask_login import login_required

settings_bp = Blueprint("settings", __name__, url_prefix="/settings")


@settings_bp.route("/appearance")
@login_required
def appearance():
    return render_template("settings/appearance.html")
