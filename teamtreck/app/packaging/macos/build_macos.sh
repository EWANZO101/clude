#!/usr/bin/env bash
# Build the macOS onefile binary. Run from the project root:
#   bash packaging/macos/build_macos.sh
# Output: dist/teamtreck-agent
#
# NOT RUN OR VERIFIED IN THIS SANDBOX - there's no macOS machine here.
# The .spec file was validated with a real Linux build (see
# BUILD_STATUS.txt); pyobjc and the codesign/notarize step below still
# need a first real run on macOS.
#
# CODE SIGNING & NOTARIZATION (required for the binary to run without
# Gatekeeper warnings on other people's Macs):
#   1. You need an Apple Developer ID ($99/yr) - can't be done from here.
#   2. codesign --deep --force --options runtime \
#        --sign "Developer ID Application: Your Name (TEAMID)" dist/teamtreck-agent
#   3. Zip it and submit for notarization:
#        xcrun notarytool submit teamtreck-agent.zip --keychain-profile "AC_PROFILE" --wait
#      (keychain-profile is set up once via `xcrun notarytool store-credentials`)
#   4. xcrun stapler staple dist/teamtreck-agent
# Skipping this means Gatekeeper will block the binary on first launch
# unless the user right-click -> Open's it and confirms.
set -euo pipefail
cd "$(dirname "$0")/../.."

python3 -m venv .build-venv 2>/dev/null || true
source .build-venv/bin/activate
pip install -q -r requirements.txt
pip install -q pyobjc pyinstaller

rm -rf build dist
pyinstaller packaging/pyinstaller/teamtreck-agent.spec --distpath dist --workpath build --noconfirm

echo ""
echo "Built: dist/teamtreck-agent (UNSIGNED - see the signing/notarization notes at the top of this script)"
