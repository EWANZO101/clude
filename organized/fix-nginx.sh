#!/usr/bin/env bash
#
# fix-nginx.sh — deploy the reorganized nginx configs from this folder onto
# the live server, safely.
#
# What it does:
#   1. Backs up your CURRENT /etc/nginx/sites-available and sites-enabled
#      (full copy, timestamped) before touching anything.
#   2. Copies every file from ./sites-available/ into /etc/nginx/sites-available/
#      and symlinks it into sites-enabled/. These are the deduped, no-risk files.
#   3. Leaves the 3 genuinely conflicting domains ALONE by default — see
#      ./CONFLICTS_NEEDS_YOUR_INPUT/. Pass --include-conflicts to deploy those
#      too (only do this after you've confirmed the correct backend port on
#      the server, per the comments in each of those files).
#   4. Runs `nginx -t`. If the config is broken, it automatically restores
#      your backup and exits — it will NOT reload nginx with a bad config.
#   5. Only if the test passes does it reload nginx.
#
# Usage:
#   sudo ./fix-nginx.sh                  # safe files only (recommended first run)
#   sudo ./fix-nginx.sh --include-conflicts   # also deploy the 3 flagged domains
#   sudo ./fix-nginx.sh --dry-run        # show what would happen, change nothing
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NGINX_AVAILABLE="/etc/nginx/sites-available"
NGINX_ENABLED="/etc/nginx/sites-enabled"
BACKUP_ROOT="/etc/nginx/backup-$(date +%Y%m%d-%H%M%S)"
INCLUDE_CONFLICTS=false
DRY_RUN=false

for arg in "$@"; do
    case "$arg" in
        --include-conflicts) INCLUDE_CONFLICTS=true ;;
        --dry-run) DRY_RUN=true ;;
        -h|--help)
            grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg" >&2
            exit 1
            ;;
    esac
done

log()  { echo -e "\033[1;34m[fix-nginx]\033[0m $*"; }
warn() { echo -e "\033[1;33m[fix-nginx]\033[0m $*"; }
err()  { echo -e "\033[1;31m[fix-nginx]\033[0m $*" >&2; }

if [[ "$EUID" -ne 0 ]]; then
    err "This needs to run as root (it writes to /etc/nginx). Try: sudo $0 $*"
    exit 1
fi

if [[ ! -d "$NGINX_AVAILABLE" ]] || [[ ! -d "$NGINX_ENABLED" ]]; then
    err "Couldn't find $NGINX_AVAILABLE or $NGINX_ENABLED. Is nginx installed on this machine?"
    exit 1
fi

if ! command -v nginx >/dev/null 2>&1; then
    err "nginx binary not found on PATH. Aborting."
    exit 1
fi

SAFE_DIR="$SCRIPT_DIR/sites-available"
CONFLICT_DIR="$SCRIPT_DIR/CONFLICTS_NEEDS_YOUR_INPUT"

if [[ ! -d "$SAFE_DIR" ]]; then
    err "Expected to find $SAFE_DIR next to this script — run it from inside the extracted 'organized' folder."
    exit 1
fi

if $DRY_RUN; then
    log "DRY RUN — no files will be changed, no services reloaded."
fi

# ---------------------------------------------------------------------------
# 1. Backup
# ---------------------------------------------------------------------------
log "Backing up current config to $BACKUP_ROOT"
if ! $DRY_RUN; then
    mkdir -p "$BACKUP_ROOT"
    cp -a "$NGINX_AVAILABLE" "$BACKUP_ROOT/sites-available"
    cp -a "$NGINX_ENABLED" "$BACKUP_ROOT/sites-enabled"
fi

restore_backup() {
    err "Rolling back to the backup at $BACKUP_ROOT"
    rm -rf "$NGINX_AVAILABLE" "$NGINX_ENABLED"
    cp -a "$BACKUP_ROOT/sites-available" "$NGINX_AVAILABLE"
    cp -a "$BACKUP_ROOT/sites-enabled" "$NGINX_ENABLED"
    err "Rolled back. Nginx config is unchanged from before this script ran."
}

# ---------------------------------------------------------------------------
# 2. Deploy safe files
# ---------------------------------------------------------------------------
deploy_file() {
    local src="$1"
    local name
    name="$(basename "$src")"

    log "Deploying $name"
    if $DRY_RUN; then
        return
    fi

    cp "$src" "$NGINX_AVAILABLE/$name"

    # Only symlink into sites-enabled for actual vhost files, not the
    # "default" file replacement or anything that isn't meant to be enabled.
    ln -sf "$NGINX_AVAILABLE/$name" "$NGINX_ENABLED/$name"
}

log "Deploying deduped, non-conflicting site files from $SAFE_DIR"
for f in "$SAFE_DIR"/*; do
    [[ -f "$f" ]] || continue
    deploy_file "$f"
done

# ---------------------------------------------------------------------------
# 3. Conflicts (opt-in only)
# ---------------------------------------------------------------------------
if $INCLUDE_CONFLICTS; then
    warn "Deploying the 3 flagged conflict domains too (--include-conflicts was passed)."
    warn "Make sure you've already confirmed the correct backend port on this server"
    warn "for: stocktool.opslabsystems.cloud, web.opslabsystems.cloud, websites.opslabsystems.cloud"
    if [[ -d "$CONFLICT_DIR" ]]; then
        for f in "$CONFLICT_DIR"/*.conf; do
            [[ -f "$f" ]] || continue
            deploy_file "$f"
        done
    else
        warn "No $CONFLICT_DIR folder found — nothing to deploy there."
    fi
else
    log "Skipping the 3 flagged conflict domains (default). Re-run with --include-conflicts once you've verified them."
    log "See: $CONFLICT_DIR"
fi

if $DRY_RUN; then
    log "Dry run complete. Nothing was changed."
    exit 0
fi

# ---------------------------------------------------------------------------
# 4. Test config
# ---------------------------------------------------------------------------
log "Running nginx -t"
if ! nginx -t; then
    err "nginx -t FAILED. Config is broken."
    restore_backup
    exit 1
fi

# ---------------------------------------------------------------------------
# 5. Reload
# ---------------------------------------------------------------------------
log "Config OK. Reloading nginx."
if systemctl reload nginx 2>/dev/null || service nginx reload 2>/dev/null; then
    log "Done. Nginx reloaded successfully."
    log "Backup of your previous config is at: $BACKUP_ROOT (kept — delete manually once you're confident)."
else
    err "Reload command failed even though nginx -t passed. Check 'systemctl status nginx'."
    err "Your new configs are in place but not yet active. Backup remains at $BACKUP_ROOT if you need to roll back manually:"
    err "  sudo rm -rf $NGINX_AVAILABLE $NGINX_ENABLED && sudo cp -a $BACKUP_ROOT/sites-available $NGINX_AVAILABLE && sudo cp -a $BACKUP_ROOT/sites-enabled $NGINX_ENABLED && sudo systemctl reload nginx"
    exit 1
fi
