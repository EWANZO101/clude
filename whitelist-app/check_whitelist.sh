#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Whitelist Integration — Health Check
# Run from: /root/whitelist-app/
# Usage:    bash check_whitelist.sh
# ─────────────────────────────────────────────────────────────────────────────

PASS=0
FAIL=0
WARN=0

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}✔${NC}  $1"; ((PASS++)); }
fail() { echo -e "  ${RED}✗${NC}  $1"; ((FAIL++)); }
warn() { echo -e "  ${YELLOW}⚠${NC}  $1"; ((WARN++)); }
hdr()  { echo -e "\n${CYAN}${BOLD}── $1 ──${NC}"; }

BASE="${1:-$(pwd)}"
MODELS="$BASE/app/models.py"
API_ROUTES="$BASE/app/api/routes.py"
ADMIN_ROUTES="$BASE/app/admin/routes.py"
SIDEBAR="$BASE/app/templates/admin/base_admin.html"
WL_TEMPLATE="$BASE/app/templates/admin/whitelist.html"
APP_INIT="$BASE/app/__init__.py"
MIGRATIONS="$BASE/migrations"
DB=$(find "$BASE" -name "*.db" -o -name "*.sqlite3" 2>/dev/null | head -1)

echo -e "\n${BOLD}Whitelist Integration Health Check${NC}"
echo -e "Base: $BASE\n"

# ── 1. MODELS ──────────────────────────────────────────────────────────────
hdr "Step 1 — models.py"

if [ -f "$MODELS" ]; then
  ok "models.py exists"

  grep -q "class WhitelistSchedule" "$MODELS" \
    && ok "WhitelistSchedule model defined" \
    || fail "WhitelistSchedule model MISSING — add it to models.py"

  grep -q "whitelist_enabled" "$MODELS" \
    && ok "SiteSettings: whitelist_enabled present" \
    || fail "SiteSettings MISSING 'whitelist_enabled' in DEFAULTS"

  grep -q "whitelist_kick_msg" "$MODELS" \
    && ok "SiteSettings: whitelist_kick_msg present" \
    || fail "SiteSettings MISSING 'whitelist_kick_msg' in DEFAULTS"

  grep -q "whitelist_closed_msg" "$MODELS" \
    && ok "SiteSettings: whitelist_closed_msg present" \
    || fail "SiteSettings MISSING 'whitelist_closed_msg' in DEFAULTS"

  # Check for SQLite-incompatible default='[]'
  if grep -q "default='\[\]'" "$MODELS" 2>/dev/null || grep -q 'default="\[\]"' "$MODELS" 2>/dev/null; then
    warn "Found default='[]' columns — may cause SQLite migration errors. Use server_default='[]' instead"
  else
    ok "No problematic default='[]' column defaults found"
  fi
else
  fail "models.py NOT FOUND at $MODELS"
fi

# ── 2. API ROUTES ──────────────────────────────────────────────────────────
hdr "Step 2 — API routes"

WL_API="$BASE/app/api/whitelist_routes.py"
if [ -f "$WL_API" ]; then
  ok "app/api/whitelist_routes.py exists"
else
  fail "app/api/whitelist_routes.py MISSING"
fi

if [ -f "$API_ROUTES" ]; then
  grep -q "whitelist" "$API_ROUTES" \
    && ok "whitelist imported/included in api/routes.py" \
    || fail "whitelist NOT referenced in api/routes.py — add import"

  grep -q "WhitelistSchedule" "$API_ROUTES" \
    && ok "WhitelistSchedule imported in api/routes.py" \
    || warn "WhitelistSchedule not imported in api/routes.py (may be imported inside whitelist_routes.py — OK if so)"
else
  fail "app/api/routes.py NOT FOUND"
fi

# ── 3. ADMIN ROUTES ────────────────────────────────────────────────────────
hdr "Step 3 — Admin routes"

WL_ADMIN="$BASE/app/admin/whitelist_routes.py"
if [ -f "$WL_ADMIN" ]; then
  ok "app/admin/whitelist_routes.py exists"
else
  fail "app/admin/whitelist_routes.py MISSING"
fi

if [ -f "$ADMIN_ROUTES" ]; then
  grep -q "whitelist" "$ADMIN_ROUTES" \
    && ok "whitelist imported/included in admin/routes.py" \
    || fail "whitelist NOT referenced in admin/routes.py — add import"
else
  fail "app/admin/routes.py NOT FOUND"
fi

# ── 4. TEMPLATE ────────────────────────────────────────────────────────────
hdr "Step 4 — Templates"

if [ -f "$WL_TEMPLATE" ]; then
  ok "templates/admin/whitelist.html exists"
else
  fail "templates/admin/whitelist.html MISSING"
fi

if [ -f "$SIDEBAR" ]; then
  grep -q "monitor\.monitor_page" "$SIDEBAR" \
    && fail "Broken monitor.monitor_page link still in sidebar — run: sed -i '/monitor\\.monitor_page/d' $SIDEBAR" \
    || ok "No broken monitor.monitor_page link in sidebar"

  grep -q "admin.whitelist" "$SIDEBAR" \
    && ok "Whitelist sidebar link present" \
    || fail "Whitelist sidebar link MISSING — add url_for('admin.whitelist') to base_admin.html"
