"""Manual + scheduled backups: database, module metadata, and uploaded
files bundled into a single timestamped ZIP under BACKUP_FOLDER.

Supports SQLite (file copy), MySQL (mysqldump), and Postgres (pg_dump).
For MySQL/Postgres, the dump tool must be installed on the server the app
runs on (mysqldump ships with the mysql-client package; pg_dump ships
with postgresql-client) — if it's missing, this is a documented no-op
placeholder in the backup, not a silently incomplete/wrong dump.
"""
import json
import logging
import os
import shutil
import subprocess
import zipfile
from datetime import datetime
from urllib.parse import urlparse, unquote

from flask import current_app

from app.extensions import db
from app.core.backup.models import Backup

logger = logging.getLogger(__name__)


def _db_uri():
    return current_app.config.get("SQLALCHEMY_DATABASE_URI", "")


def _backend():
    uri = _db_uri()
    if uri.startswith("sqlite"):
        return "sqlite"
    if uri.startswith("mysql"):
        return "mysql"
    if uri.startswith("postgresql") or uri.startswith("postgres"):
        return "postgres"
    return "unknown"


def _sqlite_path():
    uri = _db_uri()
    if not uri.startswith("sqlite:///"):
        return None
    raw_path = uri.replace("sqlite:///", "", 1)
    if os.path.isabs(raw_path):
        return raw_path
    # Flask-SQLAlchemy resolves relative sqlite:/// paths against the app's
    # instance folder (Flask's own convention), not the process cwd.
    return os.path.join(current_app.instance_path, raw_path)


def _parsed_db_url():
    """Parses DATABASE_URL into connection parts for mysqldump/pg_dump.
    Works for both mysql+pymysql://user:pass@host:port/name and
    postgresql+psycopg2://user:pass@host:port/name style URIs."""
    uri = _db_uri()
    # Strip the SQLAlchemy driver suffix (e.g. "+pymysql") so urlparse sees a plain scheme.
    scheme = uri.split("://", 1)[0]
    plain_scheme = scheme.split("+", 1)[0]
    normalised = plain_scheme + "://" + uri.split("://", 1)[1]
    parsed = urlparse(normalised)
    return {
        "user": unquote(parsed.username or ""),
        "password": unquote(parsed.password or ""),
        "host": parsed.hostname or "localhost",
        "port": parsed.port,
        "name": (parsed.path or "").lstrip("/"),
    }


def is_sqlite():
    return _backend() == "sqlite"


def backend():
    return _backend()


def _dump_database(zf):
    """Writes the database into the zip under database/. Returns True if a
    real dump/copy happened, False if only a placeholder note was written."""
    backend = _backend()

    if backend == "sqlite":
        db_path = _sqlite_path()
        if db_path and os.path.isfile(db_path):
            zf.write(db_path, arcname="database/app.db")
            return True
        zf.writestr("database/NOTE.txt", "SQLite database file was not found on disk.")
        return False

    if backend == "mysql":
        if not shutil.which("mysqldump"):
            zf.writestr(
                "database/NOTE.txt",
                "mysqldump was not found on this server (install the mysql-client package) — "
                "this backup does not include a database dump.",
            )
            return False
        parts = _parsed_db_url()
        cmd = ["mysqldump", "-u", parts["user"], f"--password={parts['password']}",
               "-h", parts["host"]]
        if parts["port"]:
            cmd += ["-P", str(parts["port"])]
        cmd += ["--single-transaction", "--routines", "--triggers", parts["name"]]
        try:
            result = subprocess.run(cmd, capture_output=True, timeout=120)
            if result.returncode != 0:
                raise RuntimeError(result.stderr.decode(errors="replace")[:500])
            zf.writestr("database/dump.sql", result.stdout)
            return True
        except Exception as e:
            zf.writestr("database/NOTE.txt", f"mysqldump failed: {e}")
            return False

    if backend == "postgres":
        if not shutil.which("pg_dump"):
            zf.writestr(
                "database/NOTE.txt",
                "pg_dump was not found on this server (install the postgresql-client package) — "
                "this backup does not include a database dump.",
            )
            return False
        parts = _parsed_db_url()
        env = os.environ.copy()
        if parts["password"]:
            env["PGPASSWORD"] = parts["password"]
        cmd = ["pg_dump", "-U", parts["user"], "-h", parts["host"]]
        if parts["port"]:
            cmd += ["-p", str(parts["port"])]
        cmd += [parts["name"]]
        try:
            result = subprocess.run(cmd, capture_output=True, timeout=120, env=env)
            if result.returncode != 0:
                raise RuntimeError(result.stderr.decode(errors="replace")[:500])
            zf.writestr("database/dump.sql", result.stdout)
            return True
        except Exception as e:
            zf.writestr("database/NOTE.txt", f"pg_dump failed: {e}")
            return False

    zf.writestr("database/NOTE.txt", f"Unrecognised database backend for URI scheme in DATABASE_URL.")
    return False


