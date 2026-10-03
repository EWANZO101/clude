"""
Ops Labs - Multi-service Flask platform
Build. Support. Scale. Together.
"""
import os
from flask import Flask
from flask_sqlalchemy import SQLAlchemy
from flask_login import LoginManager
from flask_mail import Mail
from flask_migrate import Migrate

db = SQLAlchemy()
login_manager = LoginManager()
mail = Mail()
migrate = Migrate()



def create_app(config_name="default"):
    app = Flask(__name__, instance_relative_config=True)

    # ------- Core config -------
    app.config["SECRET_KEY"] = os.environ.get("SECRET_KEY", "change-me-in-production-please")
    app.config["SQLALCHEMY_DATABASE_URI"] = os.environ.get(
        "DATABASE_URL", f"sqlite:///{os.path.join(app.instance_path, 'opslabs.db')}"
    )
    app.config["SQLALCHEMY_TRACK_MODIFICATIONS"] = False

    # ------- Billing / Stripe (optional until keys are set) -------
    app.config["STRIPE_SECRET_KEY"] = os.environ.get("STRIPE_SECRET_KEY", "")
    app.config["STRIPE_PUBLISHABLE_KEY"] = os.environ.get("STRIPE_PUBLISHABLE_KEY", "")
    app.config["STRIPE_WEBHOOK_SECRET"] = os.environ.get("STRIPE_WEBHOOK_SECRET", "")
    app.config["DISPLAY_TIMEZONE"] = os.environ.get("DISPLAY_TIMEZONE", "Europe/London")

    # ------- Mail (for password reset emails) -------
    app.config["MAIL_SERVER"] = os.environ.get("MAIL_SERVER", "smtp.gmail.com")
    app.config["MAIL_PORT"] = int(os.environ.get("MAIL_PORT", 587))
    app.config["MAIL_USE_TLS"] = os.environ.get("MAIL_USE_TLS", "true").lower() == "true"
    app.config["MAIL_USERNAME"] = os.environ.get("MAIL_USERNAME")
    app.config["MAIL_PASSWORD"] = os.environ.get("MAIL_PASSWORD")
    app.config["MAIL_DEFAULT_SENDER"] = os.environ.get(
        "MAIL_DEFAULT_SENDER", "noreply@opslabs.local"
    )

    # ------- Discord bot bridge -------
    app.config["DISCORD_BOT_URL"] = os.environ.get("DISCORD_BOT_URL", "http://127.0.0.1:5005")
    app.config["DISCORD_BOT_TOKEN"] = os.environ.get("DISCORD_BOT_TOKEN", "")
    app.config["DISCORD_BRIDGE_KEY"] = os.environ.get(
        "DISCORD_BRIDGE_KEY", "shared-secret-change-me"
    )
    app.config["DISCORD_GUILD_ID"] = os.environ.get("DISCORD_GUILD_ID", "")

    # Make sure instance dir exists
    try:
        os.makedirs(app.instance_path)
    except OSError:
        pass

    # ------- Init extensions -------
    db.init_app(app)
    login_manager.init_app(app)
    mail.init_app(app)
    migrate.init_app(app, db)

    login_manager.login_view = "auth.login"
    login_manager.login_message_category = "warning"

    from .models import User

    @login_manager.user_loader
    def load_user(uid):
        return User.query.get(int(uid))

    # ------- Blueprints -------
    from .routes.main import main_bp
    from .routes.auth import auth_bp
    from .routes.tickets import tickets_bp
    from .routes.admin import admin_bp
    from .routes.admin_content   import content_bp
    from .routes.admin_settings  import settings_bp
    from .routes.bridge import bridge_bp
    from .routes.api import api_bp
    from . import models_api  # noqa: F401  (registers ApiKey on metadata)
    from . import models_admin
    from . import models_business  # noqa: F401  (portal/CRM/billing tables)
    from . import admin_seeds
    from . import licenses
    from .portal import portal_bp
    from .billing import billing_bp
    from .quickjobs import quickjobs_bp
    from .reviews import reviews_bp
    from .callouts import callouts_bp
    from .site import site_bp
    from .sso import sso_bp, init_sso
    from .partners import partners_bp

    app.register_blueprint(main_bp)
    app.register_blueprint(auth_bp, url_prefix="/auth")
    app.register_blueprint(tickets_bp, url_prefix="/tickets")
    app.register_blueprint(admin_bp, url_prefix="/admin")
    app.register_blueprint(content_bp,  url_prefix="/admin/content")
    app.register_blueprint(settings_bp, url_prefix="/admin/settings")
    app.register_blueprint(bridge_bp, url_prefix="/bridge")
    app.register_blueprint(api_bp, url_prefix="/api/v1")
    app.register_blueprint(portal_bp, url_prefix="/portal")
    app.register_blueprint(billing_bp, url_prefix="/billing")
    app.register_blueprint(quickjobs_bp)  # /admin/jobs (gated) + /j/<token> (public)
    app.register_blueprint(reviews_bp)    # /reviews (public) + /admin/reviews (gated)
    app.register_blueprint(callouts_bp)   # /callout (public) + /admin/callouts (gated)
    app.register_blueprint(site_bp)       # /enter + /onsitesupport (+ gateway at /)
    app.register_blueprint(sso_bp, url_prefix="/auth/sso")
    app.register_blueprint(partners_bp)
    init_sso(app)                         # enable any providers with env credentials

    # License Manager (/licenses/) — mounted as sub-package
    licenses.register(app)

    # ── Deterministic template resolution (env-independent) ──────────────
    # The License Manager reassigns app.jinja_loader to a ChoiceLoader; on some
    # Flask builds that loader fails to resolve OpsLabs templates at all (e.g.
    # "TemplateNotFound: index.html") and on all builds it shadows the OpsLabs
    # admin pages. We sidestep it by setting the Jinja environment loader
    # ourselves, from absolute paths: licenses templates first (so /licenses
    # keeps its own pages), OpsLabs templates second (so the main site, portal,
    # quick jobs and admin always resolve). The admin name-collision is removed
    # separately by the installer (admin/ops_*.html), so order is safe here.
    import os as _os
    from jinja2 import ChoiceLoader as _CL, FileSystemLoader as _FSL
    _app_tpl = _os.path.join(app.root_path, app.template_folder or "templates")
    _lic_tpl = _os.path.join(app.root_path, "licenses", "templates")
    _loaders = []
    if _os.path.isdir(_lic_tpl):
        _loaders.append(_FSL(_lic_tpl))
    _loaders.append(_FSL(_app_tpl))
    app.jinja_env.loader = _CL(_loaders)

    # ── Restore OpsLabs as the ACTIVE login manager ──────────────────────
    # licenses' _setup_independent_login() calls lic_lm.init_app(app) last,
    # which makes its AdminUser-only loader the app-wide manager and breaks
    # current_user on every non-/licenses page (tickets, admin, portal).
    # Its own scope-aware wrapper on THIS manager is meant to be active, so
    # we re-assert it, and add a scoped unauthorized redirect so /licenses
    # still points at the licenses login.
    login_manager.init_app(app)
    login_manager.login_view = "auth.login"

    @login_manager.unauthorized_handler
    def _scoped_unauthorized():
        from flask import request, redirect, url_for
        if request.path.startswith("/licenses"):
            return redirect(url_for("lic_auth.login", next=request.path))
        return redirect(url_for("auth.login", next=request.path))

    # ------- Create tables + seed -------
    with app.app_context():
        db.create_all()
        _ensure_columns()
        _seed_defaults()

    @app.context_processor
    def _inject_sso():
        try:
            from .sso import ENABLED
            return dict(sso_providers=ENABLED)
        except Exception:
            return dict(sso_providers={})

    @app.before_request
    def _entry_gateway():
        """Show the Cloud-vs-Onsite chooser the first time an anonymous visitor
        lands on '/'. Once they choose (cookie set) or if they're logged in,
        the normal homepage is served as usual."""
        from flask import request, render_template
        from flask_login import current_user
        if (request.method == "GET" and request.path == "/"
                and not request.cookies.get("ols_entry")
                and not current_user.is_authenticated):
            return render_template("gateway.html")

    @app.context_processor
    def _inject_admin_helpers():
        from .models_admin import Setting, SiteContent
        return dict(setting=Setting.get, content=SiteContent.get_data)

    @app.context_processor
    def _inject_reviews():
        """Approved reviews for the homepage slider + a nav count. Defensive:
        never breaks page rendering if the table isn't there yet."""
        try:
            from .models_business import Testimonial
            items = (Testimonial.query.filter_by(approved=True)
                     .order_by(Testimonial.created_at.desc()).limit(12).all())
            return dict(site_reviews=items, site_reviews_count=len(items))
        except Exception:
            return dict(site_reviews=[], site_reviews_count=0)

    return app


