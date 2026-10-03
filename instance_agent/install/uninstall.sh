#!/usr/bin/env bash
#
# OpsLab Instance Agent — Linux uninstaller. Counterpart to install.sh.
#
# By default, PRESERVES /etc/opslab-agent (settings.json — the instance's
# identity/secret — plus any downloaded packages and recovery points) so a
# machine can be reinstalled onto without losing its registration or its
# Last-Known-Good rollback history. Pass --purge to remove that too, which
# is irreversible and means the machine will need to be re-enrolled with a
# fresh registration token if the Agent is ever reinstalled.
#
# Usage:
#   sudo ./install/uninstall.sh [--purge]
set -euo pipefail

INSTALL_DIR="/opt/opslab-agent"
DATA_DIR="/etc/opslab-agent"
SERVICE_USER="opslab-agent"
SERVICE_GROUP="opslab-agent"
SYSTEMD_UNIT_DEST="/etc/systemd/system/opslab-agent.service"

log()  { echo "[opslab-agent-uninstall] $*"; }

PURGE=false
for arg in "$@"; do
    case "$arg" in
        --purge) PURGE=true ;;
        -h|--help) grep '^#' "$0" | sed 's/^#//'; exit 0 ;;
        *) echo "unrecognized argument: $arg" >&2; exit 1 ;;
    esac
done

[[ "$(id -u)" -eq 0 ]] || { echo "must be run as root (try: sudo $0)" >&2; exit 1; }

if systemctl list-unit-files 2>/dev/null | grep -q '^opslab-agent\.service'; then
    log "Stopping and disabling opslab-agent service..."
    systemctl stop opslab-agent.service || true
    systemctl disable opslab-agent.service || true
fi

if [[ -f "$SYSTEMD_UNIT_DEST" ]]; then
    log "Removing systemd unit..."
    rm -f "$SYSTEMD_UNIT_DEST"
    systemctl daemon-reload || true
fi

if [[ -d "$INSTALL_DIR" ]]; then
    log "Removing Agent code at $INSTALL_DIR..."
    rm -rf "$INSTALL_DIR"
fi

if [[ "$PURGE" == true ]]; then
    if [[ -d "$DATA_DIR" ]]; then
        log "Purging $DATA_DIR (settings, downloads, recovery points)..."
        rm -rf "$DATA_DIR"
    fi
else
    log "Leaving $DATA_DIR in place (identity, recovery points). Re-run with --purge to remove it too."
fi

if getent passwd "$SERVICE_USER" >/dev/null; then
    log "Removing service account $SERVICE_USER..."
    userdel "$SERVICE_USER" 2>/dev/null || true
fi
if getent group "$SERVICE_GROUP" >/dev/null; then
    groupdel "$SERVICE_GROUP" 2>/dev/null || true
fi

log "Uninstall complete."
