#!/usr/bin/env bash
set -euo pipefail

# Deploys this xonsight-livesync build into a FiveM server's resources/
# directory. Does NOT restart the resource - do that yourself (`refresh` +
# `restart xonsight-livesync` in the server console, or a full restart).
#
# Usage:
#   ./update.sh /path/to/fxserver/resources

RESOURCE_NAME="xonsight-livesync"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ $# -lt 1 ]; then
  echo "Usage: $0 /path/to/fxserver/resources" >&2
  exit 1
fi

RESOURCES_DIR="$1"
DEST="$RESOURCES_DIR/$RESOURCE_NAME"

if [ ! -d "$RESOURCES_DIR" ]; then
  echo "error: $RESOURCES_DIR does not exist" >&2
  exit 1
fi

# config.lua holds this server's SiteUrl/ApiKey - never overwrite it with the
# repo's template. Stash it, restore it after copying the rest.
KEPT_CONFIG=""
if [ -f "$DEST/config.lua" ]; then
  KEPT_CONFIG="$(mktemp)"
  cp "$DEST/config.lua" "$KEPT_CONFIG"
fi

# Back up whatever's already deployed before overwriting it, so a bad update
# can be rolled back by hand.
if [ -d "$DEST" ] && [ -n "$(ls -A "$DEST" 2>/dev/null)" ]; then
  BACKUP="${DEST}.bak.$(date +%Y%m%d%H%M%S)"
  cp -r "$DEST" "$BACKUP"
  echo "Backed up existing resource to $BACKUP"
fi

mkdir -p "$DEST"
cp -r "$SCRIPT_DIR"/. "$DEST"/
rm -f "$DEST/update.sh" "$DEST"/*.bak.*/update.sh 2>/dev/null || true

if [ -n "$KEPT_CONFIG" ]; then
  cp "$KEPT_CONFIG" "$DEST/config.lua"
  rm -f "$KEPT_CONFIG"
  echo "Kept existing config.lua (SiteUrl/ApiKey untouched)"
else
  echo "No existing config.lua found - copied the template. Edit $DEST/config.lua before starting the resource."
fi

echo "Deployed $RESOURCE_NAME to $DEST"
echo "Now restart it: refresh; restart $RESOURCE_NAME"
