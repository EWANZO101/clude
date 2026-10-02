from flask_sqlalchemy import SQLAlchemy
from flask_login import LoginManager
from flask_wtf import CSRFProtect
from flask_migrate import Migrate
from flask_limiter import Limiter
from flask_limiter.util import get_remote_address

db = SQLAlchemy()
login_manager = LoginManager()
csrf = CSRFProtect()
migrate = Migrate()

# In-memory storage — fine for a single-process personal deployment; a
# multi-process/production deployment needs a shared backend (Redis) via
# storage_uri, since in-memory limits don't share state across workers.
limiter = Limiter(key_func=get_remote_address, default_limits=[], storage_uri="memory://")

login_manager.login_view = "auth.login"
login_manager.login_message_category = "warning"
