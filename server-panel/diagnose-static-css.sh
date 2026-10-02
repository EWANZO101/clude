#!/usr/bin/env bash
# OpsLabSystems Server Panel — static CSS diagnostic & fix
#
# Run this ON THE VPS (as root, matching the systemd unit), from anywhere:
#   sudo bash diagnose-static-css.sh
#
# It checks, in order, the things that produce exactly the symptom you're
# seeing (fully unstyled page = the <link rel="stylesheet"> 404'd or was
# never deployed) and offers to fix the most common cause.

set -uo pipefail

APP_DIR="${OPSLAB_APP_DIR:-/opt/opslab-panel}"
SERVICE_NAME="${OPSLAB_SERVICE_NAME:-opslab-panel}"
DOMAIN="${OPSLAB_DOMAIN:-serverpanel.opslabsystems.cloud}"
CSS_REL_PATH="static/css/tailwind.css"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
bad()  { echo -e "  ${RED}✗${NC} $1"; }
info() { echo -e "  ${BLUE}→${NC} $1"; }
warn() { echo -e "  ${YELLOW}!${NC} $1"; }
step() { echo -e "\n${BLUE}== $1 ==${NC}"; }

FOUND_ISSUE=0

step "1. Does the compiled CSS exist on disk at $APP_DIR/$CSS_REL_PATH?"
if [ -f "$APP_DIR/$CSS_REL_PATH" ]; then
  SIZE=$(stat -c%s "$APP_DIR/$CSS_REL_PATH" 2>/dev/null || stat -f%z "$APP_DIR/$CSS_REL_PATH")
  ok "File exists (${SIZE} bytes)"
  if [ "$SIZE" -lt 1000 ]; then
    bad "File is suspiciously small — likely a failed/partial build"
    FOUND_ISSUE=1
  fi
else
  bad "Missing. This is almost certainly the whole problem."
  warn "Build output like tailwind.css is often left out of git deploys"
  warn "(excluded by a *.css gitignore rule, or just never pushed since"
  warn "it's a generated file, not source)."
  FOUND_ISSUE=1
fi

step "2. Is base.html on disk pointing at the right file?"
if [ -f "$APP_DIR/templates/base.html" ]; then
  if grep -q "css/tailwind.css" "$APP_DIR/templates/base.html"; then
    ok "templates/base.html references css/tailwind.css"
  else
    bad "templates/base.html does NOT reference css/tailwind.css — deployed template is stale"
    FOUND_ISSUE=1
  fi
else
  bad "templates/base.html not found under $APP_DIR — is APP_DIR correct?"
  FOUND_ISSUE=1
fi

step "3. Is the app process actually running?"
if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files | grep -q "^${SERVICE_NAME}.service"; then
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    ok "systemd service '$SERVICE_NAME' is active"
    UPTIME=$(systemctl show "$SERVICE_NAME" -p ActiveEnterTimestamp --value)
    info "Running since: $UPTIME"
  else
    bad "systemd service '$SERVICE_NAME' is NOT active"
    systemctl status "$SERVICE_NAME" --no-pager -l | sed 's/^/    /'
    FOUND_ISSUE=1
  fi
else
  warn "No systemd unit named '$SERVICE_NAME' found — checking for a running python process instead"
  if pgrep -f "app.py" >/dev/null 2>&1; then
    ok "A python app.py process is running"
  else
    bad "No app.py process found running anywhere"
    FOUND_ISSUE=1
  fi
fi

step "4. Does the app serve the CSS directly (bypassing nginx)?"
if command -v curl >/dev/null 2>&1; then
  LOCAL_PORT="${OPSLAB_PORT:-8000}"
  LOCAL_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${LOCAL_PORT}/static/css/tailwind.css" 2>/dev/null)
  if [ "$LOCAL_CODE" = "200" ]; then
    ok "http://127.0.0.1:${LOCAL_PORT}/static/css/tailwind.css -> 200"
  else
    bad "http://127.0.0.1:${LOCAL_PORT}/static/css/tailwind.css -> ${LOCAL_CODE:-no response}"
    warn "If this fails but the file exists on disk, the app likely needs a restart"
    warn "(set OPSLAB_PORT env var if the panel doesn't run on 8000)"
    FOUND_ISSUE=1
  fi
