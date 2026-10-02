#!/usr/bin/env bash
# Deploys the Windows-installer BOM/reinstall-nesting fix onto an Admin
# Panel server.
#
# Usage:
#   ./deploy_windows_install_fix.sh <path-to-admin_panel-repo> [--restart <systemd-service-name>]
#
# Example:
#   ./deploy_windows_install_fix.sh /opt/admin_panel --restart admin-panel
#
# Run this from the same directory as opslab_windows_install_fix.zip
# (or pass --fix-dir to point at an already-extracted server_fix/ folder).

set -euo pipefail

FIX_ZIP="opslab_windows_install_fix.zip"
FIX_DIR=""
ADMIN_PANEL_DIR=""
RESTART_SERVICE=""

usage() {
    echo "Usage: $0 <path-to-admin_panel-repo> [--restart <systemd-service-name>] [--fix-dir <extracted-server_fix-dir>]"
    exit 1
}

if [ $# -lt 1 ]; then
    usage
fi

ADMIN_PANEL_DIR="$1"
shift

while [ $# -gt 0 ]; do
    case "$1" in
        --restart)
            RESTART_SERVICE="$2"
            shift 2
            ;;
        --fix-dir)
            FIX_DIR="$2"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1"
            usage
            ;;
    esac
done

if [ ! -d "$ADMIN_PANEL_DIR" ]; then
    echo "Error: admin_panel directory not found: $ADMIN_PANEL_DIR"
    exit 1
fi

if [ -z "$FIX_DIR" ]; then
    if [ ! -f "$FIX_ZIP" ]; then
        echo "Error: $FIX_ZIP not found in current directory."
        echo "Either place it here, or pass --fix-dir <extracted-server_fix-dir>."
        exit 1
    fi
    TMP_EXTRACT="$(mktemp -d)"
    unzip -q "$FIX_ZIP" -d "$TMP_EXTRACT"
    FIX_DIR="$TMP_EXTRACT/server_fix"
    trap 'rm -rf "$TMP_EXTRACT"' EXIT
fi

INSTALLERS_DIR="$ADMIN_PANEL_DIR/app/static/installers"
TARGET_PS1="$INSTALLERS_DIR/install.ps1"
TARGET_TAR="$INSTALLERS_DIR/opslab-agent.tar.gz"
SRC_PS1="$FIX_DIR/app/static/installers/install.ps1"
SRC_TAR="$FIX_DIR/app/static/installers/opslab-agent.tar.gz"
SRC_CONFIG="$FIX_DIR/instance_agent_repo/config.py"

for f in "$SRC_PS1" "$SRC_TAR"; do
    if [ ! -f "$f" ]; then
        echo "Error: expected fix file not found: $f"
        exit 1
    fi
done

if [ ! -d "$INSTALLERS_DIR" ]; then
    echo "Error: $INSTALLERS_DIR does not exist - is $ADMIN_PANEL_DIR really the admin_panel repo root?"
    exit 1
fi

echo "==> Backing up current installers..."
BACKUP_DIR="$INSTALLERS_DIR/backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
[ -f "$TARGET_PS1" ] && cp "$TARGET_PS1" "$BACKUP_DIR/"
[ -f "$TARGET_TAR" ] && cp "$TARGET_TAR" "$BACKUP_DIR/"
echo "    Backed up to $BACKUP_DIR"

echo "==> Deploying fixed install.ps1..."
cp "$SRC_PS1" "$TARGET_PS1"

echo "==> Deploying fixed opslab-agent.tar.gz..."
cp "$SRC_TAR" "$TARGET_TAR"

if [ -f "$SRC_CONFIG" ]; then
    AGENT_CONFIG="$ADMIN_PANEL_DIR/agent/config.py"
    if [ -f "$AGENT_CONFIG" ]; then
        echo "==> Also patching $AGENT_CONFIG (source served on-disk by the app)..."
        cp "$AGENT_CONFIG" "$BACKUP_DIR/config.py.orig" 2>/dev/null || true
        cp "$SRC_CONFIG" "$AGENT_CONFIG"
    fi
fi

echo "==> Verifying deployed install.ps1 no longer has the BOM-writing line..."
if grep -q 'Set-Content -Path "\$DataDir\\settings.json" -Encoding UTF8' "$TARGET_PS1"; then
    echo "    WARNING: old Set-Content line still present - deploy may not have applied correctly."
else
    echo "    OK - settings.json is now written via UTF8Encoding(\$false) (no BOM)."
fi

echo "==> Verifying deployed tarball's config.py is patched..."
TMP_CHECK="$(mktemp -d)"
tar -xzf "$TARGET_TAR" -C "$TMP_CHECK" agent/config.py
if grep -q 'utf-8-sig' "$TMP_CHECK/agent/config.py"; then
    echo "    OK - opslab-agent.tar.gz contains the patched config.py."
else
    echo "    WARNING: tarball's config.py does not look patched."
fi
rm -rf "$TMP_CHECK"

if [ -n "$RESTART_SERVICE" ]; then
    echo "==> Restarting $RESTART_SERVICE..."
    if command -v systemctl >/dev/null 2>&1; then
        sudo systemctl restart "$RESTART_SERVICE"
        sudo systemctl status "$RESTART_SERVICE" --no-pager -l | head -10
    else
        echo "    systemctl not found - restart $RESTART_SERVICE manually."
    fi
else
    echo "==> No --restart service given. Static files are usually served without"
    echo "    needing an app restart (Flask reads them from disk per request),"
    echo "    but restart your app if it caches static files in memory or"
    echo "    sits behind a caching reverse proxy/CDN."
fi

echo ""
echo "Done. Test with a fresh install on a Windows machine:"
echo "  irm https://<your-admin-url>/install.ps1 -OutFile install.ps1"
echo "  .\\install.ps1 -Token <token> -AdminUrl https://<your-admin-url>"
echo "Expect: '    Registered successfully.' instead of the BOM-crash warning."
