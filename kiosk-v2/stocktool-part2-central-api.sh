#!/usr/bin/env bash
#
# stocktool-part2-central-api.sh
#
# Adds the central-API surface a kiosk-v2 desktop client needs to this
# existing stocktool-api deployment:
#   - Installation registration / heartbeat / admin listing
#   - Config endpoint (sync cadence, app settings)
#   - Update/version-check endpoint + admin release publishing
#   - Sync pull (incremental) + push (with last-write-wins conflict
#     detection) for items/tools/projects/barcodes/users
#
# Safe to re-run — every step is idempotent. Every file this run
# creates or touches is backed up first; a failed import sanity check
# auto-rolls-back everything this run did, before touching the DB or
# restarting anything.
#
# Usage:
#   ./stocktool-part2-central-api.sh --api-dir /root/stocktool-api [--api-service stocktool-api] [--dry-run]

set -u

API_DIR="/root/stocktool-api"
API_SERVICE="stocktool-api"
API_PORT="5032"
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --api-dir) API_DIR="$2"; shift 2 ;;
    --api-service) API_SERVICE="$2"; shift 2 ;;
    --api-port) API_PORT="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

TS="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="./stocktool-part2_${TS}.log"
BACKUP_DIR="./stocktool-part2-backups_${TS}"
mkdir -p "$BACKUP_DIR"

log()  { echo "$(date '+%H:%M:%S') $*" | tee -a "$LOG_FILE"; }
hr()   { log "────────────────────────────────────────────────────────────"; }
section() { echo "" | tee -a "$LOG_FILE"; hr; log "## $*"; hr; }
ok()   { log "  [OK]   $*"; }
skip() { log "  [SKIP] $* (already applied)"; }
err()  { log "  [FAIL] $*"; FAILED=1; }

FAILED=0
TOUCHED_FILES=()

API_DIR="$(cd "$API_DIR" 2>/dev/null && pwd)" || { echo "FATAL: --api-dir not found"; exit 1; }

PY=""
for cand in "$API_DIR/venv/bin/python" "$API_DIR/.venv/bin/python" "$(command -v python3)"; do
  if [ -n "$cand" ] && [ -x "$cand" ]; then PY="$cand"; break; fi
done
[ -z "$PY" ] && { echo "FATAL: no python3 found"; exit 1; }
PY="$(cd "$(dirname "$PY")" && pwd)/$(basename "$PY")"

backup_file() {
  local f="$1"
  local rel="${f#/}"
  mkdir -p "$BACKUP_DIR/$(dirname "$rel")"
  [ -f "$f" ] && cp "$f" "$BACKUP_DIR/$rel"
  TOUCHED_FILES+=("$f")
}

rollback_all_touched_files() {
  log "  Rolling back ${#TOUCHED_FILES[@]} file(s) touched this run..."
  for f in "${TOUCHED_FILES[@]}"; do
    local rel="${f#/}"
    if [ -f "$BACKUP_DIR/$rel" ]; then
      cp "$BACKUP_DIR/$rel" "$f"
      log "    restored $f"
    else
      rm -f "$f"
      log "    removed (was newly created this run) $f"
    fi
  done
}

# Creates a file only if it doesn't already exist — used for the new
# files this part adds. Idempotent by construction: a second run just
# skips everything since the files are already there.
create_if_missing() {
  local target="$1" content_file="$2" label="$3"
  if [ -f "$target" ]; then
    skip "$label"
    return
  fi
  if [ "$DRY_RUN" = "1" ]; then
    ok "$label (dry-run, would create)"
    return
  fi
  mkdir -p "$(dirname "$target")"
  cp "$content_file" "$target"
  TOUCHED_FILES+=("$target")
  ok "$label"
}

