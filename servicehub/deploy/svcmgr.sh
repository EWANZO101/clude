#!/bin/bash
# svcmgr.sh - privileged helper for ServiceHub
# Only ever touches units named opslab-*.service to prevent this from
# becoming a general-purpose "run anything as root" hole.
#
# Usage:
#   svcmgr.sh write   <unit-name> <path-to-tmp-unit-file>
#   svcmgr.sh start   <unit-name>
#   svcmgr.sh stop    <unit-name>
#   svcmgr.sh restart <unit-name>
#   svcmgr.sh enable  <unit-name>
#   svcmgr.sh disable <unit-name>
#   svcmgr.sh remove  <unit-name>
#   svcmgr.sh status  <unit-name>
#   svcmgr.sh logs    <unit-name> <lines>

set -euo pipefail

ACTION="${1:-}"
UNIT="${2:-}"
UNIT_DIR="/etc/systemd/system"

# Read-only, host-wide introspection actions are allowed for ANY unit -
# they can't change state, so they sit outside the opslab-* allowlist.
case "$ACTION" in
  list)
    # All service units on the host, active or not.
    systemctl list-units --type=service --all --no-legend --no-pager --plain
    exit 0
    ;;
  show)
    if [[ -z "$UNIT" ]]; then
      echo "refused: no unit given" >&2
      exit 1
    fi
    systemctl show "$UNIT" --no-pager \
      --property=Description,ExecStart,WorkingDirectory,FragmentPath,ActiveState,UnitFileState
    exit 0
    ;;
esac

# Every remaining action mutates state, so it's locked to units ServiceHub
# itself created: unit name must look like opslab-<slug>.service
if [[ ! "$UNIT" =~ ^opslab-[a-z0-9-]+\.service$ ]]; then
  echo "refused: unit name '$UNIT' does not match opslab-*.service" >&2
  exit 1
fi

UNIT_PATH="$UNIT_DIR/$UNIT"

case "$ACTION" in
  write)
    SRC="${3:-}"
    if [[ -z "$SRC" || ! -f "$SRC" ]]; then
      echo "refused: no source file given" >&2
      exit 1
    fi
    install -m 0644 "$SRC" "$UNIT_PATH"
    systemctl daemon-reload
    ;;
  start)
    systemctl start "$UNIT"
    ;;
  stop)
    systemctl stop "$UNIT"
    ;;
  restart)
    systemctl restart "$UNIT"
    ;;
  enable)
    systemctl enable "$UNIT"
    ;;
  disable)
    systemctl disable "$UNIT"
    ;;
  remove)
    systemctl stop "$UNIT" 2>/dev/null || true
    systemctl disable "$UNIT" 2>/dev/null || true
    rm -f "$UNIT_PATH"
    systemctl daemon-reload
    ;;
  status)
    # Never fail the script just because the unit is inactive/failed
    ACTIVE=$(systemctl is-active "$UNIT" 2>/dev/null || true)
    ENABLED=$(systemctl is-enabled "$UNIT" 2>/dev/null || true)
    echo "active=$ACTIVE"
    echo "enabled=$ENABLED"
    ;;
  logs)
    LINES="${3:-100}"
    journalctl -u "$UNIT" -n "$LINES" --no-pager --output=short-iso
    ;;
  *)
    echo "unknown action: $ACTION" >&2
    exit 1
    ;;
esac