else
  fail "base_admin.html NOT FOUND at $SIDEBAR"
fi

# ── 5. APP __init__.py ─────────────────────────────────────────────────────
hdr "Step 5 — app/__init__.py"

if [ -f "$APP_INIT" ]; then
  ok "app/__init__.py exists"

  grep -q "create_app" "$APP_INIT" \
    && ok "create_app function defined" \
    || fail "create_app NOT found in app/__init__.py"

  grep -q "flask_migrate\|flask_migrate\|Migrate\|migrate" "$APP_INIT" \
    && ok "Flask-Migrate initialised" \
    || warn "Flask-Migrate not detected in app/__init__.py"

  grep -q "models" "$APP_INIT" \
    && ok "models imported in app/__init__.py (Alembic can detect all tables)" \
    || warn "models not explicitly imported in app/__init__.py — Alembic may miss tables in future migrations"

  grep -q "apscheduler\|APScheduler\|_tick" "$APP_INIT" \
    && ok "APScheduler ticker found" \
    || warn "APScheduler ticker NOT set up — schedules won't fire automatically (see Step 7 in install guide)"
else
  fail "app/__init__.py NOT FOUND"
fi

# ── 6. MIGRATIONS / DATABASE ───────────────────────────────────────────────
hdr "Step 6 — Database"

if [ -d "$MIGRATIONS" ]; then
  ok "migrations/ directory exists"
else
  fail "migrations/ directory MISSING — run: flask --app run db init"
fi

if [ -n "$DB" ]; then
  ok "Database file found: $DB"

  if command -v sqlite3 &>/dev/null; then
    TABLES=$(sqlite3 "$DB" ".tables" 2>/dev/null)

    echo "$TABLES" | grep -q "whitelist_schedules" \
      && ok "Table 'whitelist_schedules' exists in DB" \
      || fail "Table 'whitelist_schedules' MISSING — run: flask --app run db upgrade"

    echo "$TABLES" | grep -q "site_settings" \
      && ok "Table 'site_settings' exists in DB" \
      || fail "Table 'site_settings' MISSING"

    echo "$TABLES" | grep -q "economy_flags" \
      && ok "Table 'economy_flags' exists in DB" \
      || fail "Table 'economy_flags' MISSING"

    # Check dedup_key column
    EFLAG_COLS=$(sqlite3 "$DB" "PRAGMA table_info(economy_flags);" 2>/dev/null)
    echo "$EFLAG_COLS" | grep -q "dedup_key" \
      && ok "Column 'economy_flags.dedup_key' exists" \
      || fail "Column 'economy_flags.dedup_key' MISSING — run: flask --app run db upgrade"

    # Check whitelist settings seeded
    WL_SETTING=$(sqlite3 "$DB" "SELECT value FROM site_settings WHERE key='whitelist_enabled' LIMIT 1;" 2>/dev/null)
    if [ -n "$WL_SETTING" ]; then
      ok "SiteSettings 'whitelist_enabled' seeded (value: $WL_SETTING)"
    else
      warn "SiteSettings 'whitelist_enabled' not yet seeded — will be created on first app start if DEFAULTS are applied"
    fi
  else
    warn "sqlite3 CLI not available — skipping table checks"
  fi
else
  warn "No .db/.sqlite3 file found — if using PostgreSQL/MySQL, table checks skipped"
fi

# ── 7. PYTHON IMPORTS ──────────────────────────────────────────────────────
hdr "Step 7 — Python environment"

PYTHON="$BASE/venv/bin/python"
[ -f "$PYTHON" ] || PYTHON=$(which python3)

$PYTHON -c "from app.models import WhitelistSchedule; print('ok')" 2>/dev/null \
  && ok "WhitelistSchedule importable from app.models" \
  || fail "Cannot import WhitelistSchedule — check models.py and app/__init__.py"

$PYTHON -c "import flask_migrate" 2>/dev/null \
  && ok "flask_migrate installed" \
  || fail "flask_migrate NOT installed — run: pip install flask-migrate"

$PYTHON -c "import apscheduler" 2>/dev/null \
  && ok "apscheduler installed" \
  || warn "apscheduler NOT installed — needed for auto-tick (run: pip install apscheduler)"

# ── SUMMARY ────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}────────────────────────────────────${NC}"
echo -e "  ${GREEN}✔ Passed:${NC}  $PASS"
[ $WARN -gt 0 ] && echo -e "  ${YELLOW}⚠ Warnings:${NC} $WARN"
[ $FAIL -gt 0 ] && echo -e "  ${RED}✗ Failed:${NC}  $FAIL"
echo -e "${BOLD}────────────────────────────────────${NC}\n"

[ $FAIL -eq 0 ] && echo -e "${GREEN}${BOLD}All checks passed!${NC}\n" \
                || echo -e "${RED}${BOLD}Fix the failed checks above, then re-run.${NC}\n"

exit $FAIL
