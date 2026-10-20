"""Multi-tenancy: one dedicated MySQL database per community.

The control-plane `Community` registry (models.py) lives in this app's
normal control-plane database (SQLite) alongside everything else. Each
community's actual application data (today: Evidence, ActiveRecorder,
Alert, ExternalFeed - the webhook-ingested tables) lives in its own
MySQL database, reached through a separate SQLAlchemy engine/session
cached here, independent of Flask-SQLAlchemy's single `db.session`.

Scope, honestly: only the webhook ingestion path (xonsight/webhooks.py)
is tenant-aware right now. The browser-facing app (dashboard, evidence
viewer, cases, assistant, admin, ...) still reads/writes the control-
plane SQLite database only, and does not yet resolve or query a
community's MySQL database. Wiring that up - and migrating the existing
production data into its own Community row - is a deliberate follow-up,
not done here, to avoid a half-migrated state where data moves to MySQL
but most of the UI doesn't know to look for it there.
"""

import re
import secrets
import string

import pymysql
from flask import current_app
from sqlalchemy import create_engine
from sqlalchemy.orm import scoped_session, sessionmaker

_SLUG_RE = re.compile(r"^[a-z0-9_]{3,32}$")

_engines = {}  # community_id -> Engine
_sessions = {}  # community_id -> scoped_session


class ProvisioningError(Exception):
    pass


def slugify(name):
    """Best-effort: lowercase, keep only a-z0-9, collapse to underscores,
    clamp to 32 chars. Caller (tenancy.create_community) still has to
    check the result against _SLUG_RE and for uniqueness."""
    slug = re.sub(r"[^a-z0-9]+", "_", name.strip().lower()).strip("_")
    return slug[:32] or "community"


def _generate_token(length=48):
    alphabet = string.ascii_letters + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(length))


def _generate_password(length=32):
    # URL/shell-safe on purpose - this ends up in a MySQL connection URI
    alphabet = string.ascii_letters + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(length))


def _provisioner_connection():
    cfg = current_app.config
    if not cfg.get("MYSQL_PROVISIONER_PASSWORD"):
        raise ProvisioningError(
            "MYSQL_PROVISIONER_PASSWORD isn't set - community creation is disabled until it is."
        )
    return pymysql.connect(
        host=cfg["MYSQL_PROVISIONER_HOST"],
        port=cfg["MYSQL_PROVISIONER_PORT"],
        user=cfg["MYSQL_PROVISIONER_USER"],
        password=cfg["MYSQL_PROVISIONER_PASSWORD"],
        autocommit=False,
    )


def provision_database(db_name, db_user, db_password, db_host):
    """Creates the database + a user scoped to only it. db_name/db_user
    are never taken from raw user input unescaped - see create_community,
    which builds them from a validated slug before this is ever called.

    Creates the user for both '127.0.0.1' and 'localhost': with
    skip-name-resolve off (the default), MySQL reverse-resolves a TCP
    connection from 127.0.0.1 to the hostname 'localhost' for privilege
    matching, so a user that only exists for '127.0.0.1' gets rejected
    as that resolved identity instead - same reason xonsight_provisioner
    itself was created for both hosts above."""
    if not _SLUG_RE.match(db_name.replace("xonsight_", "", 1)) or not db_name.startswith("xonsight_"):
        raise ProvisioningError(f"refusing to provision an unexpected database name: {db_name!r}")

    conn = _provisioner_connection()
    try:
        with conn.cursor() as cur:
            cur.execute(f"CREATE DATABASE IF NOT EXISTS `{db_name}` CHARACTER SET utf8mb4")
            for host in {db_host, "localhost"}:
                cur.execute("CREATE USER IF NOT EXISTS %s@%s IDENTIFIED BY %s", (db_user, host, db_password))
                cur.execute(f"GRANT ALL PRIVILEGES ON `{db_name}`.* TO %s@%s", (db_user, host))
            # No FLUSH PRIVILEGES - GRANT/CREATE USER take effect immediately; FLUSH is only needed
            # after directly editing the mysql.* grant tables, and needs a RELOAD privilege we don't grant.
        conn.commit()
    finally:
        conn.close()


def _tenant_tables():
    """Models whose tables get created in each new tenant database. Only
    the webhook-ingested ones, matching the current scope above."""
    from .models import ActiveRecorder, Alert, Evidence, ExternalFeed

    return [Evidence.__table__, ActiveRecorder.__table__, Alert.__table__, ExternalFeed.__table__]


