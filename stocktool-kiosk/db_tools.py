"""
db_tools.py -- generic per-table (and whole-database) export, import,
and diff, built on SQLAlchemy's table metadata rather than hand-written
per-table code, so every table in models.py (current and future) is
covered automatically without needing a matching change here.

Deliberately kept independent of Flask (same pattern as format_fixer.py)
so the actual logic can be tested directly, without needing a running
app. app/routes_db_tools.py is the thin Flask wrapper around this.

Scope, deliberately: this is a raw, admin-facing table tool -- it does
NOT understand header synonyms, business validation, or partial-column
CSVs the way app/routes_import_export.py's Items/Tools importer does.
Export from here, edit, re-import here -- for messier real-world
spreadsheets, use the Items/Tools importer or the format-fixer instead.
"""
import datetime


class DbToolsError(Exception):
    pass


def list_tables(db):
    """Returns table names in dependency order (tables with no foreign
    keys first) -- the same order safe for import, so callers don't
    have to work that out themselves."""
    return [t.name for t in db.metadata.sorted_tables]


def _table_by_name(db, table_name):
    table = db.metadata.tables.get(table_name)
    if table is None:
        raise DbToolsError(f"No such table: {table_name!r}. See list_tables() for valid names.")
    return table


def _primary_key_columns(table):
    cols = list(table.primary_key.columns)
    if not cols:
        raise DbToolsError(f"Table {table.name!r} has no primary key -- can't export/import/diff it safely.")
    return cols


def _serialize_value(value):
    if isinstance(value, (datetime.datetime, datetime.date)):
        return value.isoformat()
    return value


def export_table(db, table_name: str) -> list:
    """Returns every row of one table as a list of JSON-serializable
    dicts (column name -> value), ordered by primary key for a stable,
    diffable output."""
    table = _table_by_name(db, table_name)
    pk_cols = _primary_key_columns(table)
    stmt = table.select().order_by(*pk_cols)
    rows = db.session.execute(stmt).mappings().all()
    return [{k: _serialize_value(v) for k, v in dict(r).items()} for r in rows]


def export_all(db) -> dict:
    """Whole-database export: {table_name: [rows]} for every table, in
    dependency order (see list_tables)."""
    return {name: export_table(db, name) for name in list_tables(db)}


def import_table(db, table_name: str, rows: list) -> dict:
    """Upserts rows into one table, keyed by primary key: a row whose
    PK already exists gets its other columns updated; a row with a new
    PK gets inserted. Extra keys in a row not matching a real column
    are ignored; missing non-PK columns are left at whatever the DB
    default/existing value is (update) -- this is a deliberate "fill in
    what you give it" tool, not a strict schema validator.

    Returns {"inserted": N, "updated": N, "errors": [str, ...]}.
    Each row is applied in its own SAVEPOINT: a row that violates a
    database constraint (e.g. a duplicate value in a unique column
    like badge_code) is rolled back and reported in "errors", but
    every other row in the file still commits. One bad row no longer
    sinks the entire import."""
    table = _table_by_name(db, table_name)
    pk_cols = _primary_key_columns(table)
    pk_names = [c.name for c in pk_cols]
    valid_columns = {c.name for c in table.columns}
    datetime_columns = {
        c.name for c in table.columns
        if "DateTime" in type(c.type).__name__ or "Date" in type(c.type).__name__
    }

    inserted, updated, errors = 0, 0, []

    for i, raw_row in enumerate(rows, start=1):
        if not isinstance(raw_row, dict):
            errors.append(f"Row {i}: not an object -- skipped.")
            continue
        row = {k: v for k, v in raw_row.items() if k in valid_columns}
        for col_name in datetime_columns:
            v = row.get(col_name)
            if isinstance(v, str):
                try:
                    row[col_name] = datetime.datetime.fromisoformat(v)
                except ValueError:
                    errors.append(f"Row {i}: couldn't parse {col_name!r} value {v!r} as a date/time -- skipped.")
                    row = None
                    break
        if row is None:
            continue

        pk_values = {name: row.get(name) for name in pk_names}
        if any(v is None for v in pk_values.values()):
            errors.append(f"Row {i}: missing primary key value ({', '.join(pk_names)}) -- skipped.")
            continue

        where_clause = None
        for name, value in pk_values.items():
            cond = table.c[name] == value
            where_clause = cond if where_clause is None else (where_clause & cond)

        savepoint = db.session.begin_nested()
        try:
            exists = db.session.execute(table.select().where(where_clause)).first() is not None
            if exists:
                db.session.execute(table.update().where(where_clause).values(**row))
            else:
                db.session.execute(table.insert().values(**row))
            savepoint.commit()
        except Exception as exc:
            savepoint.rollback()
            pk_desc = ", ".join(f"{k}={v!r}" for k, v in pk_values.items())
            errors.append(f"Row {i} ({pk_desc}): {_short_db_error(exc)} -- skipped.")
            continue

        if exists:
            updated += 1
        else:
            inserted += 1

    try:
        db.session.commit()
    except Exception as exc:
        db.session.rollback()
        raise DbToolsError(f"Import failed, nothing was saved: {exc}") from exc

    return {"inserted": inserted, "updated": updated, "errors": errors}


def _short_db_error(exc: Exception) -> str:
    """Best-effort one-line summary of a DB constraint failure, e.g.
    'UNIQUE constraint failed: local_users.badge_code', instead of the
    full multi-line SQLAlchemy repr (which includes the raw SQL and
    parameters)."""
    orig = getattr(exc, "orig", None)
    msg = str(orig) if orig is not None else str(exc)
    return msg.splitlines()[0].strip()


def diff_snapshots(snapshot_a: dict, snapshot_b: dict) -> dict:
    """Compares two whole-database (or single-table, wrapped as
    {table_name: rows}) exports. For each table present in EITHER
    snapshot, returns which rows were added, removed, or changed --
    matched by treating the first column of each row as the primary
    key (export_table always puts real column names as keys, and rows
    are already ordered by PK, so this works without needing the
    caller to say which column is the PK).

    Returns {table_name: {"added": [...], "removed": [...], "changed": [{"before":.., "after":..}, ...]}}
    for every table where the two snapshots actually differ -- tables
    that are identical in both are omitted entirely, so the result
    only shows what actually changed."""
    all_tables = set(snapshot_a.keys()) | set(snapshot_b.keys())
    result = {}

    for table_name in sorted(all_tables):
        rows_a = snapshot_a.get(table_name, [])
        rows_b = snapshot_b.get(table_name, [])
        if not rows_a and not rows_b:
            continue

        def _key(row):
            # First key in the dict is always a primary-key column,
            # since export_table() reads columns in table-definition
            # order and every table here has its PK defined first.
            first_key = next(iter(row))
            return row[first_key]

        by_key_a = {_key(r): r for r in rows_a}
        by_key_b = {_key(r): r for r in rows_b}

        added = [by_key_b[k] for k in by_key_b if k not in by_key_a]
        removed = [by_key_a[k] for k in by_key_a if k not in by_key_b]
        changed = [
            {"before": by_key_a[k], "after": by_key_b[k]}
            for k in by_key_a
            if k in by_key_b and by_key_a[k] != by_key_b[k]
        ]

        if added or removed or changed:
            result[table_name] = {"added": added, "removed": removed, "changed": changed}

    return result
