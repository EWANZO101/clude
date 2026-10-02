from flask_sqlalchemy import SQLAlchemy
from flask_migrate import Migrate
from flask_login import LoginManager
from flask_wtf import CSRFProtect
from flask_limiter import Limiter
from flask_limiter.util import get_remote_address
from flask_mail import Mail
from flask_cors import CORS
import redis

db = SQLAlchemy()
migrate = Migrate()
login_manager = LoginManager()
csrf = CSRFProtect()
mail = Mail()
cors = CORS()
limiter = Limiter(key_func=get_remote_address)

redis_client = None


def init_redis(app):
    global redis_client
    redis_client = redis.from_url(app.config["REDIS_URL"], decode_responses=True)
    return redis_client


login_manager.login_view = "auth.login"
login_manager.login_message_category = "info"
login_manager.session_protection = "strong"