# For the two existing files this part edits (models/__init__.py,
# app/__init__.py) — same tested exact-text patcher used throughout
# this project.
apply_patch() {
  local target="$1" old_file="$2" new_file="$3" label="$4"

  if [ ! -f "$target" ]; then
    err "$label — target file not found: $target"
    return
  fi
  if [ "$DRY_RUN" = "1" ]; then
    STATE="$("$PY" - "$target" "$old_file" "$new_file" <<'PYEOF'
import sys
target, old_file, new_file = sys.argv[1], sys.argv[2], sys.argv[3]
with open(target) as f: content = f.read()
with open(new_file) as f: new = f.read()
with open(old_file) as f: old = f.read()
if new in content: print("ALREADY")
elif old in content: print("WOULD_PATCH")
else: print("DIVERGED")
PYEOF
)"
    case "$STATE" in
      ALREADY) skip "$label" ;;
      WOULD_PATCH) ok "$label (dry-run, would patch)" ;;
      *) err "$label (dry-run) — anchor text not found" ;;
    esac
    return
  fi

  backup_file "$target"
  RESULT="$("$PY" - "$target" "$old_file" "$new_file" <<'PYEOF'
import sys
target, old_file, new_file = sys.argv[1], sys.argv[2], sys.argv[3]
with open(target) as f: content = f.read()
with open(old_file) as f: old = f.read()
with open(new_file) as f: new = f.read()
if new in content:
    print("ALREADY"); sys.exit(0)
if old not in content:
    print("ANCHOR_NOT_FOUND"); sys.exit(1)
if content.count(old) > 1:
    print("ANCHOR_NOT_UNIQUE"); sys.exit(1)
content = content.replace(old, new, 1)
with open(target, "w") as f: f.write(content)
print("PATCHED")
PYEOF
)"
  if [ "$RESULT" = "PATCHED" ]; then ok "$label"
  elif [ "$RESULT" = "ALREADY" ]; then skip "$label"
  else err "$label — $RESULT (file has diverged from what this script expects; left untouched)"
  fi
}

WORK="$(mktemp -d /tmp/stocktool-part2-snippets.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

echo "StockTool Part 2 (central API) — $TS" > "$LOG_FILE"
log "API dir: $API_DIR   Backups: $BACKUP_DIR"

# ═════════════════════════════════════════════════════════════════════════
section "1. New models: Installation, ReleaseVersion"
# ═════════════════════════════════════════════════════════════════════════

cat > "$WORK/installation.py" << 'PYEOF'
import secrets
import hashlib
from datetime import datetime, timezone
from app.extensions import db


def _now():
    return datetime.now(timezone.utc)


class Installation(db.Model):
    """
    A registered kiosk-v2 desktop installation. The central API never
    stores this installation's business data (items/tools/projects stay
    on the existing per-tenant tables this same API already serves) —
    this table exists purely to authenticate and track the health of
    each desktop client talking to sync/update/config endpoints.
    """
    __tablename__ = "installations"

    id = db.Column(db.Integer, primary_key=True)
    installation_id = db.Column(db.String(36), unique=True, nullable=False, index=True)
    device_name = db.Column(db.String(120), nullable=True)
    app_version = db.Column(db.String(32), nullable=True)
    token_hash = db.Column(db.String(128), nullable=False)
    is_active = db.Column(db.Boolean, default=True, nullable=False)
    created_at = db.Column(db.DateTime, default=_now, nullable=False)
    last_seen_at = db.Column(db.DateTime, nullable=True)
    last_sync_at = db.Column(db.DateTime, nullable=True)

    @staticmethod
    def _hash_token(token: str) -> str:
        return hashlib.sha256(token.encode()).hexdigest()

    @classmethod
    def create_with_token(cls, installation_id: str, device_name: str, app_version: str):
        """Returns (installation, plaintext_token) — the plaintext token is
        shown to the caller exactly once, at registration time, same as
        an API key. Only its hash is ever stored."""
        token = secrets.token_urlsafe(32)
        inst = cls(
            installation_id=installation_id,
            device_name=device_name,
            app_version=app_version,
            token_hash=cls._hash_token(token),
        )
        db.session.add(inst)
        return inst, token

    @classmethod
    def find_by_token(cls, token: str):
        if not token:
            return None
        return cls.query.filter_by(token_hash=cls._hash_token(token), is_active=True).first()

    def touch(self):
        self.last_seen_at = _now()

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "installation_id": self.installation_id,
            "device_name": self.device_name,
            "app_version": self.app_version,
            "is_active": self.is_active,
            "created_at": self.created_at.isoformat() if self.created_at else None,
            "last_seen_at": self.last_seen_at.isoformat() if self.last_seen_at else None,
            "last_sync_at": self.last_sync_at.isoformat() if self.last_sync_at else None,
        }
