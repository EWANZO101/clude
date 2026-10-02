import os
import re
import tempfile
from datetime import datetime

from flask import Blueprint, Response, current_app, jsonify, render_template, request
from flask_login import current_user

from services import database_service as dbsvc
from utils.permissions import require_permission

databases_bp = Blueprint("databases", __name__, template_folder="templates")


def _ok(**data):
    return jsonify({"ok": True, **data})


def _fail(exc, status=400):
    return jsonify({"ok": False, "error": str(exc)}), status


def _body():
    return request.get_json(silent=True) or {}


def _audit(action, detail):
    """Every write goes to the panel log so there's a trail of who dropped what."""
    current_app.logger.warning("DB %s by %s: %s", action, getattr(current_user, "username", "?"), detail)


@databases_bp.route("/databases")
@require_permission("databases.manage")
def index():
    return render_template("databases_index.html", installed=dbsvc.is_installed())


# ---------------------------------------------------------------- server + databases

@databases_bp.route("/databases/api/overview")
@require_permission("databases.manage")
def api_overview():
    try:
        return _ok(server=dbsvc.server_info(), databases=dbsvc.list_databases(),
                   presets=list(dbsvc.PRIVILEGE_PRESETS.keys()))
    except dbsvc.DatabaseError as exc:
        return _fail(exc)


@databases_bp.route("/databases/api/charsets")
@require_permission("databases.manage")
def api_charsets():
    try:
        return _ok(charsets=dbsvc.list_charsets())
    except dbsvc.DatabaseError as exc:
        return _fail(exc)


@databases_bp.route("/databases/api/db/create", methods=["POST"])
@require_permission("databases.manage")
def api_db_create():
    d = _body()
    try:
        dbsvc.create_database((d.get("name") or "").strip(), d.get("charset") or "utf8mb4", d.get("collation") or None)
        _audit("create database", d.get("name"))
        return _ok()
    except dbsvc.DatabaseError as exc:
        return _fail(exc)


@databases_bp.route("/databases/api/db/drop", methods=["POST"])
@require_permission("databases.manage")
def api_db_drop():
    d = _body()
    try:
        dbsvc.drop_database(d.get("name") or "")
        _audit("DROP database", d.get("name"))
        return _ok()
    except dbsvc.DatabaseError as exc:
        return _fail(exc)


# ---------------------------------------------------------------- tables

@databases_bp.route("/databases/api/tables")
@require_permission("databases.manage")
def api_tables():
    try:
        return _ok(tables=dbsvc.list_tables(request.args.get("db", "")))
    except dbsvc.DatabaseError as exc:
        return _fail(exc)


@databases_bp.route("/databases/api/structure")
@require_permission("databases.manage")
def api_structure():
    try:
        return _ok(**dbsvc.table_structure(request.args.get("db", ""), request.args.get("table", "")))
    except dbsvc.DatabaseError as exc:
        return _fail(exc)


@databases_bp.route("/databases/api/table/<action>", methods=["POST"])
@require_permission("databases.manage")
def api_table_action(action):
    d = _body()
    db_name, table = d.get("db") or "", d.get("table") or ""
    try:
        if action == "drop":
            dbsvc.drop_table(db_name, table)
        elif action == "truncate":
            dbsvc.truncate_table(db_name, table)
        else:
            return _fail("Unknown action.", 404)
        _audit(f"{action.upper()} table", f"{db_name}.{table}")
        return _ok()
    except dbsvc.DatabaseError as exc:
        return _fail(exc)


# ---------------------------------------------------------------- rows

@databases_bp.route("/databases/api/rows")
@require_permission("databases.manage")
def api_rows():
    a = request.args
    try:
        return _ok(**dbsvc.browse_rows(a.get("db", ""), a.get("table", ""), a.get("page", 1), a.get("per_page", 50),
                                       a.get("sort"), a.get("dir", "asc"), a.get("q", "")))
    except (dbsvc.DatabaseError, ValueError) as exc:
        return _fail(exc)


