"""
Admin-only DB table export / import / diff tool. Generic across every
table in models.py via db_tools.py's SQLAlchemy introspection -- no
per-table code here or there, so a new model added later is covered
automatically.

Scope reminder (see db_tools.py's own docstring): this is a raw table
tool for admins who know what they're doing with the data, not a
forgiving spreadsheet importer -- for messy real-world spreadsheets,
that's app/routes_import_export.py (Items/Tools) or the format-fixer
on stocktoolsetup instead.
"""
import json

from flask import Blueprint, Response, jsonify, request

import db_tools
from app.auth import permission_required
from app.models import db

db_tools_bp = Blueprint("db_tools", __name__, url_prefix="/api/admin/db-tools")

MAX_IMPORT_MB = 50


@db_tools_bp.route("/tables", methods=["GET"])
@permission_required("admin")
def tables():
    return jsonify({"tables": db_tools.list_tables(db)}), 200


@db_tools_bp.route("/export/<table_name>", methods=["GET"])
@permission_required("admin")
def export_one(table_name):
    try:
        rows = db_tools.export_table(db, table_name)
    except db_tools.DbToolsError as exc:
        return jsonify({"error": str(exc)}), 404
    body = json.dumps(rows, indent=2)
    return Response(
        body, mimetype="application/json",
        headers={"Content-Disposition": f'attachment; filename="{table_name}.json"'},
    )


@db_tools_bp.route("/export-all", methods=["GET"])
@permission_required("admin")
def export_all():
    snapshot = db_tools.export_all(db)
    body = json.dumps(snapshot, indent=2)
    return Response(
        body, mimetype="application/json",
        headers={"Content-Disposition": 'attachment; filename="database-export.json"'},
    )


@db_tools_bp.route("/import/<table_name>", methods=["POST"])
@permission_required("admin")
def import_one(table_name):
    if "file" not in request.files or not request.files["file"].filename:
        return jsonify({"error": "No file uploaded (expects a JSON array of row objects)."}), 400

    upload = request.files["file"]
    raw = upload.read()
    if len(raw) > MAX_IMPORT_MB * 1024 * 1024:
        return jsonify({"error": f"File too large (over {MAX_IMPORT_MB}MB)."}), 400

    try:
        rows = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        return jsonify({"error": f"Not valid JSON: {exc}"}), 400
    if not isinstance(rows, list):
        return jsonify({"error": "Expected a JSON array of row objects."}), 400

    try:
        report = db_tools.import_table(db, table_name, rows)
    except db_tools.DbToolsError as exc:
        return jsonify({"error": str(exc)}), 400
    return jsonify(report), 200


@db_tools_bp.route("/diff", methods=["POST"])
@permission_required("admin")
def diff():
    """Accepts two uploaded JSON snapshots ("before" and "after" file
    fields -- each either a single table's row-list or a whole-database
    {table: [rows]} export) and returns what changed between them."""
    if "before" not in request.files or "after" not in request.files:
        return jsonify({"error": "Upload both a 'before' and an 'after' JSON file."}), 400

    def _load(field_name, file_storage):
        raw = file_storage.read()
        try:
            data = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise ValueError(f"{field_name} file isn't valid JSON: {exc}")
        if isinstance(data, list):
            # A single table's export -- infer the name from the filename
            # (export_table() names downloads "<table>.json") or fall
            # back to a generic label so diff_snapshots still works.
            name = (file_storage.filename or "table").rsplit(".", 1)[0]
            return {name: data}
        if isinstance(data, dict):
            return data
        raise ValueError(f"{field_name} file must be a JSON array or object.")

    try:
        before = _load("before", request.files["before"])
        after = _load("after", request.files["after"])
    except ValueError as exc:
        return jsonify({"error": str(exc)}), 400

    result = db_tools.diff_snapshots(before, after)
    return jsonify(result), 200