def _ensure_columns():
    """Lightweight idempotent migration: add new quick_jobs payment columns
    to an existing table (db.create_all() won't alter existing tables).
    Works on SQLite and PostgreSQL; safe to run on every boot."""
    from sqlalchemy import inspect, text
    try:
        insp = inspect(db.engine)
        if "quick_jobs" not in insp.get_table_names():
            return
        cols = {c["name"] for c in insp.get_columns("quick_jobs")}
        adds = {
            "is_paid": "ALTER TABLE quick_jobs ADD COLUMN is_paid BOOLEAN",
            "paid_at": "ALTER TABLE quick_jobs ADD COLUMN paid_at TIMESTAMP",
            "paid_via": "ALTER TABLE quick_jobs ADD COLUMN paid_via VARCHAR(20)",
            "stripe_session_id": "ALTER TABLE quick_jobs ADD COLUMN stripe_session_id VARCHAR(160)",
            "stripe_payment_intent": "ALTER TABLE quick_jobs ADD COLUMN stripe_payment_intent VARCHAR(160)",
            "client_phone": "ALTER TABLE quick_jobs ADD COLUMN client_phone VARCHAR(40)",
            "allow_client_edits": "ALTER TABLE quick_jobs ADD COLUMN allow_client_edits BOOLEAN",
        }
        added = False
        for name, ddl in adds.items():
            if name not in cols:
                try:
                    db.session.execute(text(ddl))
                    db.session.commit()
                    added = True
                except Exception:
                    db.session.rollback()
        if added:
            for fixup in ("UPDATE quick_jobs SET is_paid = 0 WHERE is_paid IS NULL",
                          "UPDATE quick_jobs SET allow_client_edits = 1 WHERE allow_client_edits IS NULL"):
                try:
                    db.session.execute(text(fixup))
                    db.session.commit()
                except Exception:
                    db.session.rollback()
    except Exception:
        pass

    # testimonials.posted_to_discord
    try:
        insp = inspect(db.engine)
        if "testimonials" in insp.get_table_names():
            tcols = {c["name"] for c in insp.get_columns("testimonials")}
            if "posted_to_discord" not in tcols:
                try:
                    db.session.execute(text("ALTER TABLE testimonials ADD COLUMN posted_to_discord BOOLEAN"))
                    db.session.commit()
                    # existing reviews predate the webhook — mark them un-posted
                    db.session.execute(text("UPDATE testimonials SET posted_to_discord = 0 WHERE posted_to_discord IS NULL"))
                    db.session.commit()
                except Exception:
                    db.session.rollback()
    except Exception:
        pass


