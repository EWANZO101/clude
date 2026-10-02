import os
import sys
from flask import Flask, jsonify

from app.models import db


def _local_data_dir() -> str:
    """
    Where the local SQLite DB and config live. Uses %LOCALAPPDATA% on
    Windows (no admin rights needed, survives the .exe living in a
    read-only Program Files-style location), falling back to a local
    ./data folder when run from source (e.g. this dev sandbox).
    """
    base = os.environ.get("LOCALAPPDATA") or os.path.expanduser("~")
    path = os.path.join(base, "StockToolKiosk")
    os.makedirs(path, exist_ok=True)
    return path


def create_app(test_config: dict | None = None) -> Flask:
    app = Flask(__name__)

    data_dir = _local_data_dir()
    db_path = os.path.join(data_dir, "kiosk_local.db")

    app.config.update(
        SQLALCHEMY_DATABASE_URI=f"sqlite:///{db_path}",
        SQLALCHEMY_TRACK_MODIFICATIONS=False,
        SECRET_KEY=os.environ.get("KIOSK_SECRET_KEY", "kiosk-local-dev-key"),
        DATA_DIR=data_dir,
        CLOUD_API_BASE=os.environ.get("STOCKTOOL_CLOUD_API", "https://api-stocktool.opslabsystems.cloud"),
    )
    if test_config:
        app.config.update(test_config)

    db.init_app(app)

    with app.app_context():
        db.create_all()

    # ── Local-only REST API (Items / Tools / Projects / Barcode) ──────
    from app.routes_items import items_bp
    from app.routes_tools import tools_bp
    from app.routes_projects import projects_bp
    from app.routes_barcode import barcode_bp
    from app.routes_auth import auth_bp
    from app.routes_status import status_bp

    app.register_blueprint(items_bp)
    app.register_blueprint(tools_bp)
    app.register_blueprint(projects_bp)
    app.register_blueprint(barcode_bp)
    app.register_blueprint(auth_bp)
    app.register_blueprint(status_bp)

    @app.route("/")
    def root():
        return jsonify({
            "service": "StockTool Kiosk (local)",
            "version": app.config.get("KIOSK_VERSION", "2.0.0-dev"),
            "ui": "/ui/",
        }), 200

    from app.ui import ui_bp
    app.register_blueprint(ui_bp)

    return app