PYEOF
create_if_missing "$API_DIR/app/models/installation.py" "$WORK/installation.py" "models/installation.py"

cat > "$WORK/release.py" << 'PYEOF'
from datetime import datetime, timezone
from app.extensions import db


class ReleaseVersion(db.Model):
    """A published kiosk-v2 desktop release. The desktop app polls
    /api/updates/latest and compares against its own version string."""
    __tablename__ = "release_versions"

    id = db.Column(db.Integer, primary_key=True)
    version = db.Column(db.String(32), unique=True, nullable=False)  # e.g. "2.1.0"
    channel = db.Column(db.String(20), nullable=False, default="stable", index=True)  # stable | beta
    download_url = db.Column(db.String(500), nullable=False)
    checksum_sha256 = db.Column(db.String(64), nullable=False)
    release_notes = db.Column(db.Text, nullable=True)
    min_supported_version = db.Column(db.String(32), nullable=True)  # older clients must upgrade first
    is_active = db.Column(db.Boolean, default=True, nullable=False)
    published_at = db.Column(db.DateTime, default=lambda: datetime.now(timezone.utc), nullable=False)

    def to_dict(self) -> dict:
        return {
            "version": self.version,
            "channel": self.channel,
            "download_url": self.download_url,
            "checksum_sha256": self.checksum_sha256,
            "release_notes": self.release_notes,
            "min_supported_version": self.min_supported_version,
            "published_at": self.published_at.isoformat() if self.published_at else None,
        }
PYEOF
create_if_missing "$API_DIR/app/models/release.py" "$WORK/release.py" "models/release.py"

cat > "$WORK/models_init_old.txt" << 'EOF'
from .settings import Settings

__all__ = [
    "User", "Role",
    "Item",
    "Tool", "ToolStatus",
    "ToolHistory", "HistoryAction",
    "AuditLog", "AuditAction",
    "Barcode",
    "Project",
    "Settings",
]
EOF
cat > "$WORK/models_init_new.txt" << 'EOF'
from .settings import Settings
from .installation import Installation
from .release import ReleaseVersion

__all__ = [
    "User", "Role",
    "Item",
    "Tool", "ToolStatus",
    "ToolHistory", "HistoryAction",
    "AuditLog", "AuditAction",
    "Barcode",
    "Project",
    "Settings",
    "Installation",
    "ReleaseVersion",
]
EOF
apply_patch "$API_DIR/app/models/__init__.py" "$WORK/models_init_old.txt" "$WORK/models_init_new.txt" "models/__init__.py: register new models"

# ═════════════════════════════════════════════════════════════════════════
section "2. Install-token auth helper"
# ═════════════════════════════════════════════════════════════════════════

cat > "$WORK/install_auth.py" << 'PYEOF'
from functools import wraps
from flask import request, jsonify, g
from app.models import Installation


def install_token_required(fn):
    """
    Gates sync/config endpoints behind a per-installation token (issued
    once at registration — see app/api/installations.py) rather than the
    per-user JWT used elsewhere. A desktop kiosk install represents a
    trusted DEVICE relaying many local users' actions, not one user's
    session, so it needs its own credential type.
    """
    @wraps(fn)
    def wrapper(*args, **kwargs):
        auth_header = request.headers.get("Authorization", "")
        token = auth_header[7:] if auth_header.startswith("Bearer ") else None
        installation = Installation.find_by_token(token) if token else None
        if not installation:
            return jsonify({"error": "Invalid or missing installation token."}), 401
        g.installation = installation
        return fn(*args, **kwargs)
    return wrapper
