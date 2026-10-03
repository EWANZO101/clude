#!/usr/bin/env python3
"""
═══════════════════════════════════════════════════════════════════════════
  patch_companies_homepage.py
═══════════════════════════════════════════════════════════════════════════
  • Adds a Companies/Brands section to the public homepage
  • Adds a company-picker dropdown to /tickets/new (default = OpsLabs)

  Drop this script in /root/opslabs and run:
      ./venv/bin/python patch_companies_homepage.py
═══════════════════════════════════════════════════════════════════════════
"""
import os, sys

TARGET = sys.argv[1] if len(sys.argv) > 1 else "/root/opslabs"
HOMEPAGE = os.path.join(TARGET, "app/templates/index.html")
NEW_TKT  = os.path.join(TARGET, "app/templates/tickets/new.html")


# ════════════════════════════════════════════════════════════════════════
# 1. HOMEPAGE — add companies section before "HOW IT WORKS"
# ════════════════════════════════════════════════════════════════════════
COMPANIES_SECTION = '''

<!-- ══════════════════════════════════════════════════════════════════════ -->
<!--   COMPANIES / BRANDS                                                   -->
<!-- ══════════════════════════════════════════════════════════════════════ -->
<section id="companies" class="py-28 border-t border-ink-600/40 relative">
  <div class="absolute inset-0 grid-overlay opacity-20 pointer-events-none"></div>
  <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 relative">

    <div class="text-center max-w-2xl mx-auto mb-14 reveal">
      <div class="text-[11px] font-bold uppercase tracking-[.3em] text-ops-400 mb-3">
        — Brands &amp; companies —
      </div>
      <h2 class="text-4xl sm:text-5xl lg:text-6xl font-extrabold tracking-tight">
        Built by a network of <span class="gtext">specialists</span>.
      </h2>
      <p class="mt-5 text-gray-400 text-lg">
        Each company brings a focused skillset. Open a ticket against any of them.
      </p>
    </div>

    {% if companies %}
    <div class="grid sm:grid-cols-2 lg:grid-cols-3 gap-4">
      {% for c in companies %}
      <a href="{{ url_for('tickets.new') }}?company_id={{ c.id }}"
         class="group relative block p-6 rounded-2xl bg-ink-800/40 border border-ink-600 hover:border-ops-500/50 transition reveal">

        <div class="flex items-start gap-4">
          {% if c.logo_url %}
            <img src="{{ c.logo_url }}" alt="{{ c.name }}"
                 class="w-12 h-12 rounded-xl object-cover border border-ink-600/60">
          {% else %}
            <div class="w-12 h-12 rounded-xl flex items-center justify-center text-lg font-bold flex-shrink-0"
                 style="background: linear-gradient(135deg, {{ c.accent_color or '#2196f3' }}33, {{ c.accent_color or '#2196f3' }}11); color: {{ c.accent_color or '#71b7ff' }};">
              {{ c.name[0]|upper }}
            </div>
          {% endif %}
          <div class="flex-1 min-w-0">
            <div class="text-base font-bold text-white group-hover:text-ops-300 transition">
              {{ c.name }}
            </div>
            {% if c.tagline %}
              <div class="text-xs text-gray-400 mt-1">{{ c.tagline }}</div>
            {% endif %}
          </div>
        </div>

        {% if c.description %}
          <p class="text-sm text-gray-400 mt-4 leading-relaxed line-clamp-3">
            {{ c.description }}
          </p>
        {% endif %}

        <div class="mt-4 pt-4 border-t border-ink-600/40 flex items-center justify-between">
          {% set _cats = c.categories.all() if c.categories.__class__.__name__ == 'AppenderQuery' else (c.categories or []) %}
          <span class="text-[11px] font-semibold uppercase tracking-widest text-gray-500">
            {{ _cats|length }} service{% if _cats|length != 1 %}s{% endif %}
          </span>
          <span class="text-xs font-semibold text-ops-400 group-hover:text-ops-300 transition flex items-center gap-1">
            Open ticket
            <svg class="w-3 h-3" fill="none" stroke="currentColor" stroke-width="2.5" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" d="M9 5l7 7-7 7"/>
            </svg>
          </span>
        </div>
      </a>
      {% endfor %}
    </div>
    {% else %}
    <div class="text-center py-12 text-sm text-gray-500">No companies yet.</div>
    {% endif %}

  </div>
</section>

'''

ANCHOR_BEFORE = (
    "<!-- ══════════════════════════════════════════════════════════════════════ -->\n"
    "<!--   HOW IT WORKS                                                         -->\n"
    "<!-- ══════════════════════════════════════════════════════════════════════ -->"
)


def patch_homepage():
    with open(HOMEPAGE) as f:
        src = f.read()
    if 'id="companies"' in src:
        print("ℹ️  Homepage already has a companies section")
        return
    if ANCHOR_BEFORE not in src:
        print("❌ Homepage anchor not found — refusing to guess insertion point")
        return
    src = src.replace(ANCHOR_BEFORE, COMPANIES_SECTION.strip() + "\n\n\n" + ANCHOR_BEFORE, 1)
    with open(HOMEPAGE, "w") as f:
        f.write(src)
    print("✅ Homepage patched (companies section added)")