def _engine_for(community):
    uri = (
        f"mysql+pymysql://{community.db_user}:{community.db_password}"
        f"@{community.db_host}:{community.db_port}/{community.db_name}?charset=utf8mb4"
    )
    return create_engine(uri, pool_pre_ping=True, pool_recycle=280)


def _without_foreign_keys(table, metadata):
    """A copy of `table` on `metadata` with every foreign key stripped -
    e.g. Evidence.owner_id references users.id, but a tenant database has
    no local `users` table (User accounts are control-plane only today).
    MySQL/InnoDB validates FK targets exist at CREATE TABLE time (SQLite
    doesn't), so creating Evidence as-is in a fresh tenant database fails
    outright. The column itself is kept - webhooks.py never sets owner_id
    on the tenant-token path anyway, there's no portal account to attribute
    it to there.

    Table.to_metadata() isn't usable here: it resolves ForeignKey targets
    eagerly while building the copy, so it errors on the missing `users`
    table before there's any chance to strip the FK afterward. Building
    fresh Column objects (never passing their original ForeignKeys to the
    constructor) avoids that entirely."""
    from sqlalchemy import Column, Table

    columns = [
        Column(
            col.name,
            col.type,
            primary_key=col.primary_key,
            autoincrement=col.autoincrement,
            nullable=col.nullable,
            default=col.default,
            unique=col.unique,
        )
        for col in table.columns
    ]
    return Table(table.name, metadata, *columns)


def create_tenant_schema(community):
    """Creates this community's tables in its own database. Reuses the
    exact same model classes/columns as the control-plane app - just
    targeted at a different engine, so the schema never drifts between
    what the control plane defines and what a tenant database actually
    has (foreign keys aside - see _without_foreign_keys)."""
    from sqlalchemy import MetaData

    engine = _engine_for(community)
    metadata = MetaData()
    try:
        for table in _tenant_tables():
            _without_foreign_keys(table, metadata).create(bind=engine, checkfirst=True)
    finally:
        engine.dispose()


def get_tenant_session(community):
    """Cached per community id - safe to call on every webhook request."""
    if community.id not in _sessions:
        engine = _engine_for(community)
        _engines[community.id] = engine
        _sessions[community.id] = scoped_session(sessionmaker(bind=engine))
    return _sessions[community.id]


def remove_all_sessions(*_args):
    """Call at the end of every request (app.teardown_appcontext). These
    are plain scoped_session objects, not Flask-SQLAlchemy's db.session -
    nothing removes their thread-local session automatically unless this
    does. The cached Engine/connection pool is untouched; only the
    thread-local session registry entry is cleared."""
    for session in _sessions.values():
        session.remove()


_DOMAIN_RE = re.compile(r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$")


def create_community(name, requested_slug=None, custom_domain=None):
    """End-to-end: validates/derives a slug, generates credentials and an
    API token, provisions the MySQL database + user, creates its tables,
    saves the Community row. Raises ProvisioningError on any failure
    before the row is committed - never leaves a half-created Community
    behind in the registry (the MySQL side may still need manual
    cleanup if it fails after provisioning but before the schema step;
    that's logged, not silently swallowed)."""
    from .extensions import db
    from .models import Community

    slug = slugify(requested_slug or name)
    if not _SLUG_RE.match(slug):
        raise ProvisioningError(f"'{slug}' isn't a valid slug (a-z, 0-9, _, 3-32 chars)")
    if Community.query.filter_by(slug=slug).first() is not None:
        raise ProvisioningError(f"slug '{slug}' is already in use")

    custom_domain = (custom_domain or "").strip().lower() or None
    if custom_domain is not None:
        if not _DOMAIN_RE.match(custom_domain):
            raise ProvisioningError(f"'{custom_domain}' doesn't look like a valid domain")
        if Community.query.filter_by(custom_domain=custom_domain).first() is not None:
            raise ProvisioningError(f"domain '{custom_domain}' is already in use")

    db_name = f"xonsight_{slug}"
    db_user = f"xs_{slug}"[:32]
    db_password = _generate_password()
    db_host = current_app.config["MYSQL_PROVISIONER_HOST"]
    db_port = current_app.config["MYSQL_PROVISIONER_PORT"]

    provision_database(db_name, db_user, db_password, db_host)

    community = Community(
        name=name[:128],
        slug=slug,
        custom_domain=custom_domain,
        db_host=db_host,
        db_port=db_port,
        db_name=db_name,
        db_user=db_user,
        db_password=db_password,
        api_token=_generate_token(),
    )

    try:
        create_tenant_schema(community)
    except Exception as e:
        raise ProvisioningError(f"database was created but schema setup failed: {e}") from e

    db.session.add(community)
    db.session.commit()
    return community
