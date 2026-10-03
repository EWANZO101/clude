from flask_sqlalchemy import SQLAlchemy
from flask_migrate import Migrate
from flask_login import LoginManager
from sqlalchemy import MetaData

# Explicit naming convention for every constraint/index SQLAlchemy creates.
# Without this, an unnamed constraint (e.g. a bare unique=True column) has
# no name for Alembic to reference — harmless on Postgres, but SQLite can't
# ALTER TABLE directly, so Alembic falls back to "batch mode" (recreate the
# table via a temp table) for almost any schema change, and that codepath
# specifically requires every constraint involved to have a real name. A
# migration that adds/changes a unique column on SQLite fails with
# "ValueError: Constraint must have a name" without this.
NAMING_CONVENTION = {
    "ix": "ix_%(column_0_label)s",
    "uq": "uq_%(table_name)s_%(column_0_name)s",
    "ck": "ck_%(table_name)s_%(constraint_name)s",
    "fk": "fk_%(table_name)s_%(column_0_name)s_%(referred_table_name)s",
    "pk": "pk_%(table_name)s",
}

db = SQLAlchemy(metadata=MetaData(naming_convention=NAMING_CONVENTION))
migrate = Migrate()
login_manager = LoginManager()

login_manager.login_view = "auth.login"
login_manager.login_message = "Please log in to continue."
login_manager.login_message_category = "warning"
