"""
Shared helper for any Admin Panel test that needs a real database.

THIS FILE EXISTS BECAUSE OF A REAL INCIDENT (2026-09-08): a test that called
`create_app()` and then `app.config.update(SQLALCHEMY_DATABASE_URI=...)`
afterward had NO effect on which database was actually used — Flask-
SQLAlchemy 3.x resolves and binds the engine inside `db.init_app(app)`,
which runs *inside* `create_app()`, using whatever `app.config` held at
that moment (the real production `admin_panel.db`, via config.py's
environment-variable default). The test's `db.drop_all()` in tearDown
consequently dropped every table in the live production database.

The fix: pass the overridden URI in via `config_class` so it's already in
`app.config` *before* `create_app()` ever calls `db.init_app(app)`. Never
override `SQLALCHEMY_DATABASE_URI` via `app.config.update(...)` after the
fact and assume it takes effect — it silently won't.

`make_test_app()` also asserts the resulting engine is NOT pointed at the
real database file, as a second, independent guard — so a mistake in a
*future* test (e.g. constructing TestConfig wrong) fails loudly in setUp
instead of silently wiping real data again.
"""
import os

from config import Config, BASEDIR

REAL_DB_PATH = os.path.realpath(os.path.join(BASEDIR, "admin_panel.db"))


class TestConfig(Config):
    TESTING = True
    SQLALCHEMY_DATABASE_URI = "sqlite://"  # in-memory — never a file on disk
    REQUIRE_EMAIL_VERIFICATION = False
    SERVER_NAME = "testserver.local"


def make_test_app(config_class=TestConfig):
    from app import create_app
    from app.extensions import db

    app = create_app(config_class)

    # Belt-and-suspenders: fail loudly rather than silently touching the
    # real database if this ever regresses.
    engine_path = None
    with app.app_context():
        url = db.engine.url
        if url.database:
            engine_path = os.path.realpath(url.database)
    if engine_path == REAL_DB_PATH:
        raise RuntimeError(
            "Test app bound to the REAL admin_panel.db — refusing to continue. "
            "Pass the database URI via config_class to create_app(), not "
            "app.config.update() afterward (see this module's docstring)."
        )

    return app, db
