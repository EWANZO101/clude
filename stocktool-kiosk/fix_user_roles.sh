#!/usr/bin/env bash
#
# fix_user_roles.sh -- normalizes any LocalUser whose role is the
# mistyped "Stock user" (capital S, space) to the app's actual valid
# role string "stock_user", via the proper admin API
# (PATCH /api/admin/users/<id>) rather than touching the DB directly --
# this way every update still goes through the app's own validation
# (_VALID_ROLES, last-admin protection, etc).
#
# Usage:
#   ./fix_user_roles.sh <admin-badge-or-username> [base-url]
#
# Example:
#   ./fix_user_roles.sh KIOSK01
#   ./fix_user_roles.sh KIOSK01 http://127.0.0.1:8420

set -uo pipefail

ADMIN_ID="${1:-}"
BASE_URL="${2:-http://127.0.0.1:8420}"
BAD_ROLE="Stock user"
GOOD_ROLE="stock_user"

fail() { echo "ERROR: $*" >&2; exit 1; }

[[ -z "$ADMIN_ID" ]] && fail "Usage: $0 <admin-badge-or-username> [base-url]"
command -v curl    >/dev/null || fail "curl is not installed"
command -v python3 >/dev/null || fail "python3 is not installed"

echo "== Logging in as '$ADMIN_ID' =="
LOGIN_HTTP=$(curl -sS -o /tmp/fix_roles_login.json -w "%{http_code}" -X POST "$BASE_URL/api/auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"badge_code\": \"$ADMIN_ID\"}")
if [[ "$LOGIN_HTTP" != "200" ]]; then
  echo "Login failed (HTTP $LOGIN_HTTP):"
  cat /tmp/fix_roles_login.json
  exit 1
fi
TOKEN=$(python3 -c "import json; print(json.load(open('/tmp/fix_roles_login.json'))['token'])")
echo "Logged in."

echo "== Fetching all users =="
LIST_HTTP=$(curl -sS -o /tmp/fix_roles_users.json -w "%{http_code}" "$BASE_URL/api/admin/users" \
  -H "Authorization: Bearer $TOKEN")
if [[ "$LIST_HTTP" != "200" ]]; then
  echo "Couldn't fetch users (HTTP $LIST_HTTP):"
  cat /tmp/fix_roles_users.json
  exit 1
fi

# Collect the ids of every user whose role is exactly "Stock user"
IDS=$(python3 -c "
import json
users = json.load(open('/tmp/fix_roles_users.json'))
for u in users:
    if u.get('role') == '$BAD_ROLE':
        print(u['id'])
")

if [[ -z "$IDS" ]]; then
  echo "No users with role '$BAD_ROLE' found -- nothing to fix."
  exit 0
fi

COUNT=$(echo "$IDS" | wc -l)
echo "Found $COUNT user(s) with role '$BAD_ROLE'. Updating to '$GOOD_ROLE'..."

FIXED=0
FAILED=0
for id in $IDS; do
  RESP_HTTP=$(curl -sS -o /tmp/fix_roles_patch.json -w "%{http_code}" -X PATCH "$BASE_URL/api/admin/users/$id" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"role\": \"$GOOD_ROLE\"}")
  if [[ "$RESP_HTTP" == "200" ]]; then
    UNAME=$(python3 -c "import json; print(json.load(open('/tmp/fix_roles_patch.json')).get('username','?'))")
    echo "  OK  id=$id ($UNAME) -> $GOOD_ROLE"
    FIXED=$((FIXED+1))
  else
    echo "  FAIL id=$id (HTTP $RESP_HTTP): $(cat /tmp/fix_roles_patch.json)"
    FAILED=$((FAILED+1))
  fi
done

echo ""
echo "Done. Fixed: $FIXED, Failed: $FAILED"