PYEOF
create_if_missing "$API_DIR/app/utils/install_auth.py" "$WORK/install_auth.py" "utils/install_auth.py"

# ═════════════════════════════════════════════════════════════════════════
section "3. Installation registration / heartbeat / admin listing"
# ═════════════════════════════════════════════════════════════════════════

cat > "$WORK/installations.py" << 'PYEOF'
import uuid
from flask import Blueprint, request, jsonify, g
from flask_jwt_extended import jwt_required
from app.extensions import db
from app.models import Installation
from app.utils.decorators import admin_required
from app.utils.install_auth import install_token_required

api_installations_bp = Blueprint("api_installations", __name__, url_prefix="/api/installations")


@api_installations_bp.route("/register", methods=["POST"])
def register():
    """
    First-run registration for a kiosk-v2 desktop install. Returns an
    installation_id + a plaintext token shown exactly once — the desktop
    app stores the token locally and sends it as a Bearer token on every
    subsequent sync/config/update-check request.

    No login/admin auth required to call this — an install has no
    credentials yet at this point. In production this should be paired
    with a short-lived one-time registration code shown during setup
    (Part 6, alongside the Cloudflare Tunnel provisioning) so registration
    can't be spammed by an arbitrary caller; that gate isn't in place yet
    in this part.
    """
    data = request.get_json(silent=True) or {}
    device_name = (data.get("device_name") or "").strip()[:120] or "Unnamed Kiosk"
    app_version = (data.get("app_version") or "").strip()[:32] or None

    installation_id = str(uuid.uuid4())
    inst, token = Installation.create_with_token(installation_id, device_name, app_version)
    db.session.commit()

    return jsonify({
        "installation_id": installation_id,
        "token": token,
        "message": "Store this token locally — it will not be shown again.",
    }), 201


@api_installations_bp.route("/heartbeat", methods=["POST"])
@install_token_required
def heartbeat():
    """Lightweight check-in — the desktop app calls this periodically so
    admins can see which kiosks are online and on what version."""
    data = request.get_json(silent=True) or {}
    app_version = (data.get("app_version") or "").strip()[:32]
    if app_version:
        g.installation.app_version = app_version
    g.installation.touch()
    db.session.commit()
    return jsonify({"ok": True, "server_time": _utcnow_iso()}), 200


@api_installations_bp.route("", methods=["GET"])
@jwt_required()
@admin_required
def list_installations():
    """Admin visibility into registered kiosks — which devices exist,
    what version they're on, when they last checked in."""
    installations = Installation.query.order_by(Installation.created_at.desc()).all()
    return jsonify([i.to_dict() for i in installations]), 200


@api_installations_bp.route("/<installation_id>", methods=["DELETE"])
@jwt_required()
@admin_required
def deactivate_installation(installation_id):
    """Revoke an installation's token (e.g. a kiosk device was
    decommissioned or lost) — it can no longer sync/pull config."""
    inst = Installation.query.filter_by(installation_id=installation_id).first()
    if not inst:
        return jsonify({"error": "Installation not found."}), 404
    inst.is_active = False
    db.session.commit()
    return jsonify({"message": "Installation deactivated."}), 200


def _utcnow_iso() -> str:
    from datetime import datetime, timezone
    return datetime.now(timezone.utc).isoformat()
PYEOF
create_if_missing "$API_DIR/app/api/installations.py" "$WORK/installations.py" "api/installations.py"

# ═════════════════════════════════════════════════════════════════════════
section "4. Config endpoint"
# ═════════════════════════════════════════════════════════════════════════

cat > "$WORK/config.py" << 'PYEOF'
from flask import Blueprint, jsonify
from app.models import Settings
from app.utils.install_auth import install_token_required

api_kiosk_config_bp = Blueprint("api_kiosk_config", __name__, url_prefix="/api/config")