def _seed_defaults():
    """Seed default admin + default ticket categories + Ops Labs company."""
    from .models import User, Company, TicketCategory
    from werkzeug.security import generate_password_hash

    # Default admin
    if not User.query.filter_by(username="admin").first():
        admin = User(
            username="admin",
            email="admin@opslabs.local",
            password_hash=generate_password_hash("admin"),
            role="admin",
            is_active=True,
        )
        db.session.add(admin)

    # Default company
    if not Company.query.filter_by(slug="opslabs").first():
        company = Company(
            name="Ops Labs",
            slug="opslabs",
            tagline="Build. Support. Scale. Together.",
            description="One community. Multiple services. Endless possibilities.",
            is_active=True,
        )
        db.session.add(company)
        db.session.flush()

        # Default categories
        defaults = [
            ("Website Development", "Custom websites and updates"),
            ("FiveM Development", "Scripts, maps, resources, and more"),
            ("Tech Support", "Fix issues and get the help you need"),
            ("Hosting Support", "Reliable hosting solutions"),
            ("System Setup", "Setup and optimize your systems"),
            ("Other", "Anything tech related"),
        ]
        for name, desc in defaults:
            db.session.add(
                TicketCategory(name=name, description=desc, company_id=company.id)
            )

    admin_seeds.seed_admin_defaults(db)
    licenses.seed_defaults()
    db.session.commit()
