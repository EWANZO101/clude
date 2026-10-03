import os

from flask import Flask


def create_app():
    app = Flask(__name__)
    app.config.from_object("config.Config")
    os.makedirs(app.config["UPLOAD_FOLDER"], exist_ok=True)

    from app.extensions import db, login_manager, csrf, migrate
    db.init_app(app)
    login_manager.init_app(app)
    csrf.init_app(app)
    migrate.init_app(app, db)

    login_manager.login_view = "auth.login"

    from app.models import User

    @login_manager.user_loader
    def load_user(user_id):
        return User.query.get(user_id)

    @app.template_filter("money")
    def money_filter(amount_minor, currency="GBP"):
        symbols = {"GBP": "£", "USD": "$", "EUR": "€"}
        symbol = symbols.get(currency, currency + " ")
        sign = "-" if amount_minor < 0 else ""
        return f"{sign}{symbol}{abs(amount_minor) / 100:,.2f}"

    from app.auth.routes import auth_bp
    from app.main.routes import main_bp
    from app.bank.routes import bank_bp
    app.register_blueprint(auth_bp)
    app.register_blueprint(main_bp)
    app.register_blueprint(bank_bp)

    @app.cli.command("create-tables")
    def create_tables():
        db.create_all()
        print("Tables created.")

    return app