def create_backup(source="manual"):
    backup_dir = current_app.config["BACKUP_FOLDER"]
    os.makedirs(backup_dir, exist_ok=True)
    timestamp = datetime.utcnow().strftime("%Y%m%d_%H%M%S")
    filename = f"backup_{timestamp}.zip"
    zip_path = os.path.join(backup_dir, filename)

    record = Backup(filename=filename, source=source, status="completed")

    try:
        with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
            _dump_database(zf)

            # Module metadata (manifests + install status, not the module code itself —
            # module code lives in module_packages/ and can be reinstalled from source)
            from app.core.modules.models import ModuleRecord
            modules_meta = [
                {
                    "id": m.id, "name": m.name, "version": m.version, "status": m.status,
                    "manifest_json": m.manifest_json,
                }
                for m in ModuleRecord.query.all()
            ]
            zf.writestr("modules/manifest_snapshot.json", json.dumps(modules_meta, indent=2, default=str))

            # Config snapshot (non-secret settings only — never includes SECRET_KEY,
            # SMTP credentials, or database connection strings/passwords)
            config_snapshot = {
                "backed_up_at": datetime.utcnow().isoformat() + "Z",
                "app_env": os.environ.get("FLASK_ENV", "production"),
                "database_backend": _backend(),
            }
            zf.writestr("config/config_snapshot.json", json.dumps(config_snapshot, indent=2))

            # Uploaded files (bank statements, checklist docs, etc.)
            upload_dir = current_app.config["UPLOAD_FOLDER"]
            if os.path.isdir(upload_dir):
                for root, _dirs, files in os.walk(upload_dir):
                    for f in files:
                        full = os.path.join(root, f)
                        arcname = os.path.join("uploads", os.path.relpath(full, upload_dir))
                        zf.write(full, arcname=arcname)

        record.size_bytes = os.path.getsize(zip_path)
    except Exception as e:
        logger.exception("Backup failed")
        record.status = "failed"
        record.error = str(e)
        if os.path.isfile(zip_path):
            os.remove(zip_path)

    db.session.add(record)
    db.session.commit()
    return record


def list_backups():
    return Backup.query.order_by(Backup.created_at.desc()).all()


def backup_path(record):
    return os.path.join(current_app.config["BACKUP_FOLDER"], record.filename)


def delete_backup(record):
    path = backup_path(record)
    if os.path.isfile(path):
        os.remove(path)
    db.session.delete(record)
    db.session.commit()


def restore_backup(record):
    """Extracts the database from a backup archive. For SQLite this writes
    app.db.restored next to the live database (never overwrites it live —
    swapping a SQLite file out from under an actively-connected process
    can corrupt the running app's connections; stop the app, replace the
    file, restart instead). For MySQL/Postgres this writes dump.sql
    alongside the backup and returns the path — restoring it means running
    `mysql < dump.sql` / `psql < dump.sql` yourself against the target
    database, since piping that automatically from inside a running web
    request is its own can of worms (long-running, needs the app's own DB
    connections quiesced, wrong tool for a web handler to shell out to
    unsupervised)."""
    path = backup_path(record)
    if not os.path.isfile(path):
        raise FileNotFoundError("Backup archive not found on disk.")

    backend = _backend()
    tmp_dir = os.path.join(current_app.config["BACKUP_FOLDER"], "_restore_tmp")

    if backend == "sqlite":
        db_path = _sqlite_path()
        if not db_path:
            raise RuntimeError("Could not resolve the live SQLite database path.")
        with zipfile.ZipFile(path) as zf:
            if "database/app.db" not in zf.namelist():
                raise RuntimeError("This backup doesn't contain a database file to restore.")
            extracted = zf.extract("database/app.db", path=tmp_dir)
        restored_path = db_path + ".restored"
        shutil.copyfile(extracted, restored_path)
        shutil.rmtree(tmp_dir, ignore_errors=True)
        return restored_path

    if backend in ("mysql", "postgres"):
        with zipfile.ZipFile(path) as zf:
            if "database/dump.sql" not in zf.namelist():
                raise RuntimeError("This backup doesn't contain a SQL dump to restore.")
            extracted = zf.extract("database/dump.sql", path=tmp_dir)
        restored_path = os.path.join(current_app.config["BACKUP_FOLDER"], f"{record.filename}.dump.sql")
        shutil.copyfile(extracted, restored_path)
        shutil.rmtree(tmp_dir, ignore_errors=True)
        return restored_path

    raise RuntimeError(f"Restore isn't implemented for backend: {backend}")


# ---- Scheduled backup job ----

from app.core.jobs.service import register_job  # noqa: E402


@register_job("backup.create")
def _scheduled_backup_job():
    record = create_backup(source="scheduled")
    return {"backup_id": record.id, "filename": record.filename, "status": record.status}