@api_kiosk_config_bp.route("", methods=["GET"])
@install_token_required
def get_config():
    """
    Configuration the desktop client needs at startup / periodically:
    existing admin-managed settings, plus sync/update-check cadence.
    Kept separate from the admin-facing /api/settings endpoint (which
    manages a broader set of admin-console settings) so the desktop
    client only ever sees the subset relevant to it.
    """
    settings = Settings.get()
    return jsonify({
        "app_name": settings.app_name,
        "default_low_stock_threshold": settings.default_low_stock_threshold,
        "sync_interval_seconds": 120,
        "update_check_interval_seconds": 3600,
        "heartbeat_interval_seconds": 300,
    }), 200
PYEOF
create_if_missing "$API_DIR/app/api/config.py" "$WORK/config.py" "api/config.py"

# ═════════════════════════════════════════════════════════════════════════
section "5. Update / version-check endpoints"
# ═════════════════════════════════════════════════════════════════════════

cat > "$WORK/updates.py" << 'PYEOF'
from flask import Blueprint, request, jsonify
from flask_jwt_extended import jwt_required
from app.extensions import db
from app.models import ReleaseVersion
from app.utils.decorators import admin_required
from app.utils.install_auth import install_token_required

api_updates_bp = Blueprint("api_updates", __name__, url_prefix="/api/updates")


@api_updates_bp.route("/latest", methods=["GET"])
@install_token_required
def latest():
    """
    The desktop client's update-check call. Query param `channel`
    defaults to stable. Returns the newest active release on that
    channel — the client compares `version` against its own and decides
    whether to prompt for/perform an update.
    """
    channel = request.args.get("channel", "stable")
    release = (ReleaseVersion.query
               .filter_by(channel=channel, is_active=True)
               .order_by(ReleaseVersion.published_at.desc())
               .first())
    if not release:
        return jsonify({"error": f"No active release on channel '{channel}'."}), 404
    return jsonify(release.to_dict()), 200


@api_updates_bp.route("", methods=["POST"])
@jwt_required()
@admin_required
def publish_release():
    """Admin-only: publish a new release. The desktop client never
    uploads anything here — this is how a new build gets announced."""
    data = request.get_json(silent=True) or {}
    version = (data.get("version") or "").strip()
    download_url = (data.get("download_url") or "").strip()
    checksum_sha256 = (data.get("checksum_sha256") or "").strip()
    channel = (data.get("channel") or "stable").strip()

    errors = []
    if not version:
        errors.append("version is required.")
    if not download_url:
        errors.append("download_url is required.")
    if not checksum_sha256 or len(checksum_sha256) != 64:
        errors.append("checksum_sha256 must be a 64-character SHA-256 hex digest.")
    if ReleaseVersion.query.filter_by(version=version).first():
        errors.append(f"Version '{version}' already exists.")
    if errors:
        return jsonify({"error": " ".join(errors)}), 400

    release = ReleaseVersion(
        version=version, channel=channel, download_url=download_url,
        checksum_sha256=checksum_sha256,
        release_notes=data.get("release_notes"),
        min_supported_version=data.get("min_supported_version"),
    )
    db.session.add(release)
    db.session.commit()
    return jsonify(release.to_dict()), 201
PYEOF
create_if_missing "$API_DIR/app/api/updates.py" "$WORK/updates.py" "api/updates.py"

# ═════════════════════════════════════════════════════════════════════════
section "6. Sync pull / push"
# ═════════════════════════════════════════════════════════════════════════

cat > "$WORK/sync.py" << 'PYEOF'
from datetime import datetime, timezone
from flask import Blueprint, request, jsonify, g
from app.extensions import db
from app.models import Item, Tool, Project, Barcode, User
from app.utils.audit import log_action
from app.models.audit_log import AuditAction
from app.utils.install_auth import install_token_required

api_sync_bp = Blueprint("api_sync", __name__, url_prefix="/api/sync")

_PULLABLE = {"items": Item, "tools": Tool, "projects": Project}


def _parse_since(raw):
    if not raw:
        return None
    try:
        dt = datetime.fromisoformat(raw.replace("Z", "+00:00"))
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt
    except ValueError:
        return None