# ════════════════════════════════════════════════════════════════════════
# 2. NEW TICKET — add company dropdown above the tile grid
# ════════════════════════════════════════════════════════════════════════
COMPANY_DROPDOWN_BLOCK = '''
      <!-- ─── 0. Company dropdown (NEW) ─────────────────────────────── -->
      <div>
        <div class="flex items-baseline justify-between mb-3">
          <label class="block text-xs font-bold text-gray-300 uppercase tracking-widest" for="company_select">
            <span class="text-ops-400">1.</span> Choose a company <span class="text-red-400">*</span>
          </label>
          <span class="text-[11px] text-gray-500">Defaults to OpsLabs</span>
        </div>
        <select id="company_select" name="company_id_picker"
                class="form-select w-full px-3 py-3 text-sm font-semibold">
          {% set _default_id = request.args.get('company_id')|int(0) %}
          {% set _opslabs = (companies|selectattr('name', 'in', ['OpsLabs', 'OpsLab Systems', 'OpsLabs Systems'])|list|first) %}
          {% if not _default_id and _opslabs %}
            {% set _default_id = _opslabs.id %}
          {% endif %}
          {% for c in companies %}
            <option value="{{ c.id }}" {% if c.id == _default_id %}selected{% endif %}>
              {{ c.name }}{% if c.tagline %} — {{ c.tagline }}{% endif %}
            </option>
          {% endfor %}
        </select>
      </div>

      <!-- ─── 2. Service picker (visual) ────────────────────────────── -->'''

OLD_SERVICE_HEADER = '''      <!-- ─── 1. Service picker (visual) ────────────────────────────── -->'''


def patch_new_ticket_template():
    with open(NEW_TKT) as f:
        src = f.read()

    # 2a. Inject company dropdown above the existing service picker
    if 'id="company_select"' in src:
        print("ℹ️  New-ticket template already has company dropdown")
    elif OLD_SERVICE_HEADER not in src:
        print("❌ Service picker header not found — refusing to patch")
        return
    else:
        src = src.replace(OLD_SERVICE_HEADER, COMPANY_DROPDOWN_BLOCK, 1)

        # 2b. Renumber the existing labels — actual order is:
        #     1. Service → 2. Subject → 3. Priority → 4. Describe
        # After patch they become 2 / 3 / 4 / 5 since we added "1. Company"
        src = src.replace(
            '<span class="text-ops-400">4.</span> Describe',
            '<span class="text-ops-400">5.</span> Describe'
        )
        src = src.replace(
            '<span class="text-ops-400">3.</span> Priority',
            '<span class="text-ops-400">4.</span> Priority'
        )
        src = src.replace(
            '<span class="text-ops-400">2.</span> Subject',
            '<span class="text-ops-400">3.</span> Subject'
        )
        # Service was "1." — bump it to "2."
        src = src.replace(
            '<span class="text-ops-400">1.</span> Choose a service',
            '<span class="text-ops-400">2.</span> Choose a service'
        )

        # 2c. Wire the dropdown into the existing JS: when changed, update
        #     `company_id` hidden field + filter the tiles by that company.
        injection_js = '''
  // ─── Company dropdown sync (added by patch_companies_homepage.py) ───
  const companySelect = document.getElementById('company_select');
  function filterTilesByCompany() {
    if (!companySelect) return;
    const selectedCompanyId = companySelect.value;
    companyIn.value = selectedCompanyId;
    document.querySelectorAll('.svc-tile').forEach(t => {
      const match = t.dataset.company === selectedCompanyId;
      t.style.display = match ? '' : 'none';
      if (!match && t.classList.contains('selected')) {
        t.classList.remove('selected');
        categoryIn.value = '';
      }
    });
    // Auto-select first visible tile if none chosen
    if (!categoryIn.value) {
      const firstVisible = document.querySelector('.svc-tile:not([style*="display: none"])');
      if (firstVisible) firstVisible.click();
    }
  }
  if (companySelect) {
    companySelect.addEventListener('change', filterTilesByCompany);
    // Initial filter on page load
    filterTilesByCompany();
  }
'''
        # Insert just before the closing `})();` (or last closing line) of the script
        marker = "  const companyIn  = document.getElementById('company_id');"
        if marker in src:
            src = src.replace(marker, marker + injection_js, 1)

        with open(NEW_TKT, "w") as f:
            f.write(src)
        print("✅ New-ticket template patched (company dropdown added)")


# ════════════════════════════════════════════════════════════════════════
if __name__ == "__main__":
    if not os.path.exists(HOMEPAGE):
        print(f"❌ Missing {HOMEPAGE}"); sys.exit(1)
    if not os.path.exists(NEW_TKT):
        print(f"❌ Missing {NEW_TKT}"); sys.exit(1)

    patch_homepage()
    patch_new_ticket_template()

    print("\nDone. No restart needed — templates auto-reload on next request.")
    print("Hard-refresh your browser (Ctrl+Shift+R) on / and /tickets/new")
