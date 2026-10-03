"""Product builds pushed from a ticket (admin), and credential reveal (owner/staff)."""
import json
import os
import shutil
import time
import uuid

from flask import Blueprint, request, jsonify, abort, current_app, Response
from flask_login import login_required, current_user

from .. import db, product_builder as pb
from ..models import Ticket, ProductBuild
from ..models_business import AuditLog

builds_bp = Blueprint("builds", __name__)

STAGING_MAX_BYTES = 2 * 1024 ** 3          # whole uploaded folder
STAGING_MAX_FILES = 20000
CHUNK_BYTES = 8 * 1024 * 1024


def _require_admin():
    if not getattr(current_user, "is_admin", False):
        abort(403)


def _ticket_for_view(tid):
    t = Ticket.query.get_or_404(tid)
    if not (getattr(current_user, "is_staff", False) or t.user_id == current_user.id):
        abort(403)
    return t


def _staging_dir(sid):
    if not sid or not all(c in "0123456789abcdef" for c in sid) or len(sid) != 32:
        abort(404)
    d = os.path.join(pb.STAGING_ROOT, sid)
    meta = os.path.join(d, ".staging.json")
    if not os.path.isfile(meta):
        abort(404)
    with open(meta) as f:
        info = json.load(f)
    if info.get("user_id") != current_user.id:
        abort(404)
    return d, info, meta


def _sweep_staging():
    cutoff = time.time() - 24 * 3600
    if not os.path.isdir(pb.STAGING_ROOT):
        return
    for name in os.listdir(pb.STAGING_ROOT):
        p = os.path.join(pb.STAGING_ROOT, name)
        try:
            if os.path.getmtime(p) < cutoff:
                shutil.rmtree(p, ignore_errors=True)
        except OSError:
            pass


# ---------- Folder upload staging (admin) ----------
@builds_bp.route("/builds/staging", methods=["POST"])
@login_required
def staging_start():
    _require_admin()
    pb.ensure_dirs()
    _sweep_staging()
    sid = uuid.uuid4().hex
    d = os.path.join(pb.STAGING_ROOT, sid, "src")
    os.makedirs(d, mode=0o700)
    with open(os.path.join(pb.STAGING_ROOT, sid, ".staging.json"), "w") as f:
        json.dump({"user_id": current_user.id, "bytes": 0, "files": 0}, f)
    return jsonify({"ok": True, "id": sid, "chunk_size": CHUNK_BYTES})


@builds_bp.route("/builds/staging/<sid>/file", methods=["PUT"])
@login_required
def staging_file(sid):
    _require_admin()
    d, info, meta = _staging_dir(sid)
    rel = pb.safe_relpath(request.args.get("path"))
    offset = request.args.get("offset", type=int, default=0)
    length = request.content_length or 0
    if not rel:
        return jsonify({"ok": False, "error": "Bad file path."}), 400
    if length > CHUNK_BYTES:
        return jsonify({"ok": False, "error": "Chunk too large."}), 400
    if info["bytes"] + length > STAGING_MAX_BYTES:
        return jsonify({"ok": False, "error": "Folder is larger than 2 GB."}), 400

    dest = os.path.realpath(os.path.join(d, "src", rel))
    if not dest.startswith(os.path.realpath(os.path.join(d, "src")) + "/"):
        return jsonify({"ok": False, "error": "Bad file path."}), 400
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    exists = os.path.exists(dest)
    size = os.path.getsize(dest) if exists else 0
    if offset == 0 and not exists:
        if info["files"] >= STAGING_MAX_FILES:
            return jsonify({"ok": False, "error": "Too many files in folder."}), 400
        info["files"] += 1
    elif offset != size:
        return jsonify({"ok": False, "error": "Wrong offset.", "received": size}), 409

    written = 0
    with open(dest, "ab" if offset else "wb") as f:
        while True:
            buf = request.stream.read(1024 * 1024)
            if not buf:
                break
            f.write(buf)
            written += len(buf)
    info["bytes"] += written
    with open(meta, "w") as f:
        json.dump(info, f)
    return jsonify({"ok": True, "received": offset + written})


