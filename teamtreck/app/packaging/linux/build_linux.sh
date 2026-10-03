#!/usr/bin/env bash
# Build the Linux onefile binary. Run from the project root:
#   bash packaging/linux/build_linux.sh
# Output: dist/teamtreck-agent
#
# NOTE ON DISTRIBUTION: build on the OLDEST glibc you intend to support
# (PyInstaller binaries aren't forward-compatible across glibc versions -
# a binary built on a newer distro won't run on an older one). This
# sandbox's build was verified to run (see BUILD_STATUS.txt) but was
# built on whatever glibc happened to be here - re-build on your actual
# target (e.g. Ubuntu 20.04 or a manylinux container) before shipping.
set -euo pipefail
cd "$(dirname "$0")/../.."

python3 -m venv .build-venv 2>/dev/null || true
source .build-venv/bin/activate
pip install -q -r requirements.txt
pip install -q pyinstaller

rm -rf build dist
pyinstaller packaging/pyinstaller/teamtreck-agent.spec --distpath dist --workpath build --noconfirm

echo ""
echo "Built: dist/teamtreck-agent"
echo "Test it with: ./dist/teamtreck-agent --version"
