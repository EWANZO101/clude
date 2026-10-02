import os
from flask import Flask, request

from config import Config
from app.extensions import db, migrate, login_manager, mail


def create_app(config_class=Config):
    app = Flask(__name__)
    app.config.from_object(config_class)

    db.init_app(app)
    migrate.init_app(app, db)
    login_manager.init_app(app)
    mail.init_app(app)

    from app.models import User, ClientUser

    @login_manager.user_loader
    def load_user(loader_id):
        # Two entirely separate login systems share one Flask-Login session
        # mechanism: a bare public_id is a staff User (unchanged, so
        # already-logged-in sessions from before the Client Portal existed
        # keep working); a "client:"-prefixed id is a ClientUser — see
        # ClientUser.get_id() / client_portal.py.
        if loader_id.startswith("client:"):
            return ClientUser.query.filter_by(public_id=loader_id[len("client:"):]).first()
        return User.query.filter_by(public_id=loader_id).first()

    from app.blueprints.auth import bp as auth_bp
    from app.blueprints.companies import bp as companies_bp
    from app.blueprints.dashboard import bp as dashboard_bp
    from app.blueprints.instances import bp as instances_bp
    from app.blueprints.inventory_ops_instances import bp as inventory_ops_instances_bp
    from app.blueprints.agent_api import bp as agent_api_bp
    from app.blueprints.releases import bp as releases_bp
    from app.blueprints.platform import bp as platform_bp
    from app.blueprints.rollouts import bp as rollouts_bp
    from app.blueprints.dev_files import bp as dev_files_bp
    from app.blueprints.client_portal import bp as client_portal_bp
    from app.blueprints.scan_portal import bp as scan_portal_bp
    from app.blueprints.products import bp as products_bp

    app.register_blueprint(auth_bp)
    app.register_blueprint(companies_bp)
    app.register_blueprint(dashboard_bp)
    app.register_blueprint(instances_bp)
    app.register_blueprint(inventory_ops_instances_bp)
    app.register_blueprint(agent_api_bp)
    app.register_blueprint(releases_bp)
    app.register_blueprint(platform_bp)
    app.register_blueprint(rollouts_bp)
    app.register_blueprint(dev_files_bp)
    app.register_blueprint(client_portal_bp)
    app.register_blueprint(scan_portal_bp)
    app.register_blueprint(products_bp)

    # Endpoints a logged-in-but-not-PIN-current user must still be able to
    # reach: the PIN setup page itself (or the redirect below would loop),
    # logout (so someone who doesn't want to set a PIN right now isn't
    # trapped), and static assets. Agent-facing endpoints are exempted as a
    # whole prefix — those are machine-to-machine (bearer-token auth, not
    # a Flask-Login session), never subject to a human PIN policy at all.
    _PIN_GATE_EXEMPT_ENDPOINTS = {"auth.pin_setup", "auth.logout", "static"}

    # DISABLED as of 2026-09-08: this was built to gate the Admin Panel's
    # own web dashboard login (owners/admins/managers/operators managing
    # the fleet at kiosksys.opslabsystems.cloud) — but the PIN requirement
    # was meant for actual kiosk-terminal usage instead, a different user
    # base entirely. The physical kiosk terminal application doesn't exist
    # as a built project in this repo yet, so there's currently nowhere
    # correct to attach this. Left in place (schema, models, admin UI) so
    # it can be pointed at the right login flow later — just not enforced
    # here in the meantime. Flip back to True to re-enable dashboard-side
    # enforcement if that's ever actually wanted.
    _PIN_GATE_ENABLED = False

    @app.before_request
    def confine_client_portal_sessions():
        """A ClientUser (Client Portal — see models.py / client_portal.py)
        is a completely separate account type from the staff User model:
        no company membership, no is_platform_admin, none of the methods
        staff-side routes/decorators (rbac.py, platform_auth.py) assume
        exist. Rather than trust every current and future staff route to
        defensively guard against the "wrong" account type reaching it,
        confine a logged-in ClientUser to client_portal's own endpoints
        (and static assets) here, once, before any of those routes run."""
        from flask import request, redirect, url_for
        from flask_login import current_user
        from app.models import ClientUser

        if not current_user.is_authenticated or not isinstance(current_user, ClientUser):
            return
        endpoint = request.endpoint
        if endpoint is None or endpoint == "static" or endpoint.startswith("client_portal."):
            return
        return redirect(url_for("client_portal.dashboard"))

    @app.before_request
    def enforce_pin_policy():
        if not _PIN_GATE_ENABLED:
            return
        from flask import request, redirect, url_for
        from flask_login import current_user

        if not current_user.is_authenticated:
            return
        endpoint = request.endpoint
        if endpoint is None or endpoint in _PIN_GATE_EXEMPT_ENDPOINTS:
            return
        if endpoint.startswith("agent_api."):
            return
        if current_user.needs_pin_setup() or current_user.pin_is_expired():
            return redirect(url_for("auth.pin_setup", next=request.url))

    from app.cli import register_cli
    register_cli(app)

    import os
    os.makedirs(app.config["UPDATE_PACKAGE_DIR"], exist_ok=True)
    os.makedirs(app.config["INSTANCE_BACKUP_DIR"], exist_ok=True)

    @app.context_processor
    def inject_globals():
        from flask import g
        from app.models import PlatformSetting, company_has_product
        company = getattr(g, "company", None)
        return {
            "company_roles": ["owner", "administrator", "manager", "operator"],
            "client_portal_auto_logout_minutes": PlatformSetting.get().client_portal_auto_logout_minutes,
            # Computed once per request here (rather than every view that
            # renders base.html having to remember to pass it) so the
            # sidebar can hide a product's nav links the moment a company
            # loses/never had access — see rbac.py's require_product_access
            # for the actual enforcement this only ever mirrors in the UI.
            "company_has_kiosk": company_has_product(company.id, "kiosk") if company else False,
            "company_has_inventory_ops": company_has_product(company.id, "inventory-ops") if company else False,
        }

    from app.datetime_utils import friendly_dt, friendly_dtstr, friendly_date, friendly_local_dt
    app.jinja_env.filters["friendly_dt"] = friendly_dt
    app.jinja_env.filters["friendly_dtstr"] = friendly_dtstr
    app.jinja_env.filters["friendly_date"] = friendly_date
    app.jinja_env.filters["friendly_local_dt"] = friendly_local_dt

    @app.route("/install.sh")
    def install_sh():
        from flask import send_from_directory
        return send_from_directory(
            os.path.join(app.root_path, "static", "installers"), "install.sh",
            mimetype="text/x-sh",
        )

    @app.route("/install.ps1")
    def install_ps1():
        from flask import send_from_directory
        return send_from_directory(
            os.path.join(app.root_path, "static", "installers"), "install.ps1",
            mimetype="text/plain",
        )

    @app.after_request
    def _strip_bogus_tar_gz_content_encoding(response):
        """Werkzeug's static-file serving (and send_file() generally) sets
        Content-Encoding from mimetypes.guess_type() — which, for any
        *.tar.gz name, reports encoding='gzip' purely because of the
        extension. Nothing here actually re-compresses the response for
        transport; the header is simply wrong. A client that honors
        Content-Encoding (Python's `requests`, which agent/self_update.py
        uses — unlike a bare `curl` without --compressed, or PowerShell's
        Invoke-WebRequest, neither of which request/apply it) then
        transparently gunzips an already-compressed archive on receipt,
        silently handing back the RAW TAR CONTENTS instead of the real
        .tar.gz bytes it asked for. This was the actual, 100% reproducible
        cause behind every 'Agent Update' checksum-mismatch failure traced
        today (see instances.py::agent_self_update and
        dev_files.py::build_agent_tarball_snapshot) — independent of, and
        found only after, the separate mutable-filename race fixed there.
        Stripping the header is strictly more correct for every client;
        install.sh/install.ps1 are unaffected either way since neither
        ever asked for gzip transport-encoding in the first place."""
        if response.content_encoding == "gzip" and request.path.endswith(".tar.gz"):
            del response.headers["Content-Encoding"]
        return response

    return app
