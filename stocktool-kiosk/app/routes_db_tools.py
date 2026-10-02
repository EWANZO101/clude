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


@db_tools_bp.route("/page", methods=["GET"])
@permission_required("admin")
def page():
    """Self-contained admin page (no template dependency) for driving
    export/import/diff. Reachable at /api/admin/db-tools/page while
    logged in as admin."""
    html = """<!doctype html>
<html><head><meta charset="utf-8"><title>DB Tools</title>
<style>
body{font-family:system-ui,sans-serif;background:#0f1115;color:#e6e8ec;max-width:720px;margin:40px auto;padding:0 20px;}
h1{font-size:22px;margin-bottom:4px;}
h2{font-size:15px;color:#9aa1ac;margin:32px 0 10px;border-bottom:1px solid #2a2e38;padding-bottom:6px;}
select,input[type=file]{width:100%;padding:8px;margin:6px 0 12px;border-radius:6px;border:1px solid #2a2e38;background:#171a21;color:#e6e8ec;}
button{padding:9px 16px;border-radius:6px;border:1px solid #4f8cff;background:rgba(79,140,255,0.12);color:#6ea0ff;font-weight:700;cursor:pointer;}
button:hover{background:#4f8cff;color:#fff;}
pre{background:#171a21;border:1px solid #2a2e38;border-radius:6px;padding:12px;overflow:auto;max-height:320px;font-size:12.5px;}
.row{display:flex;gap:12px;}
.row>div{flex:1;}
label{font-size:12.5px;color:#9aa1ac;}
</style></head>
<body>
<h1>Database Tools</h1>
<p style="color:#9aa1ac;">Export, import, or diff any table directly. Raw tool -- for messy spreadsheets use the regular Items/Tools import instead.</p>

<h2>Export</h2>
<label>Table</label>
<select id="exportTable"></select>
<button onclick="exportOne()">Download table JSON</button>
<button onclick="location.href='/api/admin/db-tools/export-all'" style="margin-left:8px;">Download whole database</button>

<h2>Import</h2>
<label>Table</label>
<select id="importTable"></select>
<label>JSON file (array of row objects, from a matching export)</label>
<input type="file" id="importFile" accept=".json">
<button onclick="importOne()">Import (insert/update by primary key)</button>
<pre id="importResult"></pre>

<h2>Diff two snapshots</h2>
<div class="row">
  <div><label>Before</label><input type="file" id="diffBefore" accept=".json"></div>
  <div><label>After</label><input type="file" id="diffAfter" accept=".json"></div>
</div>
<button onclick="doDiff()">Compare</button>
<pre id="diffResult"></pre>

<script>
async function loadTables() {
  const resp = await fetch('/api/admin/db-tools/tables');
  const data = await resp.json();
  const opts = data.tables.map(t => `<option value="${t}">${t}</option>`).join('');
  document.getElementById('exportTable').innerHTML = opts;
  document.getElementById('importTable').innerHTML = opts;
}
loadTables();

function exportOne() {
  const t = document.getElementById('exportTable').value;
  location.href = '/api/admin/db-tools/export/' + encodeURIComponent(t);
}

async function importOne() {
  const t = document.getElementById('importTable').value;
  const fileInput = document.getElementById('importFile');
  const result = document.getElementById('importResult');
  if (!fileInput.files.length) { result.textContent = 'Choose a file first.'; return; }
  const fd = new FormData();
  fd.append('file', fileInput.files[0]);
  result.textContent = 'Importing...';
  const resp = await fetch('/api/admin/db-tools/import/' + encodeURIComponent(t), {method: 'POST', body: fd});
  const data = await resp.json();
  result.textContent = JSON.stringify(data, null, 2);
}

async function doDiff() {
  const before = document.getElementById('diffBefore');
  const after = document.getElementById('diffAfter');
  const result = document.getElementById('diffResult');
  if (!before.files.length || !after.files.length) { result.textContent = 'Choose both files first.'; return; }
  const fd = new FormData();
  fd.append('before', before.files[0]);
  fd.append('after', after.files[0]);
  result.textContent = 'Comparing...';
  const resp = await fetch('/api/admin/db-tools/diff', {method: 'POST', body: fd});
  const data = await resp.json();
  result.textContent = JSON.stringify(data, null, 2);
}
</script>
</body></html>"""
    return Response(html, mimetype="text/html")
