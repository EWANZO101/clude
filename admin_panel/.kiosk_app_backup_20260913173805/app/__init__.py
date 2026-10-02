from datetime import datetime, timezone

from flask import Flask, jsonify, render_template

from app.config import Config
from app.extensions import db, migrate, login_manager
from app import version


def create_app(config_class=Config):
    app = Flask(__name__)
    app.config.from_object(config_class)

    db.init_app(app)
    migrate.init_app(app, db)
    login_manager.init_app(app)

    from app.models import LocalUser

    @login_manager.user_loader
    def load_user(user_id):
        return LocalUser.query.get(int(user_id))

    from app.blueprints.auth import bp as auth_bp
    from app.blueprints.dashboard import bp as dashboard_bp
    from app.blueprints.items import bp as items_bp
    from app.blueprints.tools import bp as tools_bp
    from app.blueprints.projects import bp as projects_bp
    from app.blueprints.scan import bp as scan_bp
    from app.blueprints.wire import bp as wire_bp
    from app.blueprints.admin import bp as admin_bp
    from app.blueprints.stock_audit import bp as stock_audit_bp
    from app.blueprints.sync_api import bp as sync_api_bp
    from app.blueprints.inventory import bp as inventory_bp
    from app.blueprints.client import bp as client_bp

    app.register_blueprint(auth_bp)
    app.register_blueprint(dashboard_bp)
    app.register_blueprint(items_bp)
    app.register_blueprint(tools_bp)
    app.register_blueprint(projects_bp)
    app.register_blueprint(scan_bp)
    app.register_blueprint(wire_bp)
    app.register_blueprint(admin_bp)
    app.register_blueprint(stock_audit_bp)
    app.register_blueprint(sync_api_bp)
    app.register_blueprint(inventory_bp)
    app.register_blueprint(client_bp)

    @app.route("/health")
    def health():
        """Polled by the Instance Agent's health_check.py
        (kiosk_health_check_url). Deliberately unauthenticated and cheap —
        a real DB round-trip (not just 'the process is up') without doing
        anything expensive enough to matter under frequent polling."""
        try:
            db.session.execute(db.text("SELECT 1"))
            db_ok = True
        except Exception:
            db_ok = False

        status = "ok" if db_ok else "degraded"
        code = 200 if db_ok else 503
        return jsonify({
            "status": status,
            "version": version.VERSION,
            "database": "ok" if db_ok else "unreachable",
        }), code

    @app.route("/privacy")
    def privacy_notice():
        """Public POPIA privacy notice — deliberately unauthenticated (like
        /health above) so staff can read it without needing to already be
        logged in, and so it can be linked straight from the login page."""
        from app.config import load_agent_config
        cfg = load_agent_config()
        return render_template(
            "privacy_notice.html",
            configured_retention_days=cfg.get("activity_log_retention_days"),
            information_officer_contact=cfg.get("information_officer_contact"),
        )

    @app.errorhandler(403)
    def forbidden(e):
        return render_template("errors/403.html"), 403

    from app.cli import register_cli
    register_cli(app)

    @app.context_processor
    def inject_globals():
        from flask import session
        from flask_login import current_user
        from app.permissions import visible_items_for, ADMIN_ROLES
        from app.models import StockAudit, NavEntry, RoleSidebarPermission
        visible = visible_items_for(current_user.role) if current_user.is_authenticated else set()
        open_audit = None
        if current_user.is_authenticated:
            open_audit = StockAudit.query.filter_by(status="open").first()

        # Sidebar builder (Track 2, see /root/.claude/plans/sprightly-
        # meandering-whisper.md) — every custom ItemType's auto-generated
        # NavEntry (key "type:<slug>"), grouped by section, filtered by
        # this role's visibility. Checked directly against
        # RoleSidebarPermission rather than via visible_items_for()/
        # `visible` above — that helper only ever iterates the static
        # SIDEBAR_ITEMS list, so a "type:<slug>" key (never a member of
        # that list) would otherwise never come back as visible no matter
        # what a role's actual permission row says. Built-in NavEntry rows
        # are NOT rendered from here — base.html keeps its existing
        # hardcoded Inventory/Welding Wire/Jobs/Audit blocks unchanged;
        # this only ever adds NEW groups for custom types.
        custom_nav_sections = {}
        if current_user.is_authenticated:
            custom_rows = (
                NavEntry.query.filter(NavEntry.key.like("type:%"))
                .order_by(NavEntry.section, NavEntry.sort_order).all()
            )
            for row in custom_rows:
                if not RoleSidebarPermission.get_or_default(current_user.role, row.key):
                    continue
                custom_nav_sections.setdefault(row.section, []).append(
                    {"type_key": row.key[len("type:"):], "label": row.label, "key": row.key}
                )

        return {
            "tenant_name": app.config["TENANT_NAME"],
            "active_project_name": session.get("active_project_name"),
            "visible_sidebar_items": visible,
            "is_admin_role": current_user.is_authenticated and current_user.role in ADMIN_ROLES,
            "open_stock_audit": open_audit,
            "auto_logout_minutes": app.config.get("AUTO_LOGOUT_MINUTES", 2),
            "custom_nav_sections": custom_nav_sections,
            "app_version": version.VERSION,
            "app_released": version.RELEASED,
            "current_year": datetime.now(timezone.utc).year,
        }

    return app