@api_sync_bp.route("/pull", methods=["GET"])
@install_token_required
def pull():
    """
    Incremental pull: returns rows changed since `since` (ISO-8601,
    omit or leave blank for a full first sync) for each requested type.
    Always returns `server_time` — the client should store that as the
    `since` value for its NEXT pull rather than its own clock, so pull
    windows are correct even if the client's clock is off.
    """
    since = _parse_since(request.args.get("since"))
    requested_types = [t.strip() for t in request.args.get("types", "").split(",") if t.strip()] \
        or list(_PULLABLE.keys()) + ["barcodes", "users"]

    result = {}

    for type_name in requested_types:
        if type_name in _PULLABLE:
            model = _PULLABLE[type_name]
            query = model.query
            if since:
                query = query.filter(model.updated_at > since)
            rows = query.order_by(model.updated_at.asc()).limit(500).all()
            result[type_name] = [r.to_dict() for r in rows]

        elif type_name == "barcodes":
            # Barcode rows have no updated_at (they're immutable once
            # created) — a full pull each time is fine given the small,
            # slow-growing size of this table relative to items/tools.
            result["barcodes"] = [b.to_dict() for b in Barcode.query.all()]

        elif type_name == "users":
            # Read-mostly mirror for kiosk badge-login — id, username,
            # role, badge code, active flag only. No password hash, ever.
            users = User.query.filter_by(is_active=True).all()
            result["users"] = [{
                "id": u.id, "username": u.username, "role": u.role,
                "badge_code": u.barcode.code if u.barcode else None,
                "is_active": u.is_active,
            } for u in users]

    g.installation.last_sync_at = datetime.now(timezone.utc)
    db.session.commit()

    return jsonify({
        "server_time": datetime.now(timezone.utc).isoformat(),
        "data": result,
    }), 200


@api_sync_bp.route("/push", methods=["POST"])
@install_token_required
def push():
    """
    Upload offline changes. Each entry needs `server_id` (the cloud row's
    id, learned from a prior pull) and `local_updated_at` (when the
    change was made on the device). Conflict rule: last-write-wins,
    server-side clock is authoritative — if the server row's own
    updated_at is NEWER than the client's local_updated_at, that means
    something else changed it more recently than this offline edit, so
    it's rejected as a conflict rather than silently overwritten.
    """
    data = request.get_json(silent=True) or {}
    results = {"items": [], "tools": [], "barcodes": []}

    for entry in data.get("items", []):
        results["items"].append(_push_item(entry))

    for entry in data.get("tools", []):
        results["tools"].append(_push_tool(entry))

    for entry in data.get("barcodes", []):
        results["barcodes"].append(_push_barcode(entry))

    g.installation.last_sync_at = datetime.now(timezone.utc)
    db.session.commit()

    return jsonify({"server_time": datetime.now(timezone.utc).isoformat(), "results": results}), 200


def _conflict_check(row, local_updated_at_raw):
    local_dt = _parse_since(local_updated_at_raw)
    row_dt = row.updated_at
    if row_dt and row_dt.tzinfo is None:
        row_dt = row_dt.replace(tzinfo=timezone.utc)  # SQLite round-trips naive; app always writes UTC
    if local_dt and row_dt and row_dt > local_dt:
        return True
    return False


def _push_item(entry):
    server_id = entry.get("server_id")
    delta = entry.get("delta")
    item = db.session.get(Item, server_id) if server_id else None
    if not item:
        return {"server_id": server_id, "status": "not_found"}
    if not isinstance(delta, int) or delta == 0:
        return {"server_id": server_id, "status": "error", "message": "delta must be a non-zero integer."}

    if _conflict_check(item, entry.get("local_updated_at")):
        return {"server_id": server_id, "status": "conflict", "current": item.to_dict()}

    item.adjust_stock(delta)
    log_action(AuditAction.ITEM_STOCK_ADJUSTED, "item", item.id, item.name,
               f"Kiosk sync: {delta:+d} ({item.quantity - delta} → {item.quantity})",
               quantity_delta=delta, device="kiosk-sync")
    return {"server_id": server_id, "status": "applied", "current": item.to_dict()}


