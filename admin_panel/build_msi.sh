#!/usr/bin/env bash
# Builds kiosk-agent-<version>.msi from the current agent/ source, using
# generate_wxs.py + wixl (msitools' Linux-native WiX-compatible builder -
# no Wine/Mono/Windows needed to build, only to actually run the result).
#
# Usage:
#   ./build_msi.sh <version> [--deploy-to <admin_panel-repo-path>]
#
# Example:
#   ./build_msi.sh 0.2.0
#   ./build_msi.sh 0.2.0 --deploy-to /root/admin_panel
#
# Run from the msi_build/ directory (the one containing generate_wxs.py
# and files/).

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <version> [--deploy-to <admin_panel-repo-path>]"
    exit 1
fi

VERSION="$1"
shift
DEPLOY_TO=""

while [ $# -gt 0 ]; do
    case "$1" in
        --deploy-to)
            DEPLOY_TO="$2"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1"
            exit 1
            ;;
    esac
done

if [ ! -f "generate_wxs.py" ]; then
    echo "Error: generate_wxs.py not found in current directory."
    echo "Run this from the msi_build/ directory."
    exit 1
fi

if ! command -v wixl >/dev/null 2>&1; then
    echo "Error: wixl not found. Install with:"
    echo "  sudo apt-get update && sudo apt-get install -y wixl wixl-data msitools"
    exit 1
fi

echo "==> [1/5] Setting VERSION=$VERSION in generate_wxs.py..."
if ! grep -q '^VERSION = ' generate_wxs.py; then
    echo "Error: could not find 'VERSION = ' line in generate_wxs.py to update."
    exit 1
fi
sed -i "s/^VERSION = .*/VERSION = \"$VERSION\"/" generate_wxs.py
grep -n '^VERSION = ' generate_wxs.py

echo "==> [2/5] Re-staging agent source into files/..."
if [ -d "../agent_src/instance_agent/agent" ]; then
    AGENT_SRC="../agent_src/instance_agent"
elif [ -d "agent_src/instance_agent/agent" ]; then
    AGENT_SRC="agent_src/instance_agent"
else
    echo "Warning: could not auto-locate agent_src/instance_agent relative to here."
    echo "Skipping re-stage - using whatever is already in files/agent, files/service."
    AGENT_SRC=""
fi
if [ -n "$AGENT_SRC" ]; then
    mkdir -p files/agent files/service
    cp "$AGENT_SRC/agent/"*.py files/agent/
    cp "$AGENT_SRC/requirements.txt" files/requirements.txt
    cp "$AGENT_SRC/service_files/windows/opslab_agent_service.py" files/service/
    echo "    Staged from $AGENT_SRC"
fi

echo "==> [3/5] Generating product.wxs..."
python3 generate_wxs.py > product.wxs
xmllint --noout product.wxs
echo "    OK"

echo "==> [4/5] Building MSI with wixl..."
OUT="kiosk-agent-$VERSION.msi"
rm -f "$OUT"
wixl -v product.wxs -o "$OUT"
if [ ! -f "$OUT" ]; then
    echo "Error: wixl did not produce $OUT - see output above."
    exit 1
fi
echo "    Built: $OUT ($(du -h "$OUT" | cut -f1))"

echo "==> [5/5] Self-validating the built MSI..."
FILE_COUNT=$(msiinfo export "$OUT" File 2>/dev/null | tail -n +4 | grep -c .)
COMPONENT_COUNT=$(msiinfo export "$OUT" Component 2>/dev/null | tail -n +4 | grep -c .)
CA_COUNT=$(msiinfo export "$OUT" CustomAction 2>/dev/null | tail -n +4 | grep -c .)
echo "    Files: $FILE_COUNT   Components: $COMPONENT_COUNT   CustomActions: $CA_COUNT"
if [ "$FILE_COUNT" -lt 15 ]; then
    echo "    WARNING: file count looks low - check the agent/ source staged correctly."
fi
if [ "$CA_COUNT" -ne 3 ]; then
    echo "    WARNING: expected 3 custom actions (SetRunPostInstall, RunPostInstall, RunUninstallService), found $CA_COUNT."
fi

# Round-trip check: every staged file should extract back out byte-identical.
TMPDIR="$(mktemp -d)"
msiextract -C "$TMPDIR" "$OUT" >/dev/null 2>&1
MISMATCH=0
while IFS= read -r -d '' f; do
    rel="${f#files/}"
    extracted="$TMPDIR/Program Files/OpsLabAgent/$rel"
    if [ ! -f "$extracted" ] || ! cmp -s "$f" "$extracted"; then
        echo "    MISMATCH: $rel did not round-trip correctly!"
        MISMATCH=1
    fi
done < <(find files -type f -print0)
rm -rf "$TMPDIR"
if [ "$MISMATCH" -eq 0 ]; then
    echo "    All staged files round-trip byte-identical through the built MSI."
else
    echo "    FAILED round-trip check - do not ship this build."
    exit 1
fi

if [ -n "$DEPLOY_TO" ]; then
    DEST="$DEPLOY_TO/app/static/installers"
    if [ ! -d "$DEST" ]; then
        echo "Error: $DEST does not exist - is $DEPLOY_TO really the admin_panel repo root?"
        exit 1
    fi
    echo "==> Deploying to $DEST/$OUT ..."
    cp "$OUT" "$DEST/$OUT"
    echo "    Done. Update your download link/docs to reference $OUT."
fi

echo ""
echo "Done. Test with:"
echo "  msiexec /i $OUT TOKEN=\"<token>\" ADMINURL=\"https://<admin-url>\" /l*v install.log"
