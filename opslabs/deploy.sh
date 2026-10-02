#!/usr/bin/env bash
# Deploy the six-division services overhaul onto vps-90a29264.
#
# Usage:
#   ./deploy.sh
#   (override any default if needed, e.g. HEALTH_URL=http://127.0.0.1:8000/api/v1/health ./deploy.sh)
#
# Defaults below are set for this box:
#   APP_ROOT     /root/opslabs
#   SERVICE_NAME opslabs-app.service   (confirmed via `systemctl status`)
#   HEALTH_URL   http://127.0.0.1:5000/api/v1/health
#     ^ port 5000 is Flask's default — confirm this matches how run.py
#       actually binds on this box before relying on the health check.
#       If it's wrong, the deploy will look like it "failed" and roll
#       back even though the app is fine.
#
# What it does:
#   1. Preflight checks (paths exist, patch files present, python compiles)
#   2. Timestamped backup of every file it's about to overwrite
#   3. Copies patch files into place (idempotent — safe to re-run)
#   4. Restarts the systemd service
#   5. Health-checks /api/v1/health and a couple of new routes
#   6. On health-check failure, restores the backup and restarts again

set -euo pipefail

APP_ROOT="${APP_ROOT:-/root/opslabs}"
SERVICE_NAME="${SERVICE_NAME:-opslabs-app.service}"
HEALTH_URL="${HEALTH_URL:-http://127.0.0.1:5000/api/v1/health}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$APP_ROOT/_backups/services-overhaul-$STAMP"
PATCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/patch"

FILES=(
  "app/services_data.py"
  "app/services/__init__.py"
  "app/services/routes.py"
  "app/templates/services/detail.html"
  "app/templates/services/index.html"
  "app/templates/about.html"
  "app/templates/gateway.html"
  "app/templates/reviews/index.html"
  "app/templates/index.html"
  "app/templates/base.html"
  "app/__init__.py"
)

log()  { echo "[deploy] $*"; }
fail() { echo "[deploy] ERROR: $*" >&2; exit 1; }

# ---------- 1. Preflight ----------
log "Preflight checks..."
[ -d "$APP_ROOT" ]   || fail "APP_ROOT not found: $APP_ROOT"
[ -d "$PATCH_DIR" ]  || fail "patch/ directory not found next to this script"
for f in "${FILES[@]}"; do
  [ -f "$PATCH_DIR/$f" ] || fail "missing patch file: $f"
done

command -v python3 >/dev/null || fail "python3 not found"
for f in "${FILES[@]}"; do
  case "$f" in
    *.py)
      python3 -m py_compile "$PATCH_DIR/$f" \
        || fail "patch file fails to compile: $f"
      ;;
  esac
done
log "Preflight OK — ${#FILES[@]} files staged, all .py files compile cleanly."

# ---------- 2. Backup ----------
log "Backing up existing files to $BACKUP_DIR"
mkdir -p "$BACKUP_DIR"
for f in "${FILES[@]}"; do
  src="$APP_ROOT/$f"
  if [ -f "$src" ]; then
    mkdir -p "$BACKUP_DIR/$(dirname "$f")"
    cp -p "$src" "$BACKUP_DIR/$f"
  fi
done
log "Backup complete."

restore_and_bail() {
  log "Health check failed — restoring backup from $BACKUP_DIR"
  for f in "${FILES[@]}"; do
    if [ -f "$BACKUP_DIR/$f" ]; then
      mkdir -p "$APP_ROOT/$(dirname "$f")"
      cp -p "$BACKUP_DIR/$f" "$APP_ROOT/$f"
    fi
  done
  if systemctl is-enabled "$SERVICE_NAME" >/dev/null 2>&1; then
    sudo systemctl restart "$SERVICE_NAME" || true
  fi
  fail "Deploy rolled back. Nothing left in a broken state. Backup kept at $BACKUP_DIR"
}

# ---------- 3. Apply (idempotent copy-in) ----------
log "Applying patch files..."
for f in "${FILES[@]}"; do
  dest="$APP_ROOT/$f"
  mkdir -p "$(dirname "$dest")"
  cp -p "$PATCH_DIR/$f" "$dest"
done
log "Applied ${#FILES[@]} files."

# New package needs an __init__.py-having directory registered as a
# blueprint — nothing else to migrate; no DB schema changes in this patch.

# ---------- 4. Restart service ----------
if systemctl is-enabled "$SERVICE_NAME" >/dev/null 2>&1; then
  log "Restarting $SERVICE_NAME..."
  sudo systemctl restart "$SERVICE_NAME"
  sleep 2
else
  log "WARNING: systemd service '$SERVICE_NAME' not found/enabled — restart it manually, then re-run with HEALTH_URL set once it's up."
fi

# ---------- 5. Health check ----------
log "Health-checking $HEALTH_URL ..."
ok=0
for i in 1 2 3 4 5; do
  if curl -fsS -m 5 "$HEALTH_URL" >/dev/null 2>&1; then
    ok=1
    break
  fi
  sleep 2
done
[ "$ok" -eq 1 ] || restore_and_bail

# Spot-check a couple of the new routes actually resolve (not just /health)
BASE_URL="$(echo "$HEALTH_URL" | sed -E 's#/api/v1/health$##')"
for path in "/services/website-development" "/about"; do
  code="$(curl -s -o /dev/null -w '%{http_code}' -m 5 "$BASE_URL$path" || echo 000)"
  if [ "$code" != "200" ] && [ "$code" != "302" ]; then
    log "Route check failed: $path -> HTTP $code"
    restore_and_bail
  fi
  log "Route OK: $path -> HTTP $code"
done

log "Deploy successful. Backup retained at: $BACKUP_DIR"
