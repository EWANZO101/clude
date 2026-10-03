#!/usr/bin/env python3
"""
═══════════════════════════════════════════════════════════════════════════
  patch_company_delete.py
═══════════════════════════════════════════════════════════════════════════
  Adds three "delete" actions to each company card on /admin/companies:

    🟡 Deactivate    — hides the company everywhere, data preserved
    🟠 Reassign      — moves all its tickets to OpsLabs (fallback) and deletes
    🔴 Wipe          — deletes the company AND all its tickets + messages

  • Patches app/routes/admin.py  — adds reassign/wipe handlers, updates deactivate
  • Patches app/templates/admin/companies.html  — adds a 3-button dropdown

  Drop in /root/opslabs and run:
      ./venv/bin/python patch_company_delete.py
═══════════════════════════════════════════════════════════════════════════
"""
import os, sys

TARGET = sys.argv[1] if len(sys.argv) > 1 else "/root/opslabs"
ADMIN_PY = os.path.join(TARGET, "app/routes/admin.py")
TPL      = os.path.join(TARGET, "app/templates/admin/companies.html")


# ════════════════════════════════════════════════════════════════════════
# 1. Patch routes/admin.py
# ════════════════════════════════════════════════════════════════════════
OLD_DELETE_HANDLER = '''@admin_bp.route("/companies/<int:cid>/delete", methods=["POST"])
@admin_required
def company_delete(cid):
    c = Company.query.get_or_404(cid)
    if c.tickets.count() > 0:
        flash("Can't delete — company has tickets. Deactivate instead.", "error")
        return redirect(url_for("admin.companies"))
    db.session.delete(c)
    db.session.commit()
    flash("Company deleted.", "success")
    return redirect(url_for("admin.companies"))'''

NEW_DELETE_HANDLERS = '''@admin_bp.route("/companies/<int:cid>/deactivate", methods=["POST"])
@admin_required
def company_deactivate(cid):
    """Hide the company everywhere — tickets and history preserved."""
    c = Company.query.get_or_404(cid)
    c.is_active = False
    # Also deactivate its categories so they don't show up in pickers
    for cat in c.categories.all() if c.categories.__class__.__name__ == "AppenderQuery" else (c.categories or []):
        cat.is_active = False
    db.session.commit()
    flash(f"'{c.name}' deactivated. Tickets and history preserved.", "success")
    return redirect(url_for("admin.companies"))


@admin_bp.route("/companies/<int:cid>/reassign", methods=["POST"])
@admin_required
def company_reassign(cid):
    """Move all this company's tickets to a fallback (default = OpsLabs / first
    active company), then delete the company. Tickets and messages preserved."""
    c = Company.query.get_or_404(cid)

    fallback = (
        Company.query.filter(Company.id != c.id, Company.is_active.is_(True))
        .filter(Company.name.in_(["OpsLabs", "OpsLab Systems", "OpsLabs Systems"]))
        .first()
        or Company.query.filter(Company.id != c.id, Company.is_active.is_(True))
        .order_by(Company.id).first()
    )
    if not fallback:
        flash("No fallback company exists to receive the tickets. Create another company first.", "error")
        return redirect(url_for("admin.companies"))

    moved = (Ticket.query.filter_by(company_id=c.id)
             .update({"company_id": fallback.id, "category_id": None},
                     synchronize_session=False))
    # Drop the categories belonging to the deleted company
    TicketCategory.query.filter_by(company_id=c.id).delete(synchronize_session=False)
    db.session.delete(c)
    db.session.commit()
    flash(f"Reassigned {moved} ticket{'s' if moved != 1 else ''} from '{c.name}' to '{fallback.name}', then deleted '{c.name}'.", "success")
    return redirect(url_for("admin.companies"))


@admin_bp.route("/companies/<int:cid>/wipe", methods=["POST"])
@admin_required
def company_wipe(cid):
    """Nuke the company, all its tickets, and all messages. DESTRUCTIVE."""
    c = Company.query.get_or_404(cid)
    name = c.name

    ticket_ids = [t.id for t in Ticket.query.filter_by(company_id=c.id).all()]
    msg_count = 0
    if ticket_ids:
        msg_count = (TicketMessage.query
                     .filter(TicketMessage.ticket_id.in_(ticket_ids))
                     .delete(synchronize_session=False))
        Ticket.query.filter(Ticket.id.in_(ticket_ids)).delete(synchronize_session=False)
    TicketCategory.query.filter_by(company_id=c.id).delete(synchronize_session=False)
    db.session.delete(c)
    db.session.commit()

    flash(
        f"Wiped '{name}' — {len(ticket_ids)} ticket(s) and {msg_count} message(s) permanently deleted.",
        "success",
    )
    return redirect(url_for("admin.companies"))


@admin_bp.route("/companies/<int:cid>/delete", methods=["POST"])
@admin_required
def company_delete(cid):
    """Legacy route — kept for backwards compatibility. Refuses if tickets exist."""
    c = Company.query.get_or_404(cid)
    if c.tickets.count() > 0:
        flash("Can't delete — company has tickets. Use Deactivate, Reassign, or Wipe.", "error")
        return redirect(url_for("admin.companies"))
    db.session.delete(c)
    db.session.commit()
    flash("Company deleted.", "success")
    return redirect(url_for("admin.companies"))'''