def _push_tool(entry):
    server_id = entry.get("server_id")
    action = entry.get("action")
    tool = db.session.get(Tool, server_id) if server_id else None
    if not tool:
        return {"server_id": server_id, "status": "not_found"}
    if action not in ("checkout", "checkin"):
        return {"server_id": server_id, "status": "error", "message": "action must be 'checkout' or 'checkin'."}

    if _conflict_check(tool, entry.get("local_updated_at")):
        return {"server_id": server_id, "status": "conflict", "current": tool.to_dict()}

    from app.models import ToolStatus
    if action == "checkout":
        if tool.status == ToolStatus.CHECKED_OUT:
            return {"server_id": server_id, "status": "conflict", "current": tool.to_dict(),
                    "message": "Already checked out server-side."}
        tool.status = ToolStatus.CHECKED_OUT
        tool.checked_out_at = datetime.now(timezone.utc)
    else:
        tool.status = ToolStatus.AVAILABLE
        tool.checked_out_by_id = None
        tool.checked_out_at = None
    tool.updated_at = datetime.now(timezone.utc)

    return {"server_id": server_id, "status": "applied", "current": tool.to_dict()}


def _push_barcode(entry):
    code = (entry.get("code") or "").strip().upper()
    entity_type = entry.get("entity_type")
    server_id = entry.get("server_id")
    if not code or entity_type not in ("item", "tool", "project") or not server_id:
        return {"code": code, "status": "error", "message": "code, entity_type, and server_id are required."}

    if Barcode.query.filter_by(code=code).first():
        return {"code": code, "status": "conflict", "message": "Code already registered."}

    model = {"item": Item, "tool": Tool, "project": Project}[entity_type]
    entity = db.session.get(model, server_id)
    if not entity:
        return {"code": code, "status": "not_found"}

    fk_field = f"{entity_type}_id"
    bc = Barcode(code=code, **{fk_field: entity.id})
    db.session.add(bc)
    return {"code": code, "status": "applied"}
PYEOF
create_if_missing "$API_DIR/app/api/sync.py" "$WORK/sync.py" "api/sync.py"

# ═════════════════════════════════════════════════════════════════════════
section "7. Register new blueprints"
# ═════════════════════════════════════════════════════════════════════════

cat > "$WORK/init_old.txt" << 'EOF'
    from app.api.settings import api_settings_bp
    app.register_blueprint(api_settings_bp)
EOF
cat > "$WORK/init_new.txt" << 'EOF'
    from app.api.settings import api_settings_bp
    app.register_blueprint(api_settings_bp)

    from app.api.installations import api_installations_bp
    app.register_blueprint(api_installations_bp)

    from app.api.config import api_kiosk_config_bp
    app.register_blueprint(api_kiosk_config_bp)

    from app.api.updates import api_updates_bp
    app.register_blueprint(api_updates_bp)

    from app.api.sync import api_sync_bp
    app.register_blueprint(api_sync_bp)
EOF
apply_patch "$API_DIR/app/__init__.py" "$WORK/init_old.txt" "$WORK/init_new.txt" "app/__init__.py: register Part 2 blueprints"

# ═════════════════════════════════════════════════════════════════════════
section "8. Sanity check — does the app still import cleanly?"
# ═════════════════════════════════════════════════════════════════════════

if [ "$DRY_RUN" = "1" ]; then
  log "  [DRY-RUN] skipped"
else
  IMPORT_CHECK="$(cd "$API_DIR" && "$PY" -c "