# ---------- Start a build (admin) ----------
@builds_bp.route("/tickets/<int:tid>/builds", methods=["POST"])
@login_required
def start_build(tid):
    _require_admin()
    t = Ticket.query.get_or_404(tid)
    data = request.get_json(silent=True) or {}
    name = (data.get("name") or "").strip()[:80]
    source_type = data.get("source_type")
    if not name:
        return jsonify({"ok": False, "error": "Give the product a name."}), 400

    if source_type == "path":
        try:
            source = pb.validate_source_path((data.get("path") or "").strip())
        except pb.BuildError as e:
            return jsonify({"ok": False, "error": str(e)}), 400
    elif source_type == "upload":
        d, info, _ = _staging_dir(data.get("staging_id") or "")
        if info["files"] == 0:
            return jsonify({"ok": False, "error": "The uploaded folder is empty."}), 400
        source = os.path.join(d, "src")
    else:
        return jsonify({"ok": False, "error": "Choose a source: upload a folder or a path on this VM."}), 400

    b = ProductBuild(ticket_id=t.id, created_by_id=current_user.id, name=name,
                     slug=pb.slugify(name), source_type=source_type, source_path=source,
                     status="queued", step="Queued")
    db.session.add(b)
    db.session.flush()
    AuditLog.log("product_build.start", actor=current_user, target_type="product_build",
                 target_id=b.id, meta={"ticket": t.id, "source_type": source_type,
                                       "source": source, "name": name},
                 ip=request.remote_addr)
    db.session.commit()
    pb.launch(b.id)
    return jsonify({"ok": True, "build": b.to_dict(include_internal=True)})


# ---------- List builds on a ticket ----------
@builds_bp.route("/tickets/<int:tid>/builds")
@login_required
def list_builds(tid):
    t = _ticket_for_view(tid)
    internal = getattr(current_user, "is_admin", False)
    rows = t.builds.filter(ProductBuild.status != "removed").all()
    return jsonify({"ok": True, "builds": [b.to_dict(include_internal=internal) for b in rows]})


# ---------- Reveal credentials (ticket owner or staff) ----------
@builds_bp.route("/builds/<int:bid>/credentials", methods=["POST"])
@login_required
def credentials(bid):
    b = ProductBuild.query.get_or_404(bid)
    _ticket_for_view(b.ticket_id)
    if b.status != "success" or not b.db_password_enc:
        return jsonify({"ok": False, "error": "No credentials available."}), 404
    try:
        password = pb.decrypt(b.db_password_enc)
    except Exception:
        current_app.logger.error(f"Could not decrypt credentials for build {b.id}")
        return jsonify({"ok": False, "error": "Credentials can't be decrypted (server key changed)."}), 500
    AuditLog.log("product_build.reveal_credentials", actor=current_user,
                 target_type="product_build", target_id=b.id, ip=request.remote_addr)
    db.session.commit()
    resp = jsonify({"ok": True, "credentials": {
        "host": b.db_host, "port": b.db_port, "database": b.db_name,
        "username": b.db_user, "password": password,
        "url": f"postgresql://{b.db_user}:{password}@{b.db_host}:{b.db_port}/{b.db_name}",
    }})
    resp.headers["Cache-Control"] = "no-store"
    return resp


# ---------- Build log (admin) ----------
@builds_bp.route("/builds/<int:bid>/log")
@login_required
def build_log(bid):
    _require_admin()
    b = ProductBuild.query.get_or_404(bid)
    path = pb.log_path(b.id)
    text = ""
    if os.path.isfile(path):
        with open(path, errors="replace") as f:
            f.seek(max(0, os.path.getsize(path) - 200_000))
            text = f.read()
    return Response(text or "(no log yet)", mimetype="text/plain",
                    headers={"Cache-Control": "no-store", "X-Content-Type-Options": "nosniff"})


# ---------- Remove a build (admin) ----------
@builds_bp.route("/builds/<int:bid>/remove", methods=["POST"])
@login_required
def remove(bid):
    _require_admin()
    b = ProductBuild.query.get_or_404(bid)
    if b.status in ("queued", "running"):
        return jsonify({"ok": False, "error": "Wait for the build to finish first."}), 400
    pb.remove_build(b)
    b.status = "removed"
    b.step = "Removed"
    b.db_password_enc = None
    AuditLog.log("product_build.remove", actor=current_user, target_type="product_build",
                 target_id=b.id, ip=request.remote_addr)
    db.session.commit()
    return jsonify({"ok": True})
