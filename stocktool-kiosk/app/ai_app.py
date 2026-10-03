"""
Local Admin AI — second WSGI app (Part 1, + Part 9's UI route).

A separate Flask app instance, bound to its own port by
server_supervisor.py, so a slow model generation can never block or
compete with the main kiosk API's request threads (items/tools/
barcode scanning need to stay snappy on a touch screen regardless of
what the AI is doing). Still the same process, same SQLite file, same
in-memory session store as the main app -- see routes_ai.py's
docstring.
"""
from flask import Flask, jsonify, render_template

from app.models import db
from app import ai_models as _ai_models  # noqa: F401 -- import for side effect: registers AI tables on db.metadata


def create_ai_app(main_app_config: dict) -> Flask:
    app = Flask(__name__)
    app.config.update(main_app_config)

    db.init_app(app)

    from app.routes_ai import ai_bp
    app.register_blueprint(ai_bp)

    @app.route("/")
    def root():
        return jsonify({"service": "StockTool Kiosk Admin AI (local)"}), 200

    # Part 9: a plain page (paste-your-token auth, no separate login) so
    # this is clickable instead of API-only -- see app/templates/admin_ai.html.
    @app.route("/ui/")
    @app.route("/ui/admin-ai")
    def admin_ai_ui():
        return render_template("admin_ai.html")

    return app
