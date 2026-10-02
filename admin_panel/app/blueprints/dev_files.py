"""Dev Files: a platform-admin-only area for browsing, editing, and
downloading the source that makes up this whole system — both the Agent
that ships to kiosk hardware (agent/, service_files/, requirements.txt)
AND the Admin Panel application itself (app/, migrations/, run.py,
config.py), including its Jinja templates.

Deliberately platform-admin-only (not scoped to a company) since these
files affect every company, not one — same trust boundary as
releases.py's upload-a-package flow.

IMPORTANT ASYMMETRY worth understanding before editing here: this process
runs with Flask's debug reloader (see run.py — app.run(debug=True, ...)),
which watches every imported .py file and restarts the whole app the
moment one changes. Editing agent/ or service_files/ can NEVER affect
this running process (that code only ever runs on a kiosk, as a separate
program, after Publish + a reinstall) — but editing anything under app/,
migrations/, run.py, or config.py takes effect immediately on save, and a
mistake (a syntax error, an accidental break in app/__init__.py) can take
the whole Admin Panel down right then, not just on a future kiosk
install. The per-save backup below is the recovery path if that happens
— restore the previous content from data/dev_file_backups/ and save
again (or copy it back over SSH if the crash is bad enough that this UI
itself won't load).

Every save is logged (AuditLogEntry via log_action, company=None for a
platform-level action) and snapshotted to disk before being overwritten,
so "what changed and when" has two independent trails: the audit log for
who/when/what-file, and a timestamped copy of the previous content for
an actual diff or restore if a save turns out to be wrong.
"""
import os
import io
import shutil
import tarfile
import zipfile
from datetime import datetime

from flask import Blueprint, render_template, redirect, url_for, request, flash, abort, send_file
from flask_login import login_required, current_user

from config import BASEDIR
from app.extensions import db
from app.models import log_action
from app.platform_auth import platform_admin_required

bp = Blueprint("dev_files", __name__, url_prefix="/admin/dev-files")

# Everything that makes up this system, split into three systems that must
# never blur into each other (see OWNERSHIP.md):
#   - "agent"       — the Instance Agent (agent/, service_files/,
#                      requirements.txt) that runs ON a kiosk machine to
#                      manage it. Ships via Publish -> opslab-agent.tar.gz
#                      (see publish() below). NOT the application a kiosk
#                      operator actually uses.
#   - "admin_panel" — this Admin Panel itself (app/, migrations/, run.py,
#                      config.py). Edits here take effect on THIS running
#                      process immediately (Flask debug reloader).
#   - "kiosk_app"   — the Kiosk App (kiosk_app/) — the actual application a
#                      kiosk operator uses. A completely separate Flask
#                      project; never imported by / never imports the Admin
#                      Panel's app/. Only reaches a real machine via
#                      Releases -> "Build Kiosk Release" -> Push Update,
#                      never automatically and never from an edit here.
# A file's system is used both to group the UI (index()) and to pick the
# right warning banner — see _system_for below.
ADMIN_PANEL_ROOT_DIRS = ["app", "migrations"]
ADMIN_PANEL_ROOT_FILES = ["requirements.txt", "run.py", "config.py"]
AGENT_ROOT_DIRS = ["agent", "service_files"]
AGENT_ROOT_FILES = []
KIOSK_APP_ROOT_DIRS = ["kiosk_app"]
KIOSK_APP_ROOT_FILES = []

ALLOWED_ROOT_DIRS = ADMIN_PANEL_ROOT_DIRS + AGENT_ROOT_DIRS + KIOSK_APP_ROOT_DIRS
ALLOWED_ROOT_FILES = ADMIN_PANEL_ROOT_FILES + AGENT_ROOT_FILES + KIOSK_APP_ROOT_FILES

