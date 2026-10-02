#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# apply_sidebar_patch.sh
# Applies the User Limits sidebar patch to app/templates/admin/base_admin.html
# and inserts the format=count fast-path into app/admin/routes.py
#
# Usage:
#   chmod +x apply_sidebar_patch.sh
#   ./apply_sidebar_patch.sh                      # auto-detects project root
#   ./apply_sidebar_patch.sh /path/to/your/app    # explicit project root
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }

# ── Locate project root ───────────────────────────────────────────────────────
PROJECT_ROOT="${1:-}"

if [[ -z "$PROJECT_ROOT" ]]; then
  # Walk up from this script's location looking for app/templates
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  SEARCH="$SCRIPT_DIR"
  while [[ "$SEARCH" != "/" ]]; do
    if [[ -d "$SEARCH/app/templates" ]]; then
      PROJECT_ROOT="$SEARCH"
      break
    fi
    SEARCH="$(dirname "$SEARCH")"
  done
fi

[[ -n "$PROJECT_ROOT" && -d "$PROJECT_ROOT/app/templates" ]] \
  || error "Cannot find project root (app/templates not found). Pass it as the first argument."

info "Project root: $PROJECT_ROOT"

BASE_ADMIN="$PROJECT_ROOT/app/templates/admin/base_admin.html"
ADMIN_ROUTES="$PROJECT_ROOT/app/admin/routes.py"

[[ -f "$BASE_ADMIN" ]]   || error "File not found: $BASE_ADMIN"
[[ -f "$ADMIN_ROUTES" ]] || error "File not found: $ADMIN_ROUTES"

# ── Backup helper ─────────────────────────────────────────────────────────────
backup() {
  local file="$1"
  local bak="${file}.bak_$(date +%Y%m%d_%H%M%S)"
  cp "$file" "$bak"
  info "Backup saved: $bak"
}

# ═══════════════════════════════════════════════════════════════════════════════
# PATCH 1 — base_admin.html : sidebar link
# ═══════════════════════════════════════════════════════════════════════════════
echo
echo -e "${BOLD}── Patch 1 of 3 : sidebar link ──────────────────────────────────────────${RESET}"

SIDEBAR_MARKER='url_for.*admin\.user_limits'

if grep -q "$SIDEBAR_MARKER" "$BASE_ADMIN"; then
  warn "Sidebar link already present — skipping."
else
  # Find the "All Users" anchor line and insert after it.
  # We look for the line containing url_for('admin.users') inside an <a> tag.
  USERS_LINE=$(grep -n "url_for('admin\.users')\|url_for(\"admin\.users\")" "$BASE_ADMIN" \
               | grep -i '<a ' | head -1 | cut -d: -f1)

  if [[ -z "$USERS_LINE" ]]; then
    error "Cannot locate the 'All Users' sidebar link in $BASE_ADMIN.\n       Add the link manually — see base_admin_sidebar_PATCH.md."
  fi

  backup "$BASE_ADMIN"

  # Build the block to insert (sed-safe — no special chars in heredoc)
  LINK_BLOCK='    <a href="{{ url_for('"'"'admin.user_limits'"'"') }}"\n       class="sidebar-link {% if request.endpoint and '"'"'limit'"'"' in request.endpoint %}active{% endif %}">\n      <i class="ti ti-ban"><\/i> User Limits\n      <span id="sb-limit-count"\n            style="margin-left:auto;background:rgba(239,68,68,0.15);color:#f87171;\n                   border-radius:10px;padding:0 6px;font-size:0.65rem;font-weight:700;display:none;"><\/span>\n    <\/a>'

  # Insert after the matched line
  sed -i "${USERS_LINE}a\\${LINK_BLOCK}" "$BASE_ADMIN"
  success "Sidebar link inserted after line $USERS_LINE."
fi

# ═══════════════════════════════════════════════════════════════════════════════
# PATCH 2 — base_admin.html : badge count fetch in <script>
# ═══════════════════════════════════════════════════════════════════════════════
echo
echo -e "${BOLD}── Patch 2 of 3 : badge count fetch ─────────────────────────────────────${RESET}"

FETCH_MARKER="sb-limit-count"

if grep -q "$FETCH_MARKER" "$BASE_ADMIN" && grep -q "fetch.*admin/limits" "$BASE_ADMIN"; then
  warn "Badge fetch already present — skipping."
