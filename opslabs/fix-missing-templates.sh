#!/usr/bin/env bash
# Find every render_template() target across the whole Flask app and
# scaffold a safe placeholder for any that don't exist on disk, so
# missing templates turn into a graceful page instead of a 500.
#
# IMPORTANT: placeholders are NOT real forms/functionality. Anything
# flagged "NEEDS REAL CONTENT" below still needs a proper template —
# this script only stops the crashing.
#
# Usage:
#   APP_ROOT=/root/opslabs ./fix-missing-templates.sh          # scaffold missing ones
#   APP_ROOT=/root/opslabs DRY_RUN=1 ./fix-missing-templates.sh # report only, no writes

set -euo pipefail

APP_ROOT="${APP_ROOT:-/root/opslabs}"
DRY_RUN="${DRY_RUN:-0}"
STAMP="$(date +%Y%m%d-%H%M%S)"
REPORT="$APP_ROOT/_backups/missing-templates-$STAMP.txt"

log()  { echo "[fix] $*"; }
fail() { echo "[fix] ERROR: $*" >&2; exit 1; }

[ -d "$APP_ROOT/app" ] || fail "APP_ROOT/app not found: $APP_ROOT/app"
TPL_DIR="$APP_ROOT/app/templates"
[ -d "$TPL_DIR" ] || fail "templates dir not found: $TPL_DIR"

mkdir -p "$APP_ROOT/_backups"

# ---------- 1. Collect every render_template() target ----------
log "Scanning $APP_ROOT/app for render_template() calls..."
mapfile -t WANTED < <(
  grep -rhoE "render_template\(\s*[\"'][^\"']+[\"']" "$APP_ROOT/app" --include="*.py" \
    | sed -E "s/render_template\(\s*[\"']//; s/[\"']$//" \
    | sort -u
)
log "Found ${#WANTED[@]} distinct template references."

# ---------- 2. Split into present / missing ----------
MISSING=()
for t in "${WANTED[@]}"; do
  [ -f "$TPL_DIR/$t" ] || MISSING+=("$t")
done

log "Missing: ${#MISSING[@]} of ${#WANTED[@]}"
{
  echo "Template audit — $STAMP"
  echo "APP_ROOT=$APP_ROOT"
  echo
  echo "MISSING (${#MISSING[@]}):"
  for t in "${MISSING[@]}"; do echo "  - $t"; done
} > "$REPORT"
log "Report written to $REPORT"

if [ "${#MISSING[@]}" -eq 0 ]; then
  log "Nothing missing. Done."
  exit 0
fi

if [ "$DRY_RUN" = "1" ]; then
  log "DRY_RUN=1 — not writing any files. Missing templates listed above / in report."
  printf '  - %s\n' "${MISSING[@]}"
  exit 0
fi

# ---------- 3. Scaffold a safe placeholder for each missing one ----------
# Patterns that almost certainly need real functional content, not a
# placeholder (forms, auth, editing flows) — flagged loudly, not faked.
FUNCTIONAL_PATTERN='login|register|signup|sign-up|logout|reset|password|new|edit|create|form|checkout|payment|invoice'

FLAGGED=()

for t in "${MISSING[@]}"; do
  dest="$TPL_DIR/$t"
  mkdir -p "$(dirname "$dest")"

  title="$(basename "$t" .html)"
  title="${title//-/ }"
  title="${title//_/ }"
  title="$(echo "$title" | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2); print}')"

  is_functional=0
  if echo "$t" | grep -qiE "$FUNCTIONAL_PATTERN"; then
    is_functional=1
    FLAGGED+=("$t")
  fi

  {
    echo "{% extends \"base.html\" %}"
    echo "{% block title %}$title · OpsLab Systems{% endblock %}"
    echo "{% block content %}"
    echo "<div class=\"max-w-2xl mx-auto px-4 sm:px-6 lg:px-8 py-24 text-center\">"
    if [ "$is_functional" -eq 1 ]; then
      echo "  <!-- AUTO-GENERATED PLACEHOLDER — this route ($t) looks functional"
      echo "       (form/auth/edit flow) and needs a real template, not this stub."
      echo "       Replace with the actual page before relying on it. -->"
      echo "  <div class=\"inline-flex items-center gap-2 px-3 py-1 rounded-full text-xs font-bold uppercase tracking-widest bg-yellow-500/10 text-yellow-300 border border-yellow-500/30 mb-6\">Temporarily unavailable</div>"
      echo "  <h1 class=\"text-2xl font-extrabold tracking-tight mb-3\">$title</h1>"
      echo "  <p class=\"text-gray-400 leading-relaxed\">This page is being worked on right now. Please check back shortly, or open a ticket if you need this urgently.</p>"
      echo "  <a href=\"{{ url_for('main.index') }}\" class=\"inline-flex mt-8 px-5 py-2.5 text-sm font-semibold text-white bg-gradient-to-r from-ops-500 to-ops-700 rounded-xl\">Back to home</a>"
    else
      echo "  <h1 class=\"text-2xl font-extrabold tracking-tight mb-3\">$title</h1>"
      echo "  <p class=\"text-gray-400 leading-relaxed\">This page is coming soon.</p>"
      echo "  <a href=\"{{ url_for('main.index') }}\" class=\"inline-flex mt-8 px-5 py-2.5 text-sm font-semibold text-white bg-gradient-to-r from-ops-500 to-ops-700 rounded-xl\">Back to home</a>"
    fi
    echo "</div>"
    echo "{% endblock %}"
  } > "$dest"

  log "Scaffolded: app/templates/$t $( [ "$is_functional" -eq 1 ] && echo '  [FLAGGED: needs real content]' )"
done

# ---------- 4. Validate every scaffolded file parses as Jinja ----------
if command -v python3 >/dev/null && python3 -c "import jinja2" >/dev/null 2>&1; then
  log "Validating scaffolded templates parse correctly..."
  python3 - "$TPL_DIR" "${MISSING[@]}" <<'PYEOF'
import sys
from jinja2 import Environment
tpl_dir = sys.argv[1]
bad = []
for t in sys.argv[2:]:
    path = f"{tpl_dir}/{t}"
    try:
        Environment().parse(open(path).read())
    except Exception as e:
        bad.append((t, str(e)))
if bad:
    for t, e in bad:
        print(f"  PARSE ERROR: {t} -> {e}")
    sys.exit(1)
print(f"  All {len(sys.argv) - 2} scaffolded templates parse OK.")
PYEOF
else
  log "python3/jinja2 not available — skipping syntax validation."
fi

# ---------- 5. Summary ----------
log ""
log "Done. Scaffolded ${#MISSING[@]} placeholder template(s)."
if [ "${#FLAGGED[@]}" -gt 0 ]; then
  log ""
  log "*** ${#FLAGGED[@]} of these are functional pages (forms/auth/edit) and need REAL content: ***"
  printf '    - %s\n' "${FLAGGED[@]}"
  log ""
  log "Restart the app now to stop the crashes, then replace the flagged"
  log "templates above with real ones matching their route's actual logic"
  log "(form field names, CSRF tokens, template variables passed in)."
fi
log ""
log "Full report: $REPORT"