# Deliberately separate from ALLOWED_ROOT_DIRS/FILES above: this is what
# actually gets shipped as the Instance Agent tarball (publish() below) —
# NOTE the confusing name this constant already had before this file's
# systems were split out above: "KIOSK_SHIP" here has always meant "ships
# to a kiosk MACHINE" (the Agent that manages it), not "is the Kiosk App".
# The Kiosk App itself (kiosk_app/) ships a completely different way — see
# tools/build_kiosk_release.py + Releases -> "Build Kiosk Release" — never
# through this tarball. Browsing/editing covers the whole Admin Panel app
# too, but this installed artifact must NEVER silently expand to include
# it — that would leak the Admin Panel's own source (config.py, models,
# everything) onto every kiosk that installs the Agent. If a future
# agent-side file needs to ship, add it here explicitly, not by
# broadening the dev-files scope.
KIOSK_SHIP_ROOT_DIRS = list(AGENT_ROOT_DIRS)
KIOSK_SHIP_ROOT_FILES = ["requirements.txt"]

# Directories that are never worth browsing/editing even inside an
# otherwise-allowed root: build artifacts and VCS metadata, not source.
EXCLUDED_DIR_NAMES = {"__pycache__", ".git", ".pytest_cache"}
EXCLUDED_EXTENSIONS = {".pyc", ".pyo"}

BACKUP_DIR = os.path.realpath(os.path.join(BASEDIR, "data", "dev_file_backups"))
AGENT_TARBALL_PATH = os.path.join(BASEDIR, "app", "static", "installers", "opslab-agent.tar.gz")
# Immutable per-push snapshots for instances.py::agent_self_update — see
# build_agent_tarball_snapshot() below for why these must never share
# AGENT_TARBALL_PATH's single mutable filename.
AGENT_UPDATE_SNAPSHOT_DIR = os.path.join(BASEDIR, "app", "static", "installers", "agent_updates")

# Upload guardrails — this is source code, never expected to be large;
# these are generous ceilings meant to block an accidental or malicious
# zip bomb, not a real limit anyone should hit in normal use.
MAX_ZIP_ENTRIES = 2000
MAX_ZIP_ENTRY_BYTES = 5 * 1024 * 1024           # 5 MB per file
MAX_ZIP_TOTAL_UNCOMPRESSED_BYTES = 50 * 1024 * 1024   # 50 MB total

# Only these extensions open in the text editor — keeps it from trying to
# load/save a binary file, and doubles as a safety rail (nothing routed
# through here can be pointed at something like a .db file). Includes
# .html/.css/.js now that app/templates and app/static are in scope.
EDITABLE_EXTENSIONS = {
    ".py", ".txt", ".md", ".cfg", ".ini", ".service", ".json", ".sh", ".ps1", "",
    ".html", ".css", ".js", ".mako",
}

_ALLOWED_REAL_ROOTS = [os.path.realpath(os.path.join(BASEDIR, d)) for d in ALLOWED_ROOT_DIRS]
_ALLOWED_REAL_FILES = [os.path.realpath(os.path.join(BASEDIR, f)) for f in ALLOWED_ROOT_FILES]


def _resolve_safe(rel_path: str):
    """Returns the resolved absolute path if rel_path lands inside an
    allowlisted root, else None (does not abort) — shared by _safe_path
    (query-string paths, aborts on failure) and upload_zip (zip entry
    names, collects rejections instead of aborting on the first bad one).
    Path traversal ('../'), absolute paths, and symlinks are all closed
    off via realpath + an exact prefix check — this is load-bearing, not
    decorative, since both callers can end up writing to disk."""
    if not rel_path:
        return None
    rel_path = rel_path.replace("\\", "/")  # zip entries from Windows tools use '\'
    candidate = os.path.realpath(os.path.join(BASEDIR, rel_path))
    if candidate in _ALLOWED_REAL_FILES:
        return candidate
    for root in _ALLOWED_REAL_ROOTS:
        if candidate == root or candidate.startswith(root + os.sep):
            return candidate
    return None


def _safe_path(rel_path: str) -> str:
    resolved = _resolve_safe(rel_path)
    if resolved is None:
        abort(400, description="Invalid path.")
    return resolved


def _system_for(rel_path: str) -> str:
    """Which of the three systems (see the constants above) a
    dev-files-relative path belongs to — drives both the grouped UI and
    the per-system warning banner. Falls back to 'admin_panel' only for a
    path that somehow doesn't match any known root (shouldn't happen for
    anything that passed _resolve_safe)."""
    top = rel_path.replace("\\", "/").split("/")[0]
    if top in KIOSK_APP_ROOT_DIRS or top in KIOSK_APP_ROOT_FILES:
        return "kiosk_app"
    if top in AGENT_ROOT_DIRS or top in AGENT_ROOT_FILES:
        return "agent"
    return "admin_panel"


