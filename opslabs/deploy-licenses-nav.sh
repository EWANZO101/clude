#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────
# OpsLabs — surface License Manager in nav + homepage
#
#   • Adds "Licenses" link to top-nav (and footer)
#   • Adds full License Manager section to the homepage with mock dashboard
#
# Self-contained. Run AFTER deploy-licenses.sh has installed /licenses/.
#
# Usage:    chmod +x deploy-licenses-nav.sh && ./deploy-licenses-nav.sh
# Override: TARGET=/path/to/opslabs ./deploy-licenses-nav.sh
# ─────────────────────────────────────────────────────────────────────────
set -euo pipefail

TARGET="${TARGET:-/root/opslabs}"
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="$TARGET/.deploy-backup/$STAMP"

GREEN=$(tput setaf 2 2>/dev/null || echo "")
YELLOW=$(tput setaf 3 2>/dev/null || echo "")
RED=$(tput setaf 1 2>/dev/null || echo "")
RESET=$(tput sgr0 2>/dev/null || echo "")

say()  { printf "%s▸%s %s\n" "$GREEN"  "$RESET" "$*"; }
warn() { printf "%s!%s %s\n" "$YELLOW" "$RESET" "$*"; }
die()  { printf "%s✗%s %s\n" "$RED"    "$RESET" "$*" >&2; exit 1; }

[ -d "$TARGET" ]                                  || die "$TARGET does not exist."
[ -f "$TARGET/app/templates/base.html" ]          || die "base.html missing."
[ -f "$TARGET/app/templates/index.html" ]         || die "index.html missing."

say "Target:   $TARGET"
say "Backups → $BACKUP_DIR"
echo ""

mkdir -p "$BACKUP_DIR/app/templates"
cp "$TARGET/app/templates/base.html"  "$BACKUP_DIR/app/templates/base.html"
cp "$TARGET/app/templates/index.html" "$BACKUP_DIR/app/templates/index.html"

say "Writing patch_licenses_nav.py"
cat > "$TARGET/patch_licenses_nav.py" << 'OPSLAB_NAV_EOF__3c8f5a1d'
"""
Patch base.html (nav) and index.html (homepage section) to surface the
License Manager.
"""
import os, sys

TARGET = sys.argv[1] if len(sys.argv) > 1 else "/root/opslabs"
BASE_HTML  = os.path.join(TARGET, "app/templates/base.html")
INDEX_HTML = os.path.join(TARGET, "app/templates/index.html")


# ════════════════════════════════════════════════════════════════════════
# 1. Nav link in base.html  (desktop + mobile + footer)
# ════════════════════════════════════════════════════════════════════════
NAV_NEEDLE = (
    '<a href="{{ url_for(\'main.index\') }}#features" '
    'class="px-3 py-2 text-sm text-gray-300 hover:text-white rounded-lg hover:bg-white/5 transition">Why us</a>'
)
NAV_INSERT = (
    '<a href="/licenses/" class="px-3 py-2 text-sm text-gray-300 hover:text-white rounded-lg hover:bg-white/5 transition flex items-center gap-1.5">'
    '<svg class="w-3.5 h-3.5 text-ops-400" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24">'
    '<path stroke-linecap="round" stroke-linejoin="round" d="M15 7a2 2 0 012 2m4 0a6 6 0 01-7.743 5.743L11 17H9v2H7v2H4a1 1 0 01-1-1v-2.586a1 1 0 01.293-.707l5.964-5.964A6 6 0 1121 9z"/>'
    '</svg>Licenses</a>'
)

FOOTER_NEEDLE = '<li><a href="{{ url_for(\'tickets.index\') }}" class="hover:text-white transition">My Tickets</a></li>'
FOOTER_INSERT = '<li><a href="/licenses/" class="hover:text-white transition">License Manager</a></li>'


def patch_base():
    with open(BASE_HTML) as f:
        src = f.read()

    if '/licenses/' in src:
        print("ℹ️  base.html already has Licenses links")
        return

    if NAV_NEEDLE in src:
        # Insert AFTER the "Why us" link
        src = src.replace(NAV_NEEDLE, NAV_NEEDLE + "\n        " + NAV_INSERT, 1)
    else:
        print("⚠️  Couldn't find nav anchor — desktop nav link skipped")

    # Footer
    if FOOTER_NEEDLE in src:
        src = src.replace(FOOTER_NEEDLE, FOOTER_NEEDLE + "\n          " + FOOTER_INSERT, 1)

    with open(BASE_HTML, "w") as f:
        f.write(src)
    print("✅ base.html patched (nav + footer Licenses links added)")