def patch_admin_py():
    with open(ADMIN_PY) as f:
        src = f.read()

    if "company_deactivate" in src and "company_reassign" in src and "company_wipe" in src:
        print("ℹ️  admin.py already has all three delete actions")
        return

    # Ensure TicketMessage is imported (might not be in the existing admin.py)
    if "TicketMessage" not in src:
        # Try to extend the existing models import line
        import re
        m = re.search(r"^from \.\.models import ([^\n]+)$", src, re.M)
        if m:
            existing = m.group(1)
            if "TicketMessage" not in existing:
                # Just add to that import
                src = src.replace(
                    f"from ..models import {existing}",
                    f"from ..models import {existing}, TicketMessage",
                    1,
                )
        else:
            # Fallback: add a fresh import near the top
            src = "from ..models import TicketMessage  # added by patch_company_delete\n" + src

    if OLD_DELETE_HANDLER in src:
        src = src.replace(OLD_DELETE_HANDLER, NEW_DELETE_HANDLERS, 1)
    else:
        # The exact handler text differs — append our handlers at end of file instead.
        # The legacy /delete route already exists in the original, so we only
        # add the three new ones (without the legacy one).
        addition = NEW_DELETE_HANDLERS.split(
            '@admin_bp.route("/companies/<int:cid>/delete", methods=["POST"])'
        )[0].rstrip() + "\n"
        src = src.rstrip() + "\n\n\n" + addition

    with open(ADMIN_PY, "w") as f:
        f.write(src)
    print("✅ admin.py patched (three delete actions wired)")