def _is_editable(path: str) -> bool:
    return os.path.splitext(path)[1].lower() in EDITABLE_EXTENSIONS


def _is_excluded(path: str) -> bool:
    if os.path.splitext(path)[1].lower() in EXCLUDED_EXTENSIONS:
        return True
    parts = os.path.normpath(path).split(os.sep)
    return any(p in EXCLUDED_DIR_NAMES for p in parts)


def _list_files():
    """Recursively lists every file under the allowlisted roots, as
    repo-root-relative paths (forward-slash, for use in URLs), sorted.
    Skips __pycache__/.git/etc — build artifacts, not source."""
    results = []
    for root_dir in ALLOWED_ROOT_DIRS:
        abs_root = os.path.join(BASEDIR, root_dir)
        if not os.path.isdir(abs_root):
            continue
        for root, dirs, files in os.walk(abs_root):
            dirs[:] = sorted(d for d in dirs if d not in EXCLUDED_DIR_NAMES)
            for fname in sorted(files):
                if os.path.splitext(fname)[1].lower() in EXCLUDED_EXTENSIONS:
                    continue
                full = os.path.join(root, fname)
                rel = os.path.relpath(full, BASEDIR).replace(os.sep, "/")
                results.append(_file_entry(full, rel))
    for f in ALLOWED_ROOT_FILES:
        full = os.path.join(BASEDIR, f)
        if os.path.isfile(full):
            results.append(_file_entry(full, f))
    results.sort(key=lambda f: f["rel_path"])
    return results


def _format_size(num_bytes: int) -> str:
    """Bytes for anything under 1KB (avoids a misleading '0.0 KB' for a
    near-empty file like an __init__.py), KB with one decimal under 1MB,
    MB with two decimals above that — these files are source code, never
    expected to reach that size, but the formatting shouldn't quietly lie
    if one ever does."""
    if num_bytes < 1024:
        return f"{num_bytes} B"
    if num_bytes < 1024 * 1024:
        return f"{num_bytes / 1024:.1f} KB"
    return f"{num_bytes / (1024 * 1024):.2f} MB"


def _file_entry(full_path: str, rel_path: str) -> dict:
    try:
        stat = os.stat(full_path)
        size, mtime = stat.st_size, datetime.fromtimestamp(stat.st_mtime)
    except OSError:
        size, mtime = 0, None
    return {
        "rel_path": rel_path, "size": size, "size_display": _format_size(size),
        "mtime": mtime, "editable": _is_editable(full_path), "system": _system_for(rel_path),
    }


@bp.route("/")
@login_required
@platform_admin_required
def index():
    files = _list_files()
    total_size = sum(f["size"] for f in files)
    files_by_system = {"admin_panel": [], "agent": [], "kiosk_app": []}
    for f in files:
        files_by_system[f["system"]].append(f)
    return render_template(
        "dev_files/index.html", files=files, files_by_system=files_by_system,
        file_count=len(files), total_size_display=_format_size(total_size),
    )


def _is_live_app_file(rel_path: str) -> bool:
    """True for anything that's part of the running Admin Panel itself
    (takes effect immediately on save, via the debug reloader) — the
    Instance Agent (only reaches a kiosk MACHINE after Publish + reinstall)
    and the Kiosk App (kiosk_app/ — only reaches a kiosk machine after
    Build Kiosk Release + Push Update) never take effect live."""
    return _system_for(rel_path) == "admin_panel"


@bp.route("/file")
@login_required
@platform_admin_required
def view_file():
    rel_path = request.args.get("path", "")
    full_path = _safe_path(rel_path)
    if not os.path.isfile(full_path):
        abort(404)
    if not _is_editable(full_path):
        flash("That file type isn't editable here — use Download instead.", "warning")
        return redirect(url_for("dev_files.index"))
    try:
        with open(full_path, "r", encoding="utf-8") as f:
            content = f.read()
    except UnicodeDecodeError:
        flash("That file isn't valid UTF-8 text — can't open it in the editor.", "danger")
        return redirect(url_for("dev_files.index"))
    return render_template(
        "dev_files/edit.html", rel_path=rel_path, content=content,
        is_live_app_file=_is_live_app_file(rel_path),
        system=_system_for(rel_path),
    )