else
  # Find the closing </script> tag to insert before it.
  # If multiple </script> tags exist we target the last one (bottom of file).
  SCRIPT_CLOSE_LINE=$(grep -n '</script>' "$BASE_ADMIN" | tail -1 | cut -d: -f1)

  if [[ -z "$SCRIPT_CLOSE_LINE" ]]; then
    warn "No </script> tag found in $BASE_ADMIN. Appending fetch snippet at end of file."
    cat >> "$BASE_ADMIN" <<'FETCHBLOCK'

<script>
  fetch('/admin/limits?active=1&format=count', {credentials: 'same-origin'})
    .then(function(r) { return r.ok ? r.json() : null; })
    .then(function(d) {
      var el = document.getElementById('sb-limit-count');
      if (el && d && d.count > 0) {
        el.textContent   = d.count;
        el.style.display = '';
      }
    })
    .catch(function() {});
</script>
FETCHBLOCK
    success "Fetch snippet appended to end of file."
  else
    # [[ backup already done above if patch 1 ran; do it here if patch 1 was skipped ]]
    [[ -f "${BASE_ADMIN}.bak_"* ]] 2>/dev/null || backup "$BASE_ADMIN"

    FETCH_SNIPPET='  fetch('"'"'/admin\/limits?active=1\&format=count'"'"', {credentials: '"'"'same-origin'"'"'})\n    .then(function(r) { return r.ok ? r.json() : null; })\n    .then(function(d) {\n      var el = document.getElementById('"'"'sb-limit-count'"'"');\n      if (el \&\& d \&\& d.count > 0) {\n        el.textContent   = d.count;\n        el.style.display = '"'"''"'"';\n      }\n    })\n    .catch(function() {});'

    sed -i "${SCRIPT_CLOSE_LINE}i\\${FETCH_SNIPPET}" "$BASE_ADMIN"
    success "Badge fetch inserted before </script> at line $SCRIPT_CLOSE_LINE."
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
# PATCH 3 — admin/routes.py : format=count fast-path in user_limits()
# ═══════════════════════════════════════════════════════════════════════════════
echo
echo -e "${BOLD}── Patch 3 of 3 : format=count route guard ──────────────────────────────${RESET}"

COUNT_MARKER="format.*==.*count"

if grep -q "$COUNT_MARKER" "$ADMIN_ROUTES"; then
  warn "format=count guard already present in routes.py — skipping."
else
  # Find the def user_limits(): line
  UL_LINE=$(grep -n "^def user_limits\(\)\|^    def user_limits\(\)" "$ADMIN_ROUTES" | head -1 | cut -d: -f1)

  if [[ -z "$UL_LINE" ]]; then
    warn "Cannot locate user_limits() in $ADMIN_ROUTES."
    warn "Add the following three lines manually at the top of that function:"
    echo
    echo "    if request.args.get('format') == 'count':"
    echo "        count = UserLimit.query.filter_by(is_active=True).count()"
    echo "        return jsonify({'count': count})"
    echo
  else
    backup "$ADMIN_ROUTES"

    # Find the first line of the function body (first non-decorator, non-def line after UL_LINE)
    # We insert the guard after the docstring if present, or right after the def line.
    # Simple approach: insert 3 lines after the def line.
    INSERT_AT=$((UL_LINE + 1))

    GUARD='    if request.args.get('"'"'format'"'"') == '"'"'count'"'"':\n        count = UserLimit.query.filter_by(is_active=True).count()\n        return jsonify({'"'"'count'"'"': count})'

    sed -i "${INSERT_AT}i\\${GUARD}" "$ADMIN_ROUTES"
    success "format=count guard inserted at line $INSERT_AT of routes.py."
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
echo
echo -e "${GREEN}${BOLD}All patches applied successfully.${RESET}"
echo
echo -e "  ${BOLD}Next steps:${RESET}"
echo -e "  1. Verify the changes look correct in your editor."
echo -e "  2. If you haven't already, run the DB migration:"
echo -e "       ${CYAN}flask db migrate -m \"add user_limits and default_limits\"${RESET}"
echo -e "       ${CYAN}flask db upgrade${RESET}"
echo -e "  3. Restart your Flask dev server and check the sidebar."
echo
