import os

from flask import Flask

from app.config import DevConfig, ProdConfig
from app.extensions import db, login_manager, csrf, migrate, limiter


def create_app(config_name=None):
    app = Flask(__name__, instance_relative_config=True)

    config_name = config_name or os.environ.get("FLASK_ENV", "development")
    app.config.from_object(ProdConfig if config_name == "production" else DevConfig)

    os.makedirs(app.instance_path, exist_ok=True)
    os.makedirs(app.config["EXPORTS_DIR"], exist_ok=True)
    os.makedirs(app.config["UPLOADS_DIR"], exist_ok=True)

    db.init_app(app)
    login_manager.init_app(app)
    csrf.init_app(app)
    migrate.init_app(app, db)
    limiter.init_app(app)

    from app.models import User

    @login_manager.user_loader
    def load_user(user_id):
        return db.session.get(User, user_id)

    from app.auth.routes import auth_bp
    from app.main.routes import main_bp
    from app.exports.routes import exports_bp
    from app.imports.routes import imports_bp
    from app.admin.routes import admin_bp
    from app.admin.decorators import enforce_force_logout

    app.register_blueprint(auth_bp)
    app.register_blueprint(main_bp)
    app.register_blueprint(exports_bp)
    app.register_blueprint(imports_bp)
    app.register_blueprint(admin_bp)

    app.before_request(enforce_force_logout)

    @app.context_processor
    def inject_globals():
        return {"app_name": "SnailyCAD Migration Platform"}

    @app.cli.command("create-admin")
    def create_admin():
        """Promote or create a user as admin: flask create-admin"""
        import getpass
        from app.models import User, Role

        email = input("Admin email: ").strip().lower()
        user = User.query.filter_by(email=email).first()

        if user:
            user.role = Role.ADMIN
            user.is_suspended = False
            db.session.commit()
            print(f"Existing user {email} promoted to admin.")
            return

        password = getpass.getpass("Password (min 10 chars): ")
        confirm = getpass.getpass("Confirm password: ")
        if password != confirm:
            print("Passwords don't match.")
            return
        if len(password) < 10:
            print("Password must be at least 10 characters.")
            return

        user = User(email=email, role=Role.ADMIN, email_verified=True)
        user.set_password(password)
        db.session.add(user)
        db.session.commit()
        print(f"Admin user {email} created.")

    return app