@bp.route("/file", methods=["POST"])
@login_required
@platform_admin_required
def save_file():
    rel_path = request.form.get("path", "")
    full_path = _safe_path(rel_path)
    if not os.path.isfile(full_path):
        abort(404)
    if not _is_editable(full_path):
        abort(400)

    new_content = request.form.get("content", "")

    # Timestamped snapshot of the PREVIOUS content before overwriting —
    # independent of the audit log entry below, so a bad edit can be
    # recovered from directly on disk without digging through anything
    # else. Best-effort: never block a save just because the backup
    # write failed (e.g. disk full) — that would make a full disk turn a
    # save failure into data loss instead of just a missed backup.
    try:
        os.makedirs(BACKUP_DIR, exist_ok=True)
        flat_name = rel_path.replace("/", "__")
        backup_name = f"{datetime.utcnow().strftime('%Y%m%d_%H%M%S')}_{flat_name}"
        shutil.copy2(full_path, os.path.join(BACKUP_DIR, backup_name))
    except OSError:
        pass

    with open(full_path, "w", encoding="utf-8") as f:
        f.write(new_content)

    log_action(None, current_user, "dev_file_edited", rel_path)
    db.session.commit()
    flash(f"Saved {rel_path}.", "success")
    return redirect(url_for("dev_files.view_file", path=rel_path))


@bp.route("/download")
@login_required
@platform_admin_required
def download_file():
    rel_path = request.args.get("path", "")
    full_path = _safe_path(rel_path)
    if not os.path.isfile(full_path):
        abort(404)
    return send_file(full_path, as_attachment=True, download_name=os.path.basename(full_path))


