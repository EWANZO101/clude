"""MySQL / MariaDB management backend for the Databases page — the panel's
built-in phpMyAdmin replacement.

Connects as root over the local unix socket. On Ubuntu, root@localhost uses
the auth_socket plugin, and the panel already runs as root, so the kernel
vouches for us: no MySQL password is stored anywhere. Override the socket path
with MYSQL_SOCKET if the server lives somewhere non-standard.

Identifiers (database/table/column names) can't be bound as query
parameters, so every one goes through qi(). Values always go through
PyMySQL's parameter binding.
"""
import datetime
import decimal
import gzip
import os
import re
import shutil
import subprocess
import tempfile
import time
from contextlib import contextmanager

import pymysql
from pymysql.constants import CLIENT

MYSQL_SOCKET = os.environ.get("MYSQL_SOCKET", "/var/run/mysqld/mysqld.sock")

# Never droppable / truncatable from the panel. Still browsable and queryable.
SYSTEM_DATABASES = {"mysql", "information_schema", "performance_schema", "sys"}
# Accounts the panel itself, the OS packaging, or MySQL internals depend on.
PROTECTED_USERS = {"root", "debian-sys-maint", "mysql.infoschema", "mysql.session", "mysql.sys"}

MAX_QUERY_ROWS = 1000          # per result set in the SQL console
MAX_CELL_CHARS = 5000          # long TEXT/BLOB cells get truncated in the grid
QUERY_TIMEOUT_MS = 60000       # SELECT max_execution_time for console + browse

PRIVILEGE_PRESETS = {
    "all": "ALL PRIVILEGES",
    "readwrite": "SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, INDEX, DROP, CREATE TEMPORARY TABLES, LOCK TABLES",
    "data": "SELECT, INSERT, UPDATE, DELETE",
    "readonly": "SELECT",
}

_DB_NAME_RE = re.compile(r"^[A-Za-z0-9_$\-]{1,64}$")
_CHARSET_RE = re.compile(r"^[a-z0-9_]{1,64}$")
_USER_RE = re.compile(r"^[A-Za-z0-9_.\-]{1,32}$")
_HOST_RE = re.compile(r"^[A-Za-z0-9_.%:\-]{1,255}$")


class DatabaseError(Exception):
    pass


# ---------------------------------------------------------------- helpers

def is_installed():
    return os.path.exists(MYSQL_SOCKET)


def _connect(database=None, multi=False):
    if not is_installed():
        raise DatabaseError(f"MySQL socket not found at {MYSQL_SOCKET}. Is MySQL/MariaDB installed and running?")
    try:
        return pymysql.connect(
            unix_socket=MYSQL_SOCKET,
            user="root",
            database=database or None,
            charset="utf8mb4",
            autocommit=True,
            connect_timeout=5,
            read_timeout=300,
            client_flag=CLIENT.MULTI_STATEMENTS if multi else 0,
        )
    except pymysql.MySQLError as exc:
        raise DatabaseError(_err(exc)) from exc


@contextmanager
def connection(database=None, multi=False):
    conn = _connect(database, multi=multi)
    try:
        yield conn
    except pymysql.MySQLError as exc:
        raise DatabaseError(_err(exc)) from exc
    finally:
        try:
            conn.close()
        except Exception:  # noqa: BLE001
            pass


def _err(exc):
    if getattr(exc, "args", None) and len(exc.args) >= 2:
        return f"MySQL error {exc.args[0]}: {exc.args[1]}"
    return str(exc)


def qi(name):
    """Quote an identifier with backticks, escaping embedded backticks."""
    if not isinstance(name, str) or not name or len(name) > 64 or "\x00" in name:
        raise DatabaseError(f"Invalid identifier: {name!r}")
    return "`" + name.replace("`", "``") + "`"


def _check_db_name(name):
    if not name or not _DB_NAME_RE.match(name):
        raise DatabaseError("Database names may only contain letters, numbers, _, - and $ (max 64 chars).")