# ════════════════════════════════════════════════════════════════════════
# 2. Homepage section
# ════════════════════════════════════════════════════════════════════════
LICENSES_SECTION = '''

<!-- ══════════════════════════════════════════════════════════════════════ -->
<!--   LICENSE MANAGER                                                      -->
<!-- ══════════════════════════════════════════════════════════════════════ -->
<section id="licenses" class="py-28 border-t border-ink-600/40 relative overflow-hidden">
  <div class="absolute inset-0 grid-overlay opacity-20 pointer-events-none"></div>
  <div class="absolute -top-32 right-0 w-[40rem] h-[40rem] bg-ops-500/5 rounded-full blur-3xl pointer-events-none"></div>

  <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 relative">
    <div class="grid lg:grid-cols-2 gap-12 items-center">

      <!-- Copy -->
      <div class="reveal">
        <div class="text-[11px] font-bold uppercase tracking-[.3em] text-ops-400 mb-3">
          — License Manager —
        </div>
        <h2 class="text-4xl sm:text-5xl lg:text-6xl font-extrabold tracking-tight leading-[1.05]">
          License your software,
          <span class="gtext">control activations</span>,
          track usage.
        </h2>
        <p class="mt-5 text-gray-400 text-lg leading-relaxed">
          A complete licensing platform for everything we sell.
          Issue keys, lock to IPs or hardware, set expiry, manage tiers and
          features per-customer. Self-serve customer portal included.
        </p>

        <ul class="mt-7 space-y-2.5 text-sm text-gray-300">
          <li class="flex items-start gap-2">
            <svg class="w-4 h-4 mt-0.5 text-ops-400 flex-shrink-0" fill="none" stroke="currentColor" stroke-width="3" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" d="M5 13l4 4L19 7"/>
            </svg>
            <span><b class="text-white">Tiered licensing</b> — Starter / Basic / Pro / Enterprise per product</span>
          </li>
          <li class="flex items-start gap-2">
            <svg class="w-4 h-4 mt-0.5 text-ops-400 flex-shrink-0" fill="none" stroke="currentColor" stroke-width="3" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" d="M5 13l4 4L19 7"/>
            </svg>
            <span><b class="text-white">IP &amp; hardware locks</b> — bind keys to specific machines or networks</span>
          </li>
          <li class="flex items-start gap-2">
            <svg class="w-4 h-4 mt-0.5 text-ops-400 flex-shrink-0" fill="none" stroke="currentColor" stroke-width="3" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" d="M5 13l4 4L19 7"/>
            </svg>
            <span><b class="text-white">Real-time validation API</b> — software phones home, you control access</span>
          </li>
          <li class="flex items-start gap-2">
            <svg class="w-4 h-4 mt-0.5 text-ops-400 flex-shrink-0" fill="none" stroke="currentColor" stroke-width="3" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" d="M5 13l4 4L19 7"/>
            </svg>
            <span><b class="text-white">Per-feature toggles</b> — enable/disable modules per customer, instantly</span>
          </li>
        </ul>

        <div class="mt-8 flex flex-wrap items-center gap-3">
          <a href="/licenses/auth/login"
             class="inline-flex items-center justify-center gap-2 px-5 py-3 text-sm font-semibold text-white bg-gradient-to-r from-ops-500 to-ops-700 rounded-xl shadow-glow-sm hover:shadow-glow hover:scale-[1.02] transition">
            <svg class="w-4 h-4" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" d="M15 7a2 2 0 012 2m4 0a6 6 0 01-7.743 5.743L11 17H9v2H7v2H4a1 1 0 01-1-1v-2.586a1 1 0 01.293-.707l5.964-5.964A6 6 0 1121 9z"/>
            </svg>
            Admin sign-in
          </a>
          <a href="/licenses/portal/login"
             class="inline-flex items-center justify-center gap-2 px-5 py-3 text-sm font-semibold text-gray-300 bg-white/5 border border-ink-600 rounded-xl hover:bg-white/10 hover:border-ops-500/40 hover:text-white transition">
            Customer portal
            <svg class="w-3.5 h-3.5" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" d="M9 5l7 7-7 7"/>
            </svg>
          </a>
        </div>
      </div>

      <!-- Mock dashboard preview -->
      <div class="reveal">
        <div class="relative">
          <div class="absolute -inset-3 bg-gradient-to-tr from-ops-500/20 via-ops-400/10 to-transparent rounded-3xl blur-2xl pointer-events-none"></div>
          <div class="relative bg-ink-800/80 backdrop-blur-xl border border-ink-600 rounded-2xl shadow-2xl overflow-hidden">

            <!-- Window chrome -->
            <div class="flex items-center gap-2 px-4 py-3 border-b border-ink-600/60 bg-ink-900/60">
              <span class="w-2.5 h-2.5 rounded-full bg-red-500/60"></span>
              <span class="w-2.5 h-2.5 rounded-full bg-yellow-500/60"></span>
              <span class="w-2.5 h-2.5 rounded-full bg-green-500/60"></span>
              <span class="ml-3 text-[11px] font-mono text-gray-500 truncate">/licenses/admin/licenses</span>
            </div>

            <!-- Mock content -->
            <div class="p-6 space-y-4">
              <div class="flex items-center justify-between">
                <div>
                  <div class="text-[10px] font-bold uppercase tracking-widest text-ops-400">Licenses</div>
                  <div class="text-xl font-extrabold mt-0.5">Active keys</div>
                </div>
                <div class="text-right">
                  <div class="text-2xl font-extrabold text-ops-300">247</div>
                  <div class="text-[10px] text-gray-500">+12 this month</div>
                </div>
              </div>

              <div class="space-y-2">
                <div class="flex items-center gap-3 p-3 rounded-lg bg-ink-900/60 border border-ink-600/50">
                  <span class="w-2 h-2 rounded-full bg-green-400 animate-pulse"></span>
                  <span class="font-mono text-xs text-ops-300">A3F7-XKQ2-9JNP-VBHM</span>
                  <span class="ml-auto px-2 py-0.5 rounded-md text-[10px] font-bold uppercase tracking-widest bg-ops-500/15 text-ops-300">Enterprise</span>
                </div>
                <div class="flex items-center gap-3 p-3 rounded-lg bg-ink-900/60 border border-ink-600/50">
                  <span class="w-2 h-2 rounded-full bg-green-400"></span>
                  <span class="font-mono text-xs text-gray-300">7K2M-Q3PX-N5RT-9HVZ</span>
                  <span class="ml-auto px-2 py-0.5 rounded-md text-[10px] font-bold uppercase tracking-widest bg-purple-500/15 text-purple-300">Pro</span>
                </div>
                <div class="flex items-center gap-3 p-3 rounded-lg bg-ink-900/60 border border-ink-600/50">
                  <span class="w-2 h-2 rounded-full bg-yellow-400"></span>
                  <span class="font-mono text-xs text-gray-300">B8XZ-LP4M-3K2J-W5DR</span>
                  <span class="ml-auto px-2 py-0.5 rounded-md text-[10px] font-bold uppercase tracking-widest bg-blue-500/15 text-blue-300">Basic</span>
                </div>
                <div class="flex items-center gap-3 p-3 rounded-lg bg-ink-900/60 border border-ink-600/50">
                  <span class="w-2 h-2 rounded-full bg-red-400"></span>
                  <span class="font-mono text-xs text-gray-500 line-through">Q1MT-4FB7-X9YE-PR2H</span>
                  <span class="ml-auto px-2 py-0.5 rounded-md text-[10px] font-bold uppercase tracking-widest bg-red-500/15 text-red-300">Expired</span>
                </div>
              </div>

              <div class="grid grid-cols-3 gap-2 pt-2">
                <div class="p-3 rounded-lg bg-ink-900/40 border border-ink-600/40">
                  <div class="text-[10px] font-bold uppercase tracking-widest text-gray-500">Customers</div>
                  <div class="text-lg font-extrabold mt-1">63</div>
                </div>
                <div class="p-3 rounded-lg bg-ink-900/40 border border-ink-600/40">
                  <div class="text-[10px] font-bold uppercase tracking-widest text-gray-500">Activations</div>
                  <div class="text-lg font-extrabold mt-1">412</div>
                </div>
                <div class="p-3 rounded-lg bg-ink-900/40 border border-ink-600/40">
                  <div class="text-[10px] font-bold uppercase tracking-widest text-gray-500">Products</div>
                  <div class="text-lg font-extrabold mt-1">8</div>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
  </div>
</section>

'''