@bp.route("/upload-zip", methods=["POST"])
@login_required
@platform_admin_required
def upload_zip():
    """Extracts an uploaded .zip into the allowlisted roots — additive/
    overlay, same philosophy as CSV import and JSON restore elsewhere in
    this app: creates and overwrites matching files, never deletes
    anything not present in the zip.

    Every entry's target path goes through the exact same containment
    check (_resolve_safe) as every other write in this file — a zip is
    just another way to supply a path, and a crafted entry name like
    '../../../etc/cron.d/x' (the classic "zip slip" attack) isn't
    special-cased here; it hits the identical check a query-string path
    would and is rejected the same way. Validates every entry BEFORE
    writing any of them, so a zip with one bad entry doesn't half-apply.
    """
    f = request.files.get("file")
    if f is None or f.filename == "":
        flash("Choose a .zip file.", "danger")
        return redirect(url_for("dev_files.index"))
    if not f.filename.lower().endswith(".zip"):
        flash("That doesn't look like a .zip file.", "danger")
        return redirect(url_for("dev_files.index"))

    try:
        zf = zipfile.ZipFile(io.BytesIO(f.read()))
    except zipfile.BadZipFile:
        flash("That file isn't a valid zip archive.", "danger")
        return redirect(url_for("dev_files.index"))

    infos = zf.infolist()
    if len(infos) > MAX_ZIP_ENTRIES:
        flash(f"That zip has too many entries ({len(infos)} > {MAX_ZIP_ENTRIES} limit).", "danger")
        return redirect(url_for("dev_files.index"))
    total_uncompressed = sum(i.file_size for i in infos)
    if total_uncompressed > MAX_ZIP_TOTAL_UNCOMPRESSED_BYTES:
        flash(
            f"That zip is too large uncompressed ({total_uncompressed / (1024 * 1024):.1f} MB "
            f"> {MAX_ZIP_TOTAL_UNCOMPRESSED_BYTES / (1024 * 1024):.0f} MB limit).",
            "danger",
        )
        return redirect(url_for("dev_files.index"))

    planned, rejected = [], []
    for info in infos:
        if info.is_dir():
            continue
        if info.file_size > MAX_ZIP_ENTRY_BYTES:
            rejected.append(f"{info.filename} (too large: {info.file_size / (1024 * 1024):.1f} MB)")
            continue
        target = _resolve_safe(info.filename)
        if target is None or _is_excluded(info.filename):
            rejected.append(info.filename)
            continue
        planned.append((target, info))

    if not planned:
        flash(
            "Nothing valid to extract — every entry was rejected: " + "; ".join(rejected[:10]),
            "danger",
        )
        return redirect(url_for("dev_files.index"))

    # Snapshot the CURRENT tree as one zip before writing anything — same
    # spirit as the per-file backup in save_file(), but one file to
    # restore from instead of hunting through many for a bulk change.
    try:
        os.makedirs(BACKUP_DIR, exist_ok=True)
        backup_name = f"{datetime.utcnow().strftime('%Y%m%d_%H%M%S')}_pre_upload.zip"
        with zipfile.ZipFile(os.path.join(BACKUP_DIR, backup_name), "w", zipfile.ZIP_DEFLATED) as bz:
            for root_dir in ALLOWED_ROOT_DIRS:
                abs_root = os.path.join(BASEDIR, root_dir)
                if not os.path.isdir(abs_root):
                    continue
                for root, dirs, files in os.walk(abs_root):
                    dirs[:] = [d for d in dirs if d not in EXCLUDED_DIR_NAMES]
                    for fname in files:
                        if os.path.splitext(fname)[1].lower() in EXCLUDED_EXTENSIONS:
                            continue
                        full = os.path.join(root, fname)
                        bz.write(full, arcname=os.path.relpath(full, BASEDIR))
            for rf in ALLOWED_ROOT_FILES:
                full = os.path.join(BASEDIR, rf)
                if os.path.isfile(full):
                    bz.write(full, arcname=rf)
    except OSError:
        pass  # best-effort, same as the per-file backup — never blocks the upload

    written = 0
    for target, info in planned:
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with zf.open(info) as src, open(target, "wb") as dst:
            shutil.copyfileobj(src, dst)
        written += 1

    log_action(
        None, current_user, "dev_files_uploaded_zip",
        f"{written} file(s) from {f.filename}" + (f", {len(rejected)} rejected" if rejected else ""),
    )
    db.session.commit()

    if rejected:
        preview = "; ".join(rejected[:5]) + (f" (+{len(rejected) - 5} more)" if len(rejected) > 5 else "")
        flash(
            f"Extracted {written} file(s). Skipped {len(rejected)} entr{'y' if len(rejected) == 1 else 'ies'} "
            f"outside agent/service_files/requirements.txt: {preview}",
            "warning",
        )
    else:
        flash(f"Extracted {written} file(s) from {f.filename}. Doesn't reach kiosks until you click Publish.", "success")
    return redirect(url_for("dev_files.index"))


@bp.route("/download-zip")
@login_required
@platform_admin_required
def download_zip():
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
        for root_dir in ALLOWED_ROOT_DIRS:
            abs_root = os.path.join(BASEDIR, root_dir)
            if not os.path.isdir(abs_root):
                continue
            for root, dirs, files in os.walk(abs_root):
                dirs[:] = [d for d in dirs if d not in EXCLUDED_DIR_NAMES]
                for fname in files:
                    if os.path.splitext(fname)[1].lower() in EXCLUDED_EXTENSIONS:
                        continue
                    full = os.path.join(root, fname)
                    rel = os.path.relpath(full, BASEDIR)
                    zf.write(full, arcname=rel)
        for f in ALLOWED_ROOT_FILES:
            full = os.path.join(BASEDIR, f)
            if os.path.isfile(full):
                zf.write(full, arcname=f)
    buf.seek(0)

    log_action(None, current_user, "dev_files_downloaded_zip", "full snapshot")
    db.session.commit()
    filename = f"dev_files_{datetime.utcnow().strftime('%Y%m%d_%H%M%S')}.zip"
    return send_file(buf, as_attachment=True, download_name=filename, mimetype="application/zip")