def _check_not_system(database):
    if database.lower() in SYSTEM_DATABASES:
        raise DatabaseError(f"'{database}' is a MySQL system database and can't be modified from the panel.")


def _check_user(user, host):
    if not user or not _USER_RE.match(user):
        raise DatabaseError("Usernames may only contain letters, numbers, _, . and - (max 32 chars).")
    if not host or not _HOST_RE.match(host):
        raise DatabaseError("Invalid host. Use localhost, %, an IP, or a hostname pattern.")


def _cell(value):
    """Make a MySQL value JSON-safe for the grid."""
    if value is None or isinstance(value, (int, float, bool)):
        return value
    if isinstance(value, decimal.Decimal):
        return str(value)
    if isinstance(value, (datetime.datetime, datetime.date, datetime.time)):
        return value.isoformat(sep=" ") if isinstance(value, datetime.datetime) else value.isoformat()
    if isinstance(value, datetime.timedelta):
        total = int(value.total_seconds())
        sign = "-" if total < 0 else ""
        total = abs(total)
        return f"{sign}{total // 3600:02d}:{(total % 3600) // 60:02d}:{total % 60:02d}"
    if isinstance(value, (bytes, bytearray)):
        try:
            value = bytes(value).decode("utf-8")
        except UnicodeDecodeError:
            raw = bytes(value)
            hexed = raw[:MAX_CELL_CHARS // 2].hex()
            return f"0x{hexed}" + ("…" if len(raw) > MAX_CELL_CHARS // 2 else "")
    value = str(value)
    if len(value) > MAX_CELL_CHARS:
        return value[:MAX_CELL_CHARS] + "…"
    return value


def _columns_of(cur, database, table):
    cur.execute(f"SHOW FULL COLUMNS FROM {qi(database)}.{qi(table)}")
    cols = []
    for row in cur.fetchall():
        field, ctype, collation, null, key, default, extra, privileges, comment = row
        cols.append({
            "name": field, "type": ctype, "collation": collation, "nullable": null == "YES",
            "key": key, "default": _cell(default), "extra": extra, "comment": comment,
        })
    if not cols:
        raise DatabaseError(f"Table {database}.{table} not found.")
    return cols


def _primary_key(cur, database, table):
    cur.execute(f"SHOW INDEX FROM {qi(database)}.{qi(table)} WHERE Key_name = 'PRIMARY'")
    rows = sorted(cur.fetchall(), key=lambda r: r[3])  # Seq_in_index
    return [r[4] for r in rows]  # Column_name


# ---------------------------------------------------------------- server + databases

def server_info():
    with connection() as conn, conn.cursor() as cur:
        cur.execute("SELECT VERSION()")
        version = cur.fetchone()[0]
        cur.execute("SHOW GLOBAL STATUS WHERE Variable_name IN ('Uptime','Threads_connected','Questions','Slow_queries')")
        status = {k: v for k, v in cur.fetchall()}
        cur.execute("SELECT COALESCE(SUM(data_length + index_length), 0) FROM information_schema.TABLES")
        total_size = int(cur.fetchone()[0] or 0)
    return {
        "version": version,
        "flavor": "MariaDB" if "mariadb" in version.lower() else "MySQL",
        "uptime_seconds": int(status.get("Uptime", 0)),
        "connections": int(status.get("Threads_connected", 0)),
        "questions": int(status.get("Questions", 0)),
        "slow_queries": int(status.get("Slow_queries", 0)),
        "total_size": total_size,
        "socket": MYSQL_SOCKET,
    }


def list_databases():
    with connection() as conn, conn.cursor() as cur:
        cur.execute("""
            SELECT s.SCHEMA_NAME, s.DEFAULT_CHARACTER_SET_NAME, s.DEFAULT_COLLATION_NAME,
                   COUNT(t.TABLE_NAME), COALESCE(SUM(t.DATA_LENGTH + t.INDEX_LENGTH), 0)
            FROM information_schema.SCHEMATA s
            LEFT JOIN information_schema.TABLES t ON t.TABLE_SCHEMA = s.SCHEMA_NAME
            GROUP BY s.SCHEMA_NAME, s.DEFAULT_CHARACTER_SET_NAME, s.DEFAULT_COLLATION_NAME
            ORDER BY s.SCHEMA_NAME
        """)
        return [{
            "name": name, "charset": cs, "collation": coll, "tables": int(n),
            "size": int(size or 0), "system": name.lower() in SYSTEM_DATABASES,
        } for name, cs, coll, n, size in cur.fetchall()]


def list_charsets():
    with connection() as conn, conn.cursor() as cur:
        cur.execute("SELECT CHARACTER_SET_NAME, DEFAULT_COLLATE_NAME FROM information_schema.CHARACTER_SETS ORDER BY CHARACTER_SET_NAME")
        return [{"name": n, "default_collation": c} for n, c in cur.fetchall()]


def create_database(name, charset="utf8mb4", collation=None):
    _check_db_name(name)
    charset = (charset or "utf8mb4").strip()
    if not _CHARSET_RE.match(charset):
        raise DatabaseError("Invalid character set.")
    sql = f"CREATE DATABASE {qi(name)} CHARACTER SET {charset}"
    if collation:
        if not _CHARSET_RE.match(collation):
            raise DatabaseError("Invalid collation.")
        sql += f" COLLATE {collation}"
    with connection() as conn, conn.cursor() as cur:
        cur.execute(sql)


def drop_database(name):
    _check_not_system(name)
    with connection() as conn, conn.cursor() as cur:
        cur.execute(f"DROP DATABASE {qi(name)}")


# ---------------------------------------------------------------- tables

def list_tables(database):
    with connection() as conn, conn.cursor() as cur:
        cur.execute("""
            SELECT TABLE_NAME, TABLE_TYPE, ENGINE, TABLE_ROWS, DATA_LENGTH, INDEX_LENGTH,
                   TABLE_COLLATION, AUTO_INCREMENT, UPDATE_TIME, TABLE_COMMENT
            FROM information_schema.TABLES WHERE TABLE_SCHEMA = %s ORDER BY TABLE_NAME
        """, (database,))
        return [{
            "name": name, "type": "view" if ttype == "VIEW" else "table", "engine": engine,
            "rows": int(rows) if rows is not None else None,
            "data_size": int(dlen or 0), "index_size": int(ilen or 0),
            "size": int(dlen or 0) + int(ilen or 0), "collation": coll,
            "auto_increment": int(ai) if ai is not None else None,
            "updated": _cell(updated), "comment": comment,
        } for name, ttype, engine, rows, dlen, ilen, coll, ai, updated, comment in cur.fetchall()]


def table_structure(database, table):
    with connection() as conn, conn.cursor() as cur:
        columns = _columns_of(cur, database, table)
        cur.execute(f"SHOW INDEX FROM {qi(database)}.{qi(table)}")
        indexes = {}
        for r in cur.fetchall():
            idx = indexes.setdefault(r[2], {"name": r[2], "unique": not r[1], "type": r[10], "columns": []})
            idx["columns"].append(r[4])
        cur.execute(f"SHOW CREATE TABLE {qi(database)}.{qi(table)}")
        create_sql = cur.fetchone()[1]
    return {"columns": columns, "indexes": list(indexes.values()), "create_sql": create_sql}


def drop_table(database, table):
    _check_not_system(database)
    with connection() as conn, conn.cursor() as cur:
        cur.execute("SELECT TABLE_TYPE FROM information_schema.TABLES WHERE TABLE_SCHEMA=%s AND TABLE_NAME=%s", (database, table))
        row = cur.fetchone()
        if not row:
            raise DatabaseError(f"{database}.{table} not found.")
        kind = "VIEW" if row[0] == "VIEW" else "TABLE"
        cur.execute(f"DROP {kind} {qi(database)}.{qi(table)}")


def truncate_table(database, table):
    _check_not_system(database)
    with connection() as conn, conn.cursor() as cur:
        cur.execute(f"TRUNCATE TABLE {qi(database)}.{qi(table)}")


# ---------------------------------------------------------------- rows

def browse_rows(database, table, page=1, per_page=50, sort=None, direction="asc", search=""):
    page = max(1, int(page or 1))
    per_page = min(500, max(1, int(per_page or 50)))
    with connection(database) as conn, conn.cursor() as cur:
        columns = _columns_of(cur, database, table)
        names = [c["name"] for c in columns]
        pk = _primary_key(cur, database, table)

        where, params = "", []
        search = (search or "").strip()
        if search:
            like = "%" + search.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%"
            where = " WHERE " + " OR ".join(f"CAST({qi(n)} AS CHAR) LIKE %s" for n in names)
            params = [like] * len(names)

        order = ""
        if sort and sort in names:
            order = f" ORDER BY {qi(sort)} {'DESC' if direction == 'desc' else 'ASC'}"
        elif pk:
            order = " ORDER BY " + ", ".join(qi(c) for c in pk)

        cur.execute(f"SET SESSION max_execution_time = {QUERY_TIMEOUT_MS}")
        target = f"{qi(database)}.{qi(table)}"
        cur.execute(f"SELECT COUNT(*) FROM {target}{where}", params)
        total = int(cur.fetchone()[0])
        cur.execute(f"SELECT * FROM {target}{where}{order} LIMIT %s OFFSET %s",
                    params + [per_page, (page - 1) * per_page])
        rows = [[_cell(v) for v in r] for r in cur.fetchall()]
    return {"columns": columns, "primary_key": pk, "rows": rows, "total": total,
            "page": page, "per_page": per_page}


def _where_for_row(cur, database, table, match):
    """WHERE clause identifying one row. Uses the primary key when the table
    has one; otherwise falls back to matching every column of the original
    row (null-safe), like phpMyAdmin does. Always paired with LIMIT 1."""
    columns = {c["name"] for c in _columns_of(cur, database, table)}
    pk = _primary_key(cur, database, table)
    if not isinstance(match, dict) or not match:
        raise DatabaseError("No row identifier given.")
    if pk:
        missing = [c for c in pk if c not in match]
        if missing:
            raise DatabaseError(f"Missing primary key value(s): {', '.join(missing)}")
        keys = pk
    else:
        keys = [k for k in match if k in columns]
        if not keys:
            raise DatabaseError("Row identifier doesn't match any column.")
    clause = " AND ".join(f"{qi(k)} <=> %s" for k in keys)
    return clause, [match[k] for k in keys], columns


def insert_row(database, table, values):
    _check_not_system(database)
    with connection(database) as conn, conn.cursor() as cur:
        columns = {c["name"] for c in _columns_of(cur, database, table)}
        values = {k: v for k, v in (values or {}).items() if k in columns}
        if values:
            cols = ", ".join(qi(k) for k in values)
            marks = ", ".join(["%s"] * len(values))
            cur.execute(f"INSERT INTO {qi(database)}.{qi(table)} ({cols}) VALUES ({marks})", list(values.values()))
        else:
            cur.execute(f"INSERT INTO {qi(database)}.{qi(table)} () VALUES ()")
        return {"insert_id": cur.lastrowid, "affected": cur.rowcount}


def update_row(database, table, match, values):
    _check_not_system(database)
    with connection(database) as conn, conn.cursor() as cur:
        clause, params, columns = _where_for_row(cur, database, table, match)
        values = {k: v for k, v in (values or {}).items() if k in columns}
        if not values:
            raise DatabaseError("Nothing to update.")
        sets = ", ".join(f"{qi(k)} = %s" for k in values)
        cur.execute(f"UPDATE {qi(database)}.{qi(table)} SET {sets} WHERE {clause} LIMIT 1",
                    list(values.values()) + params)
        return {"affected": cur.rowcount}


def delete_row(database, table, match):
    _check_not_system(database)
    with connection(database) as conn, conn.cursor() as cur:
        clause, params, _ = _where_for_row(cur, database, table, match)
        cur.execute(f"DELETE FROM {qi(database)}.{qi(table)} WHERE {clause} LIMIT 1", params)
        return {"affected": cur.rowcount}


# ---------------------------------------------------------------- SQL console

def run_query(database, sql):
    """Run one or more ;-separated statements. Returns one entry per
    statement: a capped result grid for row-returning statements, an
    affected-row count for everything else. If a statement fails, the
    results of the statements before it are still returned with the error."""
    sql = (sql or "").strip()
    if not sql:
        raise DatabaseError("Query is empty.")
    results, error = [], None
    started = time.perf_counter()
    conn = _connect(database or None, multi=True)
    try:
        cur = conn.cursor(pymysql.cursors.SSCursor)
        cur.execute(f"SET SESSION max_execution_time = {QUERY_TIMEOUT_MS}")
        try:
            cur.execute(sql)
            while True:
                if cur.description:
                    cols = [d[0] for d in cur.description]
                    fetched = cur.fetchmany(MAX_QUERY_ROWS + 1)
                    truncated = len(fetched) > MAX_QUERY_ROWS
                    results.append({
                        "type": "rows", "columns": cols,
                        "rows": [[_cell(v) for v in r] for r in fetched[:MAX_QUERY_ROWS]],
                        "truncated": truncated,
                    })
                else:
                    results.append({"type": "ok", "affected": cur.rowcount, "insert_id": cur.lastrowid or None})
                if not cur.nextset():
                    break
        except pymysql.MySQLError as exc:
            error = _err(exc)
        try:
            cur.close()
        except pymysql.MySQLError:
            pass
    finally:
        try:
            conn.close()
        except Exception:  # noqa: BLE001
            pass
    return {"results": results, "error": error,
            "elapsed_ms": round((time.perf_counter() - started) * 1000, 1)}


# ---------------------------------------------------------------- export / import

def export_stream(database, table=None):
    """Yield a mysqldump of a database (or one table) chunk by chunk, so big
    dumps never sit in memory. Failures surface as a trailing SQL comment
    since the HTTP headers are already sent by then."""
    args = ["mysqldump", f"--socket={MYSQL_SOCKET}", "-uroot", "--single-transaction",
            "--routines", "--triggers", "--events", "--default-character-set=utf8mb4",
            "--add-drop-table", "--hex-blob", "--", database]
    if table:
        args.append(table)
    if shutil.which("mysqldump") is None:
        raise DatabaseError("mysqldump isn't installed on this server.")
    errlog = tempfile.TemporaryFile()
    proc = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=errlog)

    def generate():
        try:
            while True:
                chunk = proc.stdout.read(64 * 1024)
                if not chunk:
                    break
                yield chunk
            proc.wait()
            if proc.returncode != 0:
                errlog.seek(0)
                msg = errlog.read().decode("utf-8", "replace").strip().replace("\n", "\n-- ")
                yield f"\n-- EXPORT FAILED (mysqldump exit {proc.returncode}):\n-- {msg}\n".encode()
        finally:
            if proc.poll() is None:
                proc.kill()
            errlog.close()

    return generate()


def import_sql(database, upload_path, filename=""):
    """Feed an uploaded .sql (or .sql.gz) file into the mysql client."""
    _check_not_system(database)
    if shutil.which("mysql") is None:
        raise DatabaseError("The mysql client isn't installed on this server.")
    args = ["mysql", f"--socket={MYSQL_SOCKET}", "-uroot", "--default-character-set=utf8mb4", "--", database]
    opener = gzip.open if filename.lower().endswith(".gz") else open
    started = time.perf_counter()
    read_error = None
    with opener(upload_path, "rb") as src, tempfile.TemporaryFile() as errlog:
        proc = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=errlog)
        try:
            shutil.copyfileobj(src, proc.stdin, 64 * 1024)
        except BrokenPipeError:
            pass  # mysql stopped reading (it bails on the first error) — stderr says why
        except (OSError, EOFError, gzip.BadGzipFile) as exc:
            read_error = f"Couldn't read the uploaded file: {exc}"
        finally:
            try:
                proc.stdin.close()
            except BrokenPipeError:
                pass
        proc.wait(timeout=3600)
        errlog.seek(0)
        stderr = errlog.read().decode("utf-8", "replace").strip()
    if proc.returncode != 0:
        raise DatabaseError(stderr or read_error or f"mysql exited with {proc.returncode}")
    if read_error:
        raise DatabaseError(read_error + " (statements read before that point were executed)")
    return {"elapsed_ms": round((time.perf_counter() - started) * 1000, 1)}


