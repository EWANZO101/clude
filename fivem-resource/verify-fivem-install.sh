#!/usr/bin/env bash
#
# Verifies the FiveM-side install of the Xon Sight Evidence Portal
# integration: the XonSight resource's Config.Evidence, the
# xonsight-livesync bridge resource, server.cfg ensure lines, and that the
# configured site is actually reachable and accepts the configured key.
#
# Run this ON THE FIVEM SERVER VPS (not the website).
#
# Usage:
#   ./verify-fivem-install.sh [path-to-resources-dir]
#
# If no path is given, it searches a few common locations relative to
# wherever you run it from.
#
# Note: this parses Lua config files with plain grep/sed, not a real Lua
# parser - it expects `key = "value"` on its own line, matching the files
# this project ships. It's a best-effort sanity check, not a guarantee.

set -uo pipefail

PASS=0
FAIL=0
WARN=0

pass() { printf '  \033[32m[PASS]\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  \033[31m[FAIL]\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }
warn() { printf '  \033[33m[WARN]\033[0m %s\n' "$1"; WARN=$((WARN + 1)); }
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

WEBHOOK_URL=""
WEBHOOK_KEY=""
SITE_URL=""
SITE_KEY=""
LIVESYNC_DIR=""

RESOURCES_DIR="${1:-}"

if [ -z "$RESOURCES_DIR" ]; then
    for candidate in "./resources" "../resources" "."; do
        if [ -d "$candidate" ] && find "$candidate" -maxdepth 2 -iname "fxmanifest.lua" -path "*[Xx]on[Ss]ight*" 2>/dev/null | grep -q .; then
            RESOURCES_DIR="$candidate"
            break
        fi
    done
fi

if [ -z "$RESOURCES_DIR" ] || [ ! -d "$RESOURCES_DIR" ]; then
    echo "Could not locate a resources/ directory automatically."
    echo "Usage: $0 /path/to/your/fivem/server/resources"
    exit 2
fi

RESOURCES_DIR="$(cd "$RESOURCES_DIR" && pwd)"
echo "Using resources directory: $RESOURCES_DIR"

# ---- XonSight resource ----
section "XonSight resource"

XONSIGHT_DIR="$(find "$RESOURCES_DIR" -maxdepth 3 -type d -iname "xonsight" | head -n1)"

if [ -z "$XONSIGHT_DIR" ]; then
    fail "No 'XonSight' resource folder found under $RESOURCES_DIR"
else
    pass "Found XonSight resource at $XONSIGHT_DIR"

    CONFIG_LUA="$XONSIGHT_DIR/config.lua"
    if [ ! -f "$CONFIG_LUA" ]; then
        fail "config.lua missing at $CONFIG_LUA"
    else
        pass "config.lua exists"

        WEBHOOK_URL="$(grep -o 'webhookUrl *= *"[^"]*"' "$CONFIG_LUA" | head -n1 | sed -E 's/.*"(.*)"/\1/')"
        WEBHOOK_KEY="$(grep -o 'webhookApiKey *= *"[^"]*"' "$CONFIG_LUA" | head -n1 | sed -E 's/.*"(.*)"/\1/')"

        if [ -z "$WEBHOOK_URL" ]; then
            fail "Config.Evidence.webhookUrl is not set - evidence will never reach the site"
        elif [[ "$WEBHOOK_URL" == *YOUR_SITE_HOST* ]]; then
            fail "Config.Evidence.webhookUrl still has the placeholder host: $WEBHOOK_URL"
        else
            pass "webhookUrl = $WEBHOOK_URL"
        fi

        if [ -z "$WEBHOOK_KEY" ]; then
            warn "Config.Evidence.webhookApiKey is empty - webhook will be sent unauthenticated (only OK if the site's XONSIGHT_WEBHOOK_KEY is also blank)"
        elif [ "$WEBHOOK_KEY" = "change-me-too" ]; then
            fail "Config.Evidence.webhookApiKey is still the placeholder 'change-me-too'"
        else
            pass "webhookApiKey is set"
        fi
    fi
fi

# ---- xonsight-livesync resource ----
section "xonsight-livesync resource"

LIVESYNC_DIR="$(find "$RESOURCES_DIR" -maxdepth 3 -type d -iname "xonsight-livesync" | head -n1)"

if [ -z "$LIVESYNC_DIR" ]; then
    warn "No 'xonsight-livesync' resource folder found - the site's Live page won't populate"
else
    pass "Found xonsight-livesync resource at $LIVESYNC_DIR"

    for f in fxmanifest.lua config.lua server.lua; do
        if [ ! -f "$LIVESYNC_DIR/$f" ]; then
            fail "$f missing from xonsight-livesync"
        fi
    done

    LS_CONFIG="$LIVESYNC_DIR/config.lua"
    if [ -f "$LS_CONFIG" ]; then
        SITE_URL="$(grep -o 'Config\.SiteUrl *= *"[^"]*"' "$LS_CONFIG" | head -n1 | sed -E 's/.*"(.*)"/\1/')"
        SITE_KEY="$(grep -o 'Config\.ApiKey *= *"[^"]*"' "$LS_CONFIG" | head -n1 | sed -E 's/.*"(.*)"/\1/')"

        if [ -z "$SITE_URL" ] || [[ "$SITE_URL" == *YOUR_SITE_HOST* ]]; then
            fail "Config.SiteUrl still has the placeholder host: ${SITE_URL:-<empty>}"
        else
            pass "Config.SiteUrl = $SITE_URL"
        fi

        if [ -z "$SITE_KEY" ] || [ "$SITE_KEY" = "change-me-too" ]; then
            fail "Config.ApiKey is still the placeholder 'change-me-too'"
        else
            pass "Config.ApiKey is set"
        fi
    fi
fi

if [ -n "$WEBHOOK_KEY" ] && [ -n "$SITE_KEY" ] && [ "$WEBHOOK_KEY" != "$SITE_KEY" ]; then
    warn "XonSight's webhookApiKey and xonsight-livesync's ApiKey are different values - that's fine only if the site's XONSIGHT_WEBHOOK_KEY actually differs per-endpoint, which it doesn't by default (same key for both)"
fi

# ---- server.cfg ensure lines ----
section "server.cfg"

SERVER_CFG="$(find "$(dirname "$RESOURCES_DIR")" -maxdepth 2 -iname "server.cfg" 2>/dev/null | head -n1)"

if [ -z "$SERVER_CFG" ]; then
    warn "Could not find server.cfg near $RESOURCES_DIR - skipping ensure-line check"
else
    pass "Found server.cfg at $SERVER_CFG"

    if grep -Eq '^\s*ensure\s+XonSight\s*$' "$SERVER_CFG"; then
        pass "server.cfg ensures XonSight"
    else
        fail "server.cfg does not 'ensure XonSight'"
    fi

    if [ -n "$LIVESYNC_DIR" ]; then
        if grep -Eq '^\s*ensure\s+xonsight-livesync\s*$' "$SERVER_CFG"; then
            XS_LINE="$(grep -n -E '^\s*ensure\s+XonSight\s*$' "$SERVER_CFG" | head -n1 | cut -d: -f1)"
            LS_LINE="$(grep -n -E '^\s*ensure\s+xonsight-livesync\s*$' "$SERVER_CFG" | head -n1 | cut -d: -f1)"
            if [ -n "$XS_LINE" ] && [ -n "$LS_LINE" ] && [ "$LS_LINE" -gt "$XS_LINE" ]; then
                pass "server.cfg ensures xonsight-livesync after XonSight"
            else
                warn "xonsight-livesync is ensured before/without XonSight - it should come after"
            fi
        else
            fail "server.cfg does not 'ensure xonsight-livesync'"
        fi
    fi
fi

# ---- Connectivity to the site ----
section "Connectivity to the Evidence Portal site"

if ! command -v curl >/dev/null 2>&1; then
    warn "curl not installed - skipping connectivity checks"
else
    TARGET_URL="${WEBHOOK_URL%/api/xonsight/evidence}"
    [ -z "$TARGET_URL" ] && TARGET_URL="$SITE_URL"

    if [ -z "$TARGET_URL" ]; then
        warn "No site URL found to test against"
    else
        if curl -sf -o /dev/null --max-time 5 "$TARGET_URL/"; then
            pass "Site is reachable at $TARGET_URL"
        else
            fail "Could not reach $TARGET_URL - check firewall/port and that the site is running"
        fi

        if [ -n "$WEBHOOK_URL" ] && [ -n "$WEBHOOK_KEY" ]; then
            CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X POST "$WEBHOOK_URL" \
                -H "Content-Type: application/json" -H "X-XonSight-Key: $WEBHOOK_KEY" -d '{}')"
            case "$CODE" in
                400) pass "Evidence webhook accepts the configured key (400 = reached the site, only failed on the empty test payload)" ;;
                401) fail "Evidence webhook rejected the configured key (401) - key mismatch with the site's XONSIGHT_WEBHOOK_KEY" ;;
                000) fail "Could not reach evidence webhook URL: $WEBHOOK_URL" ;;
                *) warn "Evidence webhook returned unexpected status $CODE" ;;
            esac
        fi

        if [ -n "$SITE_URL" ] && [ -n "$SITE_KEY" ]; then
            CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X POST "$SITE_URL/api/xonsight/recorders/sync" \
                -H "Content-Type: application/json" -H "X-XonSight-Key: $SITE_KEY" -d '{"recorders":[]}')"
            case "$CODE" in
                200) pass "Recorder sync endpoint accepts the configured key" ;;
                401) fail "Recorder sync endpoint rejected the configured key (401) - key mismatch" ;;
                000) fail "Could not reach recorder sync URL: $SITE_URL/api/xonsight/recorders/sync" ;;
                *) warn "Recorder sync endpoint returned unexpected status $CODE" ;;
            esac
        fi
    fi
fi

# ---- Summary ----
section "Summary"
echo "  $PASS passed, $WARN warnings, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