def _write_agent_tarball(dest_path: str) -> None:
    """Shared tar/gzip step behind both rebuild_agent_tarball() (the one
    mutable, repeatedly-overwritten opslab-agent.tar.gz new installs
    download) and build_agent_tarball_snapshot() (an immutable one-off
    copy for a single push). Deliberately uses KIOSK_SHIP_ROOT_DIRS/FILES
    here, NOT the broader ALLOWED_ROOT_DIRS/FILES that browsing/editing
    now covers — this is the artifact that gets installed on real kiosk
    hardware, and must never accidentally include the Admin Panel's own
    application code."""
    tmp_path = dest_path + ".tmp"
    os.makedirs(os.path.dirname(dest_path), exist_ok=True)

    with tarfile.open(tmp_path, "w:gz") as tar:
        for root_dir in KIOSK_SHIP_ROOT_DIRS:
            abs_root = os.path.join(BASEDIR, root_dir)
            if os.path.isdir(abs_root):
                tar.add(abs_root, arcname=root_dir)
        for f in KIOSK_SHIP_ROOT_FILES:
            full = os.path.join(BASEDIR, f)
            if os.path.isfile(full):
                tar.add(full, arcname=f)
    os.replace(tmp_path, dest_path)


def rebuild_agent_tarball() -> str:
    """Rebuilds app/static/installers/opslab-agent.tar.gz from whatever is
    currently on disk under agent/ (plus service_files/ and
    requirements.txt) — the exact same tar/gzip a human would otherwise
    run by hand after editing files here. Returns AGENT_TARBALL_PATH. Used
    for publish() below (a human clicking "Publish", for new enrollments)
    and, historically, for instances.py::agent_self_update too — but a
    single-instance push now builds its own immutable snapshot instead
    (see build_agent_tarball_snapshot()), since sharing this one mutable,
    repeatedly-rebuilt file meant any other rebuild (a concurrent Publish,
    or a second push to a different instance) landing between "checksum
    computed" and "Agent downloads it" silently invalidated that checksum
    — and even with no concurrent rebuild, two builds of byte-identical
    source still produce different bytes (gzip embeds a build MTIME in
    its header), so even a same-content retry could still mismatch."""
    _write_agent_tarball(AGENT_TARBALL_PATH)
    return AGENT_TARBALL_PATH


def build_agent_tarball_snapshot() -> str:
    """Builds an immutable, uniquely-named agent/ tarball for ONE
    'agent_update' push (see instances.py::agent_self_update) instead of
    computing a checksum against the shared, repeatedly-overwritten
    AGENT_TARBALL_PATH — see rebuild_agent_tarball()'s docstring for the
    two distinct races that shared file had. Never written to again once
    created, so a checksum computed against it can never drift out from
    under a later download, no matter what else gets rebuilt/published in
    the meantime. These accumulate in AGENT_UPDATE_SNAPSHOT_DIR forever —
    nothing here prunes old ones; same as this project's other on-disk,
    never-rotated logs/artifacts, that's left as an operator's problem to
    manage disk usage for, not solved here."""
    import uuid
    snapshot_name = f"opslab-agent-{uuid.uuid4().hex}.tar.gz"
    dest_path = os.path.join(AGENT_UPDATE_SNAPSHOT_DIR, snapshot_name)
    _write_agent_tarball(dest_path)
    return dest_path


@bp.route("/publish", methods=["POST"])
@login_required
@platform_admin_required
def publish():
    """New enrollments pick this up immediately. Already-enrolled kiosks do
    NOT auto-update from this — there's no remote Agent self-update
    channel for the general case — they need install.sh/install.ps1
    re-run on them. (A narrow, single-purpose exception now exists for
    pushing just the agent/ folder to one already-enrolled instance at a
    time — see instances.py::agent_self_update / agent/self_update.py —
    but that's a deliberately minimal one-shot swap, not a real update
    pipeline like update_manager.py's for the Kiosk App.)"""
    rebuild_agent_tarball()

    log_action(None, current_user, "agent_tarball_published", "rebuilt from current dev-files")
    db.session.commit()
    flash(
        "Rebuilt opslab-agent.tar.gz (agent/ + service_files/ + requirements.txt only). "
        "New installs get these files immediately — already-enrolled kiosks still need a "
        "reinstall to pick them up.",
        "success",
    )
    return redirect(url_for("dev_files.index"))
