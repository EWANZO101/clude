#!/usr/bin/env bash
# Builds a .deb around the onefile Linux binary from build_linux.sh.
# Run from the project root, after packaging/linux/build_linux.sh:
#   bash packaging/linux/build_deb.sh
#
# Uses dpkg-deb, which IS available in this sandbox (unlike the Windows/
# macOS tools) - this one was actually built and inspected below, see
# BUILD_STATUS.txt.
set -euo pipefail
cd "$(dirname "$0")/../.."

VERSION="0.18.0"
STAGING="build/deb-root"

if [ ! -f "dist/teamtreck-agent" ]; then
    echo "dist/teamtreck-agent not found - run packaging/linux/build_linux.sh first." >&2
    exit 1
fi

rm -rf "$STAGING"
mkdir -p "$STAGING/usr/bin"
mkdir -p "$STAGING/usr/share/teamtreck-agent"
mkdir -p "$STAGING/DEBIAN"

cp dist/teamtreck-agent "$STAGING/usr/bin/teamtreck-agent"
chmod 755 "$STAGING/usr/bin/teamtreck-agent"
cp -R browser-extension "$STAGING/usr/share/teamtreck-agent/browser-extension"
cp packaging/linux/teamtreck-agent-autostart.desktop "$STAGING/usr/share/teamtreck-agent/"
cp packaging/linux/debian-template/DEBIAN/control "$STAGING/DEBIAN/control"
cp packaging/linux/debian-template/DEBIAN/postinst "$STAGING/DEBIAN/postinst"
chmod 755 "$STAGING/DEBIAN/postinst"

mkdir -p dist/installer
dpkg-deb --build --root-owner-group "$STAGING" "dist/installer/teamtreck-agent-${VERSION}.deb"

echo ""
echo "Built: dist/installer/teamtreck-agent-${VERSION}.deb"
echo "Install/test with: sudo dpkg -i dist/installer/teamtreck-agent-${VERSION}.deb"