ANCHOR_BEFORE_HOMEPAGE = (
    "<!-- ══════════════════════════════════════════════════════════════════════ -->\n"
    "<!--   HOW IT WORKS                                                         -->\n"
    "<!-- ══════════════════════════════════════════════════════════════════════ -->"
)


def patch_index():
    with open(INDEX_HTML) as f:
        src = f.read()
    if 'id="licenses"' in src:
        print("ℹ️  index.html already has a Licenses section")
        return
    if ANCHOR_BEFORE_HOMEPAGE not in src:
        print("⚠️  Anchor not found — refusing to guess insertion point")
        return
    src = src.replace(
        ANCHOR_BEFORE_HOMEPAGE,
        LICENSES_SECTION.strip() + "\n\n\n" + ANCHOR_BEFORE_HOMEPAGE,
        1,
    )
    with open(INDEX_HTML, "w") as f:
        f.write(src)
    print("✅ index.html patched (Licenses section added)")


# ════════════════════════════════════════════════════════════════════════
if __name__ == "__main__":
    if not os.path.exists(BASE_HTML):
        print(f"❌ Missing {BASE_HTML}"); sys.exit(1)
    if not os.path.exists(INDEX_HTML):
        print(f"❌ Missing {INDEX_HTML}"); sys.exit(1)
    patch_base()
    patch_index()
    print("\nDone. Templates auto-reload — hard-refresh / and any page (Ctrl+Shift+R).")
OPSLAB_NAV_EOF__3c8f5a1d

echo ""
say "Running patcher"
cd "$TARGET"
if [ -x "$TARGET/venv/bin/python" ]; then
    "$TARGET/venv/bin/python" patch_licenses_nav.py "$TARGET"
else
    python3 patch_licenses_nav.py "$TARGET"
fi

echo ""
say "Done. No restart needed — templates auto-reload."
say "Hard-refresh browser (Ctrl+Shift+R) on / and any page in the site"
echo ""
echo "Backups in $BACKUP_DIR"
echo "Restore:  cp -r \"$BACKUP_DIR/.\" \"$TARGET/\""