import sys
sys.path.insert(0, '.')
from app import create_app
create_app()
print('IMPORT_OK')
" 2>&1)"
  echo "$IMPORT_CHECK" >> "$LOG_FILE"
  if echo "$IMPORT_CHECK" | grep -q "IMPORT_OK"; then
    ok "app still imports cleanly after all patches"
  else
    err "app FAILED to import after patching — see $LOG_FILE for the traceback"
    rollback_all_touched_files
    section "SUMMARY"
    log "Aborted after rollback due to a failed import sanity check. See $LOG_FILE."
    exit 3
  fi
fi

# ═════════════════════════════════════════════════════════════════════════
section "9. Create new tables (Installation, ReleaseVersion)"
# ═════════════════════════════════════════════════════════════════════════
# db.create_all() only creates tables that don't exist yet — it never
# alters or touches existing tables, so this is safe to run against a
# live database with existing data.

if [ "$DRY_RUN" = "1" ]; then
  log "  [DRY-RUN] would run db.create_all() to add the two new tables"
else
  CREATE_OUT="$(cd "$API_DIR" && "$PY" -c "
import sys; sys.path.insert(0, '.')
from app import create_app
from app.extensions import db
app = create_app()
with app.app_context():
    db.create_all()
print('TABLES_OK')
" 2>&1)"
  echo "$CREATE_OUT" >> "$LOG_FILE"
  if echo "$CREATE_OUT" | grep -q "TABLES_OK"; then
    ok "installations / release_versions tables ready"
  else
    err "failed to create new tables — see $LOG_FILE"
  fi
fi

# ═════════════════════════════════════════════════════════════════════════
section "10. Restart service"
# ═════════════════════════════════════════════════════════════════════════

if [ "$DRY_RUN" = "1" ]; then
  log "  [DRY-RUN] would restart $API_SERVICE"
else
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl restart "$API_SERVICE" 2>>"$LOG_FILE"; then
      ok "restarted $API_SERVICE"
      sleep 2
    else
      err "failed to restart $API_SERVICE — check 'systemctl status $API_SERVICE'"
    fi
  else
    err "systemctl not found — restart $API_SERVICE manually"
  fi
fi

# ═════════════════════════════════════════════════════════════════════════
section "11. Verification"
# ═════════════════════════════════════════════════════════════════════════

if [ "$DRY_RUN" = "1" ]; then
  log "  [DRY-RUN] skipped"
else
  REG_OUT="$(curl -s -w '\nHTTP:%{http_code}' -X POST "http://127.0.0.1:${API_PORT}/api/installations/register" \
    -H "Content-Type: application/json" -d '{"device_name":"verify-script","app_version":"0.0.0-verify"}')"
  if echo "$REG_OUT" | grep -q "HTTP:201"; then
    ok "installation registration works"
    TOKEN="$("$PY" -c "
import sys, json
raw = '''$REG_OUT'''
body = raw.split(chr(10)+'HTTP:')[0]
print(json.loads(body)['token'])
" 2>/dev/null)"
    if [ -n "$TOKEN" ]; then
      CONFIG_CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${API_PORT}/api/config" -H "Authorization: Bearer $TOKEN")"
      [ "$CONFIG_CODE" = "200" ] && ok "config endpoint responds with a valid install token" \
        || err "config endpoint returned $CONFIG_CODE"

      SYNC_CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${API_PORT}/api/sync/pull" -H "Authorization: Bearer $TOKEN")"
      [ "$SYNC_CODE" = "200" ] && ok "sync pull endpoint responds with a valid install token" \
        || err "sync pull endpoint returned $SYNC_CODE"
    else
      err "could not parse installation token from registration response"
    fi
  else
    err "installation registration failed: $(echo "$REG_OUT" | head -1)"
  fi
fi

# ═════════════════════════════════════════════════════════════════════════
section "SUMMARY"
# ═════════════════════════════════════════════════════════════════════════

if [ "$FAILED" = "1" ]; then
  log "Some steps FAILED — review $LOG_FILE. Backups: $BACKUP_DIR"
  exit 1
else
  log "All steps completed. New endpoints: /api/installations/*, /api/config, /api/updates/*, /api/sync/*"
  log "Backups kept at $BACKUP_DIR — safe to delete once confirmed."
  exit 0
fi
