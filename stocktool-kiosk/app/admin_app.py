"""
Admin Panel — second WSGI app (Part 1), separate port, same process.
Mirrors app/ai_app.py's pattern for the exact same reason: keeps main
kiosk API request threads free of anything Admin Panel related. Same
SQLite file, same in-memory session store (app.auth) as the main app --
see routes_ai.py's docstring for why that sharing is safe (module-level
globals in the same process, not per-Flask-app state).

Tables are created and default rows seeded by the MAIN app's
create_app() (see app/__init__.py), which always runs synchronously
before server_supervisor.py starts this sub-app's thread -- this module
only needs to bind to the already-existing DB, not create it.
"""
from flask import Flask, jsonify, render_template

from app.models import db
from app import admin_models as _admin_models  # noqa: F401 -- import for side effect: registers Admin Panel tables on db.metadata
from app.admin_models import AdminRole, AdminPage, _DEFAULT_ROLES, _DEFAULT_PAGES


def create_admin_app(main_app_config: dict) -> Flask:
    app = Flask(__name__)
    app.config.update(main_app_config)

    db.init_app(app)

    from app.routes_admin_panel import admin_panel_bp
    app.register_blueprint(admin_panel_bp)

    @app.route("/")
    def root():
        return jsonify({"service": "StockTool Kiosk Admin Panel (local)"}), 200

    @app.route("/ui/")
    @app.route("/ui/admin")
    def admin_panel_ui():
        return render_template("admin_panel.html")

    return app


def seed_admin_panel_defaults() -> None:
    """Called once from the main app's create_app(), inside an app
    context, right after db.create_all()/_auto_migrate_columns(). Not
    called from create_admin_app() itself -- by the time this sub-app's
    thread starts, the main app has already run this synchronously."""
    _seed_roles()
    _seed_pages()
    db.session.commit()


def _seed_roles() -> None:
    existing = {r.name for r in AdminRole.query.all()}
    for name, display_name, permissions, is_system in _DEFAULT_ROLES:
        if name in existing:
            continue
        role = AdminRole(name=name, display_name=display_name, is_system=is_system)
        role.permissions = permissions
        db.session.add(role)


def _seed_pages() -> None:
    existing = {p.key for p in AdminPage.query.all()}
    for key, title, route, order, allowed_roles in _DEFAULT_PAGES:
        if key in existing:
            continue
        page = AdminPage(key=key, title=title, route=route, order=order, is_system=True)
        page.allowed_roles = allowed_roles
        db.session.add(page)
