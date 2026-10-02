import os
from flask import Flask
from flask_sqlalchemy import SQLAlchemy
from flask_login import LoginManager
from datetime import timedelta

db = SQLAlchemy()
login_manager = LoginManager()


def create_app():
    app = Flask(__name__)
    app.config['SECRET_KEY'] = os.environ.get('SECRET_KEY', 'change-me-in-prod')
    app.config['SQLALCHEMY_DATABASE_URI'] = os.environ.get(
        'DATABASE_URL', 'sqlite:///' + os.path.join(os.path.dirname(os.path.dirname(__file__)), 'teamtreck.db')
    )
    app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False
    app.config['PERMANENT_SESSION_LIFETIME'] = timedelta(days=7)

    db.init_app(app)
    login_manager.init_app(app)
    login_manager.login_view = 'auth.login'

    from app.models.user import User

    @login_manager.user_loader
    def load_user(user_id):
        return User.query.get(int(user_id))

    @login_manager.request_loader
    def load_user_from_token(request):
        # Allows the desktop agent to call session-protected routes (e.g. /time/start)
        # using its Bearer token instead of a browser session cookie.
        auth = request.headers.get('Authorization', '')
        if not auth.startswith('Bearer '):
            return None
        token = auth[len('Bearer '):].strip()
        if not token:
            return None
        return User.query.filter_by(api_token=token).first()

    from app.routes.auth import auth_bp
    from app.routes.main import main_bp
    from app.routes.team import team_bp
    from app.routes.time import time_bp
    from app.routes.timesheets import timesheets_bp, format_hms
    from app.routes.projects import projects_bp
    from app.routes.billing import billing_bp
    from app.routes.dashboard import dashboard_bp
    from app.routes.analytics import analytics_bp
    from app.routes.reports import reports_bp
    from app.routes.planning import planning_bp
    from app.routes.monitoring import monitoring_bp
    from app.routes.url_tracking import url_tracking_bp
    from app.routes.sync import sync_bp

    app.register_blueprint(auth_bp)
    app.register_blueprint(main_bp)
    app.register_blueprint(team_bp)
    app.register_blueprint(time_bp)
    app.register_blueprint(timesheets_bp)
    app.register_blueprint(projects_bp)
    app.register_blueprint(billing_bp)
    app.register_blueprint(dashboard_bp)
    app.register_blueprint(analytics_bp)
    app.register_blueprint(reports_bp)
    app.register_blueprint(planning_bp)
    app.register_blueprint(monitoring_bp)
    app.register_blueprint(url_tracking_bp)
    app.register_blueprint(sync_bp)

    app.jinja_env.filters['hms'] = format_hms

    with app.app_context():
        db.create_all()
        _seed_default_admin()

    return app


def _seed_default_admin():
    from app.models.user import User
    from app.models.team import Team
    if User.query.first() is None:
        team = Team(name='Default Team')
        db.session.add(team)
        db.session.flush()
        admin = User(
            name='Admin',
            email='admin@teamtreck.local',
            role='admin',
            team_id=team.id,
        )
        admin.set_password('changeme123')
        db.session.add(admin)
        db.session.commit()