# ---------------------------------------------------------------- users & privileges

def list_users():
    with connection() as conn, conn.cursor() as cur:
        cur.execute("SELECT User, Host, plugin, account_locked FROM mysql.user ORDER BY User, Host")
        users = [{"user": u, "host": h, "plugin": p, "locked": locked == "Y",
                  "protected": u in PROTECTED_USERS} for u, h, p, locked in cur.fetchall()]
        cur.execute("SELECT User, Host, Db FROM mysql.db ORDER BY Db")
        dbs = {}
        for u, h, d in cur.fetchall():
            dbs.setdefault((u, h), []).append(d)
        for u in users:
            u["databases"] = dbs.get((u["user"], u["host"]), [])
    return users


def user_grants(user, host):
    _check_user(user, host)
    with connection() as conn, conn.cursor() as cur:
        cur.execute("SHOW GRANTS FOR %s@%s", (user, host))
        return [r[0] for r in cur.fetchall()]


def _privs(preset):
    privs = PRIVILEGE_PRESETS.get(preset)
    if not privs:
        raise DatabaseError("Unknown privilege preset.")
    return privs


def create_user(user, host, password, database=None, preset="all"):
    _check_user(user, host)
    if not password or len(password) < 8:
        raise DatabaseError("Password must be at least 8 characters.")
    with connection() as conn, conn.cursor() as cur:
        cur.execute("CREATE USER %s@%s IDENTIFIED BY %s", (user, host, password))
        if database:
            cur.execute(f"GRANT {_privs(preset)} ON {qi(database)}.* TO %s@%s", (user, host))


def grant(user, host, database, preset="all"):
    _check_user(user, host)
    _check_not_system(database)
    with connection() as conn, conn.cursor() as cur:
        cur.execute(f"GRANT {_privs(preset)} ON {qi(database)}.* TO %s@%s", (user, host))


def revoke(user, host, database):
    _check_user(user, host)
    with connection() as conn, conn.cursor() as cur:
        cur.execute(f"REVOKE ALL PRIVILEGES ON {qi(database)}.* FROM %s@%s", (user, host))


def set_password(user, host, password):
    _check_user(user, host)
    if user in PROTECTED_USERS:
        raise DatabaseError(f"'{user}' is a protected system account.")
    if not password or len(password) < 8:
        raise DatabaseError("Password must be at least 8 characters.")
    with connection() as conn, conn.cursor() as cur:
        cur.execute("ALTER USER %s@%s IDENTIFIED BY %s", (user, host, password))


def drop_user(user, host):
    _check_user(user, host)
    if user in PROTECTED_USERS:
        raise DatabaseError(f"'{user}' is a protected system account.")
    with connection() as conn, conn.cursor() as cur:
        cur.execute("DROP USER %s@%s", (user, host))