else
  warn "curl not installed, skipping local check"
fi

step "5. Does the public domain serve it correctly (through nginx/TLS)?"
if command -v curl >/dev/null 2>&1; then
  PUBLIC_CODE=$(curl -s -o /dev/null -w "%{http_code}" "https://${DOMAIN}/static/css/tailwind.css" 2>/dev/null)
  PUBLIC_TYPE=$(curl -s -o /dev/null -w "%{content_type}" "https://${DOMAIN}/static/css/tailwind.css" 2>/dev/null)
  if [ "$PUBLIC_CODE" = "200" ]; then
    ok "https://${DOMAIN}/static/css/tailwind.css -> 200 ($PUBLIC_TYPE)"
    if [[ "$PUBLIC_TYPE" != text/css* ]]; then
      bad "Content-Type is '$PUBLIC_TYPE', not text/css — nginx may be routing this to Flask's"
      bad "catch-all/404 page instead of the static file (check the nginx location block below)"
      FOUND_ISSUE=1
    fi
  else
    bad "https://${DOMAIN}/static/css/tailwind.css -> ${PUBLIC_CODE:-no response}"
    warn "If step 4 (local) was 200 but this fails, nginx is the problem — see the"
    warn "location block for this site (nginx -T | grep -A5 'location /static')"
    FOUND_ISSUE=1
  fi
else
  warn "curl not installed, skipping public check"
fi

step "6. nginx site config sanity check"
if command -v nginx >/dev/null 2>&1; then
  CONF=$(nginx -T 2>/dev/null | grep -B2 -A10 "server_name.*${DOMAIN}" | head -60)
  if [ -n "$CONF" ]; then
    echo "$CONF" | sed 's/^/    /'
    if ! echo "$CONF" | grep -q "location.*static"; then
      warn "No explicit 'location /static' block found for this site — nginx may be"
      warn "proxying every request (including /static/*) straight to the Flask app,"
      warn "which is fine IF Flask is actually running and serving it (see step 4)."
    fi
  else
    warn "Could not find an nginx server block for $DOMAIN (wrong domain? different config path?)"
  fi
else
  info "nginx not found on this host — skipping (maybe it runs elsewhere / isn't used)"
fi

step "Summary"
if [ "$FOUND_ISSUE" -eq 0 ]; then
  ok "No issues detected by this script. Clear your browser cache / hard-refresh"
  ok "(Ctrl+Shift+R) and check DevTools > Network again."
else
  bad "At least one issue found above."
  echo
  read -p "Attempt the standard fix (rebuild CSS + restart service)? [y/N] " -n 1 -r
  echo
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    step "Rebuilding CSS"
    cd "$APP_DIR" || { bad "Can't cd into $APP_DIR"; exit 1; }
    if [ -f static/css/src/build.sh ]; then
      if ! command -v npx >/dev/null 2>&1; then
        bad "node/npm not installed on this host — install Node.js 18+ first, then re-run"
        exit 1
      fi
      [ -d node_modules ] || npm install
      bash static/css/src/build.sh && ok "CSS rebuilt" || bad "Build failed — check output above"
    else
      bad "static/css/src/build.sh not found — is this the full deployed project?"
    fi

    step "Restarting service"
    if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files | grep -q "^${SERVICE_NAME}.service"; then
      systemctl restart "$SERVICE_NAME" && ok "Restarted $SERVICE_NAME" || bad "Restart failed"
      sleep 2
      systemctl is-active --quiet "$SERVICE_NAME" && ok "Service is active" || bad "Service failed to start — check: journalctl -u $SERVICE_NAME -n 50"
    else
      warn "No systemd unit found — restart the app.py process manually"
    fi

    step "Re-checking"
    curl -s -o /dev/null -w "  Public URL now returns: %{http_code} (%{content_type})\n" "https://${DOMAIN}/static/css/tailwind.css" 2>/dev/null
  else
    info "Skipped. Re-run with the fixes applied manually, or re-run this script after."
  fi
fi
