import os
import socket

from flask import Blueprint, render_template, redirect, url_for, flash, request, send_file, abort

from services import file_browser_service as fb
from modules.files.forms import MkdirForm, RenameForm
from utils.permissions import require_permission

files_bp = Blueprint("files", __name__, template_folder="templates")

QUICK_LINKS = [
    ("Home", "/root"),
    ("Web root", "/var/www"),
    ("Nginx config", "/etc/nginx"),
    ("This panel", "/root/server-panel"),
    ("Logs", "/var/log"),
]


def _breadcrumbs(path):
    """[(label, full_path), ...] from / down to the current directory."""
    path = os.path.abspath(path)
    if path == "/":
        return [("/", "/")]
    parts = path.strip("/").split("/")
    crumbs = [("/", "/")]
    built = ""
    for part in parts:
        built += "/" + part
        crumbs.append((part, built))
    return crumbs


@files_bp.route("/files")
@require_permission("files.manage")
def index():
    path = request.args.get("path") or "/root"
    error = None
    listing = None
    try:
        listing = fb.list_directory(path)
    except fb.FileBrowserError as exc:
        error = str(exc)
        path = "/root"
        try:
            listing = fb.list_directory(path)
        except fb.FileBrowserError:
            listing = {"path": path, "parent": None, "entries": []}

    return render_template(
        "files_index.html",
        listing=listing,
        error=error,
        breadcrumbs=_breadcrumbs(listing["path"]),
        quick_links=QUICK_LINKS,
        hostname=socket.gethostname(),
        mkdir_form=MkdirForm(),
        rename_form=RenameForm(),
        fmt_size=fb.format_size,
        fmt_modified=fb.format_modified,
    )


@files_bp.route("/files/upload", methods=["POST"])
@require_permission("files.manage")
def upload():
    dest_dir = request.form.get("path") or "/root"
    files = request.files.getlist("files")
    if not files or all(f.filename == "" for f in files):
        flash("No files selected.", "error")
        return redirect(url_for("files.index", path=dest_dir))

    saved, failed = 0, []
    for f in files:
        if not f.filename:
            continue
        try:
            fb.save_upload(dest_dir, f.filename, f)
            saved += 1
        except fb.FileBrowserError as exc:
            failed.append(str(exc))

    if saved:
        flash(f"Uploaded {saved} file{'s' if saved != 1 else ''}.", "success")
    for msg in failed:
        flash(msg, "error")
    return redirect(url_for("files.index", path=dest_dir))


@files_bp.route("/files/download")
@require_permission("files.manage")
def download():
    path = request.args.get("path", "")
    try:
        full = fb.download_path(path)
    except fb.FileBrowserError:
        abort(404)
    return send_file(full, as_attachment=True, download_name=os.path.basename(full))


@files_bp.route("/files/mkdir", methods=["POST"])
@require_permission("files.manage")
def mkdir():
    parent = request.form.get("path") or "/root"
    form = MkdirForm()
    if form.validate_on_submit():
        try:
            fb.create_directory(parent, form.name.data)
            flash(f"Created folder '{form.name.data}'.", "success")
        except fb.FileBrowserError as exc:
            flash(str(exc), "error")
    else:
        flash("Please provide a folder name.", "error")
    return redirect(url_for("files.index", path=parent))


@files_bp.route("/files/rename", methods=["POST"])
@require_permission("files.manage")
def rename():
    path = request.form.get("path", "")
    parent = os.path.dirname(path.rstrip("/")) or "/"
    form = RenameForm()
    if form.validate_on_submit():
        try:
            fb.rename_path(path, form.new_name.data)
            flash("Renamed.", "success")
        except fb.FileBrowserError as exc:
            flash(str(exc), "error")
    else:
        flash("Please provide a new name.", "error")
    return redirect(url_for("files.index", path=parent))


@files_bp.route("/files/delete", methods=["POST"])
@require_permission("files.manage")
def delete():
    path = request.form.get("path", "")
    parent = os.path.dirname(path.rstrip("/")) or "/"
    try:
        fb.delete_path(path)
        flash(f"Deleted {os.path.basename(path.rstrip('/'))}.", "success")
    except fb.FileBrowserError as exc:
        flash(str(exc), "error")
    return redirect(url_for("files.index", path=parent))
