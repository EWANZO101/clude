from flask_sqlalchemy import SQLAlchemy
from flask_jwt_extended import JWTManager
from sqlalchemy import event
from sqlalchemy.engine import Engine

db = SQLAlchemy()
jwt = JWTManager()


# This app is the ONLY thing that ever touches the database directly — the
# admin website is a pure API client now. WAL mode is kept anyway: the
# kiosk touch-UI and the REST API are two blueprints of the same process,
# but waitress runs multiple worker threads, so more than one request can
# still hit SQLite at once.
@event.listens_for(Engine, "connect")
def _set_sqlite_pragmas(dbapi_connection, connection_record):
    if type(dbapi_connection).__module__.startswith("sqlite3"):
        cursor = dbapi_connection.cursor()
        cursor.execute("PRAGMA journal_mode=WAL")
        cursor.execute("PRAGMA busy_timeout=5000")
        cursor.close()
