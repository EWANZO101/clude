import os

from flask import Flask
from flask_login import LoginManager
from flask_migrate import Migrate
from flask_sqlalchemy import SQLAlchemy
from flask_wtf import CSRFProtect

from config import config_by_name

db = SQLAlchemy()
migrate = Migrate()
login_manager = LoginManager()
csrf = CSRFProtect()


def create_app(config_name=None):
    config_name = config_name or os.environ.get("FLASK_ENV", "development")

    app = Flask(__name__, instance_relative_config=True)
    app.config.from_object(config_by_name[config_name])

    os.makedirs(app.instance_path, exist_ok=True)

    if config_name == "production":
        config_by_name["production"].validate()

    db.init_app(app)
    migrate.init_app(app, db)
    login_manager.init_app(app)
    csrf.init_app(app)

    login_manager.login_view = "auth.login"
    login_manager.login_message = "Please sign in to continue."
    login_manager.login_message_category = "info"

    from app import models  # noqa: F401 - ensures every model is registered before migrations run
    from app.models.user import User

    @login_manager.user_loader
    def load_user(user_id):
        return db.session.get(User, int(user_id))

    from app.routes.auth import auth_bp
    from app.routes.admin import admin_bp
    from app.routes.public import public_bp
    from app.routes.calendarmaker import calendarmaker_bp

    app.register_blueprint(auth_bp)
    app.register_blueprint(admin_bp)
    app.register_blueprint(public_bp)
    app.register_blueprint(calendarmaker_bp)

    register_cli(app)
    register_error_handlers(app)

    @app.context_processor
    def inject_globals():
        return {"app_name": "Scheduler"}

    return app


def register_error_handlers(app):
    from flask import flash, redirect, render_template, request, url_for
    from flask_login import current_user
    from flask_wtf.csrf import CSRFError

    @app.errorhandler(404)
    def not_found(e):
        return render_template("errors/404.html"), 404

    @app.errorhandler(500)
    def server_error(e):
        return render_template("errors/500.html"), 500

    @app.errorhandler(CSRFError)
    def csrf_error(e):
        # Without this, Flask-WTF's default is a bare, unstyled "400 Bad
        # Request" page with no nav and no way back — indistinguishable from
        # the app being broken. This turns it into a normal flash message and
        # sends the person back to the page they were on, so a save that
        # fails because a session expired reads as "try that again", not
        # "the site is down".
        flash("Your session expired — please try that again.", "error")
        if current_user.is_authenticated:
            fallback = url_for("admin.dashboard")
        else:
            fallback = url_for("public.booking_types")
        return redirect(request.referrer or fallback)


def register_cli(app):
    import click

    @app.cli.command("create-admin")
    @click.option("--email", prompt=True)
    @click.option("--name", prompt=True)
    @click.option("--password", prompt=True, hide_input=True, confirmation_prompt=True)
    def create_admin(email, name, password):
        """Create the admin user (this app supports a single admin account)."""
        from app.models.user import User

        if User.query.filter_by(email=email.lower().strip()).first():
            click.echo(f"A user with email {email} already exists.")
            return

        user = User(email=email.lower().strip(), name=name)
        user.set_password(password)
        db.session.add(user)
        db.session.commit()
        click.echo(f"Admin user '{name}' <{email}> created.")
