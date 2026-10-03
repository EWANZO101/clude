#!/usr/bin/env bash
#
# import_users.sh -- log in as an admin and import a local_users JSON
# export via the DB Tools API, with verbose diagnostics at every step
# so a failure tells you WHY instead of just "it didn't work".
#
# Usage:
#   ./import_users.sh <admin-badge-or-username> <path-to-users.json> [base-url]
#
# Example:
#   ./import_users.sh KIOSK01 local_users_combined.json
#   ./import_users.sh KIOSK01 local_users_combined.json http://127.0.0.1:8420

set -uo pipefail

ADMIN_ID="${1:-}"
USERS_FILE="${2:-}"
BASE_URL="${3:-http://127.0.0.1:8420}"

fail() { echo "ERROR: $*" >&2; exit 1; }

[[ -z "$ADMIN_ID" || -z "$USERS_FILE" ]] && fail "Usage: $0 <admin-badge-or-username> <path-to-users.json> [base-url]"
command -v curl  >/dev/null || fail "curl is not installed (try: apt-get install -y curl)"
command -v python3 >/dev/null || fail "python3 is not installed (try: apt-get install -y python3)"
[[ -f "$USERS_FILE" ]] || fail "File not found: $USERS_FILE"

echo "== Step 1/4: checking $BASE_URL is reachable =="
STATUS_HTTP=$(curl -sS -o /tmp/import_users_status.json -w "%{http_code}" "$BASE_URL/api/status" 2>/tmp/import_users_curl_err.txt)
CURL_EXIT=$?
if [[ $CURL_EXIT -ne 0 ]]; then
  echo "curl could not connect to $BASE_URL at all (exit code $CURL_EXIT)."
  cat /tmp/import_users_curl_err.txt >&2
  echo ""
  echo "Likely causes:"
  echo "  - The app isn't running right now."
  echo "  - It's running on a different port than 8420 -- check settings.json's \"port\" value"
  echo "    (usually in the app's data dir, e.g. ./data/settings.json or %LOCALAPPDATA%/StockToolKiosk on Windows)."
  echo "  - It's bound to 127.0.0.1 only (bind_mode=local) and you're running this script from"
  echo "    somewhere other than the VPS itself -- run it ON the VPS, or over SSH on that box."
  exit 1
fi
if [[ "$STATUS_HTTP" != "200" ]]; then
  echo "Got HTTP $STATUS_HTTP from $BASE_URL/api/status (expected 200). Response body:"
  cat /tmp/import_users_status.json >&2
  exit 1
fi
echo "Reachable. /api/status says:"
python3 -m json.tool /tmp/import_users_status.json 2>/dev/null || cat /tmp/import_users_status.json
echo ""

echo "== Step 2/4: logging in as '$ADMIN_ID' =="
LOGIN_HTTP=$(curl -sS -o /tmp/import_users_login.json -w "%{http_code}" -X POST "$BASE_URL/api/auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"badge_code\": \"$ADMIN_ID\"}")
echo "HTTP $LOGIN_HTTP. Response body:"
python3 -m json.tool /tmp/import_users_login.json 2>/dev/null || cat /tmp/import_users_login.json
echo ""

if [[ "$LOGIN_HTTP" != "200" ]]; then
  case "$LOGIN_HTTP" in
    401) echo "-> \"Not recognised\": no local user has badge_code or username '$ADMIN_ID', or that account is inactive." ;;
    403) echo "-> Logins are disabled for that account's role (RolePermission.login_enabled is off). Ask an admin to re-enable it." ;;
    400) echo "-> The request body was rejected -- unexpected, check the response above." ;;
    *)   echo "-> Unexpected status. See response body above." ;;
  esac
  exit 1
fi

TOKEN=$(python3 -c "import json; print(json.load(open('/tmp/import_users_login.json')).get('token',''))" 2>/dev/null)
[[ -z "$TOKEN" ]] && fail "Login returned HTTP 200 but no 'token' field was found -- see response body above."
echo "Logged in OK, got a session token."
echo ""

echo "== Step 3/4: uploading $USERS_FILE to /api/admin/db-tools/import/local_users =="
IMPORT_HTTP=$(curl -sS -o /tmp/import_users_import.json -w "%{http_code}" -X POST "$BASE_URL/api/admin/db-tools/import/local_users" \
  -H "Authorization: Bearer $TOKEN" \
  -F "file=@${USERS_FILE}")
echo "HTTP $IMPORT_HTTP. Response body:"
python3 -m json.tool /tmp/import_users_import.json 2>/dev/null || cat /tmp/import_users_import.json
echo ""

if [[ "$IMPORT_HTTP" != "200" ]]; then
  case "$IMPORT_HTTP" in
    403) echo "-> That account doesn't have the 'admin' role/permission required for /api/admin/db-tools/*." ;;
    400) echo "-> The server rejected the file or table name -- see the \"error\" field above (e.g. bad JSON, wrong table)." ;;
    401) echo "-> Session token was rejected -- it may have expired (12h TTL); re-run this script to log in fresh." ;;
    *)   echo "-> Unexpected status. See response body above." ;;
  esac
  exit 1
fi

echo "== Step 4/4: result =="
INSERTED=$(python3 -c "import json; print(json.load(open('/tmp/import_users_import.json')).get('inserted','?'))" 2>/dev/null)
UPDATED=$(python3 -c "import json; print(json.load(open('/tmp/import_users_import.json')).get('updated','?'))" 2>/dev/null)
ERR_COUNT=$(python3 -c "import json; print(len(json.load(open('/tmp/import_users_import.json')).get('errors',[])))" 2>/dev/null)
echo "Inserted: $INSERTED, Updated: $UPDATED, Row errors: $ERR_COUNT"
if [[ "$ERR_COUNT" != "0" ]]; then
  echo "Per-row errors (these rows were skipped, everything else still imported):"
  python3 -c "import json; [print(' -', e) for e in json.load(open('/tmp/import_users_import.json')).get('errors',[])]"
fi