@databases_bp.route("/databases/api/row/<action>", methods=["POST"])
@require_permission("databases.manage")
def api_row_action(action):
    d = _body()
    db_name, table = d.get("db") or "", d.get("table") or ""
    try:
        if action == "insert":
            result = dbsvc.insert_row(db_name, table, d.get("values"))
        elif action == "update":
            result = dbsvc.update_row(db_name, table, d.get("match"), d.get("values"))
        elif action == "delete":
            result = dbsvc.delete_row(db_name, table, d.get("match"))
        else:
            return _fail("Unknown action.", 404)
        _audit(f"row {action}", f"{db_name}.{table}")
        return _ok(**result)
    except dbsvc.DatabaseError as exc:
        return _fail(exc)


# ---------------------------------------------------------------- SQL console

@databases_bp.route("/databases/api/query", methods=["POST"])
@require_permission("databases.manage")
def api_query():
    d = _body()
    try:
        result = dbsvc.run_query(d.get("db") or None, d.get("sql") or "")
        _audit("query", f"[{d.get('db') or '-'}] {(d.get('sql') or '')[:300]!r}")
        return _ok(**result)
    except dbsvc.DatabaseError as exc:
        return _fail(exc)


# ---------------------------------------------------------------- export / import

@databases_bp.route("/databases/export")
@require_permission("databases.manage")
def export():
    db_name, table = request.args.get("db", ""), request.args.get("table") or None
    try:
        dbsvc.qi(db_name)
        if table:
            dbsvc.qi(table)
        stream = dbsvc.export_stream(db_name, table)
    except dbsvc.DatabaseError as exc:
        return _fail(exc)
    safe = re.sub(r"[^A-Za-z0-9_.-]", "_", f"{db_name}{'.' + table if table else ''}")
    filename = f"{safe}-{datetime.now().strftime('%Y%m%d-%H%M%S')}.sql"
    _audit("export", f"{db_name}{'.' + table if table else ''}")
    return Response(stream, mimetype="application/sql",
                    headers={"Content-Disposition": f'attachment; filename="{filename}"',
                             "X-Accel-Buffering": "no"})


@databases_bp.route("/databases/api/import", methods=["POST"])
@require_permission("databases.manage")
def api_import():
    db_name = request.form.get("db", "")
    upload = request.files.get("file")
    if not upload or not upload.filename:
        return _fail("No file uploaded.")
    if not upload.filename.lower().endswith((".sql", ".sql.gz", ".gz")):
        return _fail("Upload a .sql or .sql.gz file.")
    fd, tmp_path = tempfile.mkstemp(prefix="panel-import-", suffix=".sql")
    os.close(fd)
    try:
        upload.save(tmp_path)
        result = dbsvc.import_sql(db_name, tmp_path, upload.filename)
        _audit("import", f"{upload.filename} -> {db_name}")
        return _ok(**result)
    except dbsvc.DatabaseError as exc:
        return _fail(exc)
    finally:
        try:
            os.remove(tmp_path)
        except OSError:
            pass


# ---------------------------------------------------------------- users & privileges

@databases_bp.route("/databases/api/users")
@require_permission("databases.manage")
def api_users():
    try:
        return _ok(users=dbsvc.list_users())
    except dbsvc.DatabaseError as exc:
        return _fail(exc)


@databases_bp.route("/databases/api/user/grants")
@require_permission("databases.manage")
def api_user_grants():
    try:
        return _ok(grants=dbsvc.user_grants(request.args.get("user", ""), request.args.get("host", "")))
    except dbsvc.DatabaseError as exc:
        return _fail(exc)


@databases_bp.route("/databases/api/user/<action>", methods=["POST"])
@require_permission("databases.manage")
def api_user_action(action):
    d = _body()
    user, host = (d.get("user") or "").strip(), (d.get("host") or "localhost").strip()
    try:
        if action == "create":
            dbsvc.create_user(user, host, d.get("password") or "", d.get("db") or None, d.get("preset") or "all")
        elif action == "password":
            dbsvc.set_password(user, host, d.get("password") or "")
        elif action == "grant":
            dbsvc.grant(user, host, d.get("db") or "", d.get("preset") or "all")
        elif action == "revoke":
            dbsvc.revoke(user, host, d.get("db") or "")
        elif action == "drop":
            dbsvc.drop_user(user, host)
        else:
            return _fail("Unknown action.", 404)
        _audit(f"user {action}", f"'{user}'@'{host}' {d.get('db') or ''}")
        return _ok()
    except dbsvc.DatabaseError as exc:
        return _fail(exc)