# ════════════════════════════════════════════════════════════════════════
# 2. Patch templates/admin/companies.html
# ════════════════════════════════════════════════════════════════════════
NEW_TEMPLATE = '''{% extends "admin/_layout.html" %}
{% block admin_content %}

<div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4 mb-8">
  <div>
    <div class="text-xs font-bold uppercase tracking-widest text-ops-400 mb-1">Manage</div>
    <h1 class="text-3xl sm:text-4xl font-extrabold tracking-tight">Companies</h1>
    <p class="text-sm text-gray-400 mt-1">
      Build out service providers under the OpsLabs umbrella. Each company has its own ticket categories.
    </p>
  </div>
  <a href="{{ url_for('admin.company_new') }}"
     class="inline-flex items-center gap-2 px-5 py-2.5 text-sm font-semibold text-white bg-gradient-to-r from-ops-500 to-ops-700 rounded-xl shadow-glow-sm hover:shadow-glow hover:scale-[1.02] transition self-start sm:self-auto">
    <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4v16m8-8H4"/>
    </svg>
    New Company
  </a>
</div>

<div class="grid sm:grid-cols-2 lg:grid-cols-3 gap-4">
  {% for c in companies %}
  <div class="group relative p-6 rounded-2xl bg-ink-800/50 border border-ink-600 hover:border-ops-500/50 transition flex flex-col">

    <!-- Menu trigger (top right) -->
    <div class="absolute top-3 right-3 z-10">
      <button type="button"
              onclick="event.stopPropagation(); toggleMenu({{ c.id }});"
              aria-label="Actions"
              class="w-8 h-8 inline-flex items-center justify-center rounded-lg text-gray-400 hover:text-white hover:bg-ink-900/80 transition">
        <svg class="w-4 h-4" fill="currentColor" viewBox="0 0 24 24">
          <circle cx="5" cy="12" r="2"/><circle cx="12" cy="12" r="2"/><circle cx="19" cy="12" r="2"/>
        </svg>
      </button>

      <!-- Dropdown menu -->
      <div id="menu-{{ c.id }}"
           class="hidden absolute right-0 top-9 w-56 bg-ink-900/95 border border-ink-600 rounded-xl shadow-2xl backdrop-blur-xl overflow-hidden">
        <a href="{{ url_for('admin.company_edit', cid=c.id) }}"
           class="flex items-center gap-2 px-3 py-2 text-xs text-gray-300 hover:bg-ops-500/10 hover:text-white transition">
          <svg class="w-3.5 h-3.5 text-gray-400" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z"/>
          </svg>
          Edit details
        </a>

        <div class="border-t border-ink-600/50"></div>

        {% if c.is_active %}
        <form method="POST" action="{{ url_for('admin.company_deactivate', cid=c.id) }}"
              onsubmit="return confirm('Deactivate \\'{{ c.name|e }}\\'? It will be hidden from the public site and ticket pickers. Tickets and history are preserved.');">
          <button type="submit"
                  class="w-full flex items-center gap-2 px-3 py-2 text-xs text-yellow-300 hover:bg-yellow-500/10 transition text-left">
            <svg class="w-3.5 h-3.5" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" d="M18.364 18.364A9 9 0 005.636 5.636m12.728 12.728L5.636 5.636m12.728 12.728L18.364 5.636M5.636 18.364l12.728-12.728"/>
            </svg>
            Deactivate
            <span class="ml-auto text-[10px] text-gray-500">Recommended</span>
          </button>
        </form>
        {% else %}
        <form method="POST" action="{{ url_for('admin.company_deactivate', cid=c.id) }}">
          <button type="submit" disabled
                  class="w-full flex items-center gap-2 px-3 py-2 text-xs text-gray-500 text-left cursor-not-allowed">
            <svg class="w-3.5 h-3.5" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" d="M18.364 18.364A9 9 0 005.636 5.636m12.728 12.728L5.636 5.636"/>
            </svg>
            Deactivate
            <span class="ml-auto text-[10px]">already inactive</span>
          </button>
        </form>
        {% endif %}

        <form method="POST" action="{{ url_for('admin.company_reassign', cid=c.id) }}"
              onsubmit="return confirm('Reassign all tickets from \\'{{ c.name|e }}\\' to the fallback company, then delete \\'{{ c.name|e }}\\'? Tickets and messages will be preserved under the new company.');">
          <button type="submit"
                  class="w-full flex items-center gap-2 px-3 py-2 text-xs text-orange-300 hover:bg-orange-500/10 transition text-left">
            <svg class="w-3.5 h-3.5" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" d="M8 7h12m0 0l-4-4m4 4l-4 4m0 6H4m0 0l4 4m-4-4l4-4"/>
            </svg>
            Reassign &amp; delete
            <span class="ml-auto text-[10px] text-gray-500">→ OpsLabs</span>
          </button>
        </form>

        <form method="POST" action="{{ url_for('admin.company_wipe', cid=c.id) }}"
              onsubmit="return wipeConfirm('{{ c.name|e }}', this);">
          <button type="submit"
                  class="w-full flex items-center gap-2 px-3 py-2 text-xs text-red-300 hover:bg-red-500/10 transition text-left">
            <svg class="w-3.5 h-3.5" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6M1 7h22M10 3h4a1 1 0 011 1v3H9V4a1 1 0 011-1z"/>
            </svg>
            Wipe everything
            <span class="ml-auto text-[10px] text-gray-500">destructive</span>
          </button>
        </form>
      </div>
    </div>

    <!-- Card body (clickable area = edit) -->
    <a href="{{ url_for('admin.company_edit', cid=c.id) }}" class="flex-1 block">
      <div class="flex items-start gap-3 mb-3 pr-10">
        <div class="w-12 h-12 rounded-xl flex items-center justify-center text-lg font-extrabold border"
             style="background: {{ c.accent_color or '#2196f3' }}1a; border-color: {{ c.accent_color or '#2196f3' }}55; color: {{ c.accent_color or '#2196f3' }};">
          {{ c.name[0].upper() }}
        </div>
      </div>

      <div class="flex items-center gap-2 mb-1">
        <h3 class="text-lg font-bold group-hover:text-ops-300 transition">{{ c.name }}</h3>
        {% if c.is_active %}
          <span class="inline-flex items-center gap-1.5 text-[10px] font-semibold uppercase tracking-wider text-green-300">
            <span class="w-1.5 h-1.5 rounded-full bg-green-400"></span> Active
          </span>
        {% else %}
          <span class="inline-flex items-center gap-1.5 text-[10px] font-semibold uppercase tracking-wider text-gray-500">
            <span class="w-1.5 h-1.5 rounded-full bg-gray-500"></span> Inactive
          </span>
        {% endif %}
      </div>
      <div class="text-xs text-gray-500 font-mono mt-0.5">/{{ c.slug }}</div>
      {% if c.tagline %}<p class="text-sm text-gray-400 mt-2 line-clamp-2">{{ c.tagline }}</p>{% endif %}

      <div class="flex items-center justify-between mt-4 pt-4 border-t border-ink-600/40 text-xs">
        <span class="text-gray-500">
          {% set _cats = c.categories.all() if c.categories.__class__.__name__ == 'AppenderQuery' else (c.categories or []) %}
          {{ _cats|length }} categor{% if _cats|length == 1 %}y{% else %}ies{% endif %}
          {% set _t = c.tickets.count() if c.tickets.__class__.__name__ == 'AppenderQuery' else (c.tickets|length if c.tickets else 0) %}
          · {{ _t }} ticket{% if _t != 1 %}s{% endif %}
        </span>
        <span class="text-ops-400 group-hover:text-ops-300 inline-flex items-center gap-1">
          Edit
          <svg class="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 5l7 7-7 7"/>
          </svg>
        </span>
      </div>
    </a>
  </div>
  {% endfor %}
</div>

{% if not companies %}
<div class="text-center py-20">
  <p class="text-sm text-gray-400">No companies yet.</p>
</div>
{% endif %}

<script>
  function toggleMenu(id) {
    document.querySelectorAll('[id^="menu-"]').forEach(el => {
      if (el.id !== 'menu-' + id) el.classList.add('hidden');
    });
    const el = document.getElementById('menu-' + id);
    if (el) el.classList.toggle('hidden');
  }

  // Close menu on outside click
  document.addEventListener('click', (e) => {
    if (!e.target.closest('[id^="menu-"]') && !e.target.closest('button[onclick^="toggleMenu"]')) {
      document.querySelectorAll('[id^="menu-"]').forEach(el => el.classList.add('hidden'));
    }
  });

  // Two-step confirmation for the wipe action
  function wipeConfirm(name, form) {
    const ok = confirm("⚠️  PERMANENT DELETE\\n\\nThis will delete '" + name + "' AND every ticket and message attached to it. There is no undo.\\n\\nProceed?");
    if (!ok) return false;
    const typed = prompt("To confirm, type the company name exactly:\\n\\n" + name);
    if (typed !== name) {
      alert("Name didn't match — cancelled.");
      return false;
    }
    return true;
  }
</script>

{% endblock %}
'''


def patch_template():
    with open(TPL) as f:
        src = f.read()
    if "wipeConfirm" in src and "company_wipe" in src and "company_reassign" in src:
        print("ℹ️  companies.html already has the three-action menu")
        return
    with open(TPL, "w") as f:
        f.write(NEW_TEMPLATE)
    print("✅ companies.html patched (three-action dropdown menu)")


# ════════════════════════════════════════════════════════════════════════
if __name__ == "__main__":
    if not os.path.exists(ADMIN_PY):
        print(f"❌ Missing {ADMIN_PY}"); sys.exit(1)
    if not os.path.exists(TPL):
        print(f"❌ Missing {TPL}"); sys.exit(1)

    patch_admin_py()
    patch_template()

    print("\nNow restart Flask: sudo systemctl restart opslabs-app")
    print("Then hard-refresh /admin/companies (Ctrl+Shift+R)")
