from flask_sqlalchemy import SQLAlchemy
from flask_login import LoginManager
from flask_jwt_extended import JWTManager
from flask_wtf import CSRFProtect
from sqlalchemy import event
from sqlalchemy.engine import Engine

db = SQLAlchemy()
login_manager = LoginManager()
jwt = JWTManager()
csrf = CSRFProtect()

# Redirect unauthenticated web users to login page
login_manager.login_view = "auth.login"
login_manager.login_message = "Please log in to access this page."
login_manager.login_message_category = "warning"


# stocktool-kiosk is a second, separate process that connects to this exact
# same SQLite file. SQLite's default rollback-journal mode locks the whole
# database file on write, so two processes writing at (or near) the same
# moment throws "database is locked". WAL mode lets readers and a writer
# proceed concurrently instead, and busy_timeout makes any remaining brief
# contention retry instead of erroring immediately. This listener fires for
# every engine created in this process, so it applies automatically whether
# this module is imported by stocktool-admin or by stocktool-kiosk.
@event.listens_for(Engine, "connect")
def _set_sqlite_pragmas(dbapi_connection, connection_record):
    if type(dbapi_connection).__module__.startswith("sqlite3"):
        cursor = dbapi_connection.cursor()
        cursor.execute("PRAGMA journal_mode=WAL")
        cursor.execute("PRAGMA busy_timeout=5000")
        cursor.close()
