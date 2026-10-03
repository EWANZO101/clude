#!/usr/bin/env bash
# Builds a macOS .pkg installer around the onefile binary from build_macos.sh.
# NOT RUN/VERIFIED IN THIS SANDBOX - pkgbuild/productbuild are macOS-only
# tools. Written against their documented syntax but needs a first real
# run on macOS.
#
# Run from the project root, after packaging/macos/build_macos.sh:
#   bash packaging/macos/build_pkg.sh
#
# This does NOT sign or notarize the .pkg - see the signing notes in
# build_macos.sh. An unsigned/unnotarized .pkg will be blocked by
# Gatekeeper on other people's Macs (right-click -> Open works around it,
# but that's not something to ship to non-technical users as the plan).
set -euo pipefail
cd "$(dirname "$0")/../.."

APP_NAME="TeamTreck Agent"
VERSION="0.18.0"
IDENTIFIER="com.teamtreck.agent"
STAGING="build/macos-pkg-root"

if [ ! -f "dist/teamtreck-agent" ]; then
    echo "dist/teamtreck-agent not found - run packaging/macos/build_macos.sh first." >&2
    exit 1
fi

rm -rf "$STAGING"
mkdir -p "$STAGING/usr/local/bin"
mkdir -p "$STAGING/Library/Application Support/TeamTreck Agent/browser-extension"

cp dist/teamtreck-agent "$STAGING/usr/local/bin/teamtreck-agent"
chmod 755 "$STAGING/usr/local/bin/teamtreck-agent"
cp -R browser-extension/* "$STAGING/Library/Application Support/TeamTreck Agent/browser-extension/"

pkgbuild \
    --root "$STAGING" \
    --identifier "$IDENTIFIER" \
    --version "$VERSION" \
    --scripts "packaging/macos/scripts" \
    "dist/teamtreck-agent-${VERSION}.pkg"

echo ""
echo "Built: dist/teamtreck-agent-${VERSION}.pkg (UNSIGNED)"
echo "See the notarization notes in packaging/macos/build_macos.sh before distributing."
