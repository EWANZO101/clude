#!/usr/bin/env bash
# Self-contained OpsLab "Settings > Appearance" theme-switcher installer.
# Everything it needs (CSS, JS, templates, the settings module) is embedded
# below — no separate zip required. Matches your real app.py structure:
# application-factory create_app(), blueprints under modules/<name>/routes.py,
# imports/registrations ending on modules.dns.routes / dns_bp.
#
# Usage (run as root, from anywhere):
#   bash fix-settings.sh
#
# Safe to re-run. Backs everything up first; if the restart fails or the
# service logs an error right after, it automatically restores the backup
# and restarts again so the panel is never left broken.

set -uo pipefail

APP_DIR="/root/server-panel"
SERVICE_NAME="SERVERPANEL.service"

if [ ! -f "$APP_DIR/app.py" ]; then
  echo "ERROR: $APP_DIR/app.py not found. Edit APP_DIR at the top of this script if your app lives elsewhere." >&2
  exit 1
fi

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="/root/server-panel-backups/$TIMESTAMP"
mkdir -p "$BACKUP_DIR"

for f in \
  "app.py" \
  "templates/base.html" \
  "static/css/style.css" \
  "static/js/theme.js" \
  "modules/settings/routes.py" \
  "modules/settings/templates/appearance.html" \
  "modules/settings/__init__.py"
do
  if [ -f "$APP_DIR/$f" ]; then
    mkdir -p "$BACKUP_DIR/$(dirname "$f")"
    cp "$APP_DIR/$f" "$BACKUP_DIR/$f"
  fi
done
echo "Backed up existing files -> $BACKUP_DIR"

restore_backup() {
  echo "Rolling back to $BACKUP_DIR ..."
  for f in \
    "app.py" \
    "templates/base.html" \
    "static/css/style.css" \
    "static/js/theme.js" \
    "modules/settings/routes.py" \
    "modules/settings/templates/appearance.html" \
    "modules/settings/__init__.py"
  do
    if [ -f "$BACKUP_DIR/$f" ]; then
      mkdir -p "$(dirname "$APP_DIR/$f")"
      cp "$BACKUP_DIR/$f" "$APP_DIR/$f"
    fi
  done
  systemctl restart "$SERVICE_NAME"
  echo "Rolled back and restarted $SERVICE_NAME."
}

# --- write the settings module ----------------------------------------------
mkdir -p "$APP_DIR/modules/settings/templates"

touch "$APP_DIR/modules/settings/__init__.py"

cat > "$APP_DIR/modules/settings/routes.py" <<'ROUTES_EOF'
from flask import Blueprint, render_template
from flask_login import login_required

settings_bp = Blueprint("settings", __name__, template_folder="templates")


@settings_bp.route("/settings/appearance")
@login_required
def appearance():
    return render_template("appearance.html")
ROUTES_EOF

cat > "$APP_DIR/modules/settings/templates/appearance.html" <<'APP_TMPL_EOF'
{% extends "base.html" %}
{% block title %}Appearance — {{ panel_name }}{% endblock %}

{% block content %}
<div class="topbar">
  <div>
    <p class="page-eyebrow">Settings</p>
    <h1 class="page-title">Appearance</h1>
    <p class="page-sub">Choose how the panel looks on this browser. Applies to every page immediately.</p>
  </div>
</div>

<div class="card tight" style="max-width: 720px;">
  <div class="card-label">Panel theme</div>

  <div class="theme-picker" id="theme-picker">
    <label class="theme-option" data-theme-option="modern">
      <input type="radio" name="theme" value="modern">
      <div class="theme-preview">
        <div class="tp-side"></div>
        <div class="tp-main">
          <div class="tp-bar"></div>
          <div class="tp-row"></div>
          <div class="tp-row"></div>
          <div class="tp-row"></div>
          <div class="tp-row"></div>
        </div>
      </div>
      <div class="theme-option-label">
        <div>
          <div class="theme-option-name">Modern Dark</div>
          <div class="theme-option-desc">Spacious rack-gear layout, full detail.</div>
        </div>
        <span class="theme-option-check"></span>
      </div>
    </label>

    <label class="theme-option" data-theme-option="compact">
      <input type="radio" name="theme" value="compact">
      <div class="theme-preview compact">
        <div class="tp-side"></div>
        <div class="tp-main">
          <div class="tp-bar"></div>
          <div class="tp-row"></div>
          <div class="tp-row"></div>
          <div class="tp-row"></div>
          <div class="tp-row"></div>
        </div>
      </div>
      <div class="theme-option-label">
        <div>
          <div class="theme-option-name">Compact / Data-Dense</div>
          <div class="theme-option-desc">Tighter rows, breadcrumb headers, more on screen.</div>
        </div>
        <span class="theme-option-check"></span>
      </div>
    </label>
  </div>

  <p class="card-meta" id="theme-save-status" style="margin-top: 16px;">&nbsp;</p>
</div>
{% endblock %}

{% block scripts %}
<script>
  (function () {
    var picker = document.getElementById('theme-picker');
    var status = document.getElementById('theme-save-status');
    var options = picker.querySelectorAll('.theme-option');

    function paintSelection(theme) {
      options.forEach(function (opt) {
        var isSelected = opt.getAttribute('data-theme-option') === theme;
        opt.classList.toggle('selected', isSelected);
        opt.querySelector('input').checked = isSelected;
      });
    }

    // Reflect whatever is currently applied (set by the inline anti-flash
    // script in <head> / static/js/theme.js) when the page loads.
    paintSelection(window.OpsLabTheme.get());

    options.forEach(function (opt) {
      opt.addEventListener('click', function () {
        var theme = opt.getAttribute('data-theme-option');
        window.OpsLabTheme.set(theme);
        paintSelection(theme);
        status.textContent = 'Saved — applied to this browser.';
        clearTimeout(window.__themeStatusTimer);
        window.__themeStatusTimer = setTimeout(function () {
          status.textContent = '\u00A0';
        }, 2500);
      });
    });
  })();
</script>
{% endblock %}
APP_TMPL_EOF

echo "Wrote modules/settings/ (routes.py + templates/appearance.html)"

# --- write base.html, style.css, theme.js -----------------------------------
mkdir -p "$APP_DIR/templates" "$APP_DIR/static/css" "$APP_DIR/static/js"

cat > "$APP_DIR/templates/base.html" <<'BASE_EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <script>
    // Applied before any CSS/paint so there's no flash of the wrong theme.
    // Mirrors the logic in static/js/theme.js (kept inline here on purpose).
    (function () {
      try {
        var t = localStorage.getItem('opslab-theme');
        if (t === 'compact') document.documentElement.setAttribute('data-theme', 'compact');
      } catch (e) {}
    })();
  </script>
  <title>{% block title %}{{ panel_name }}{% endblock %}</title>
  <link rel="icon" type="image/svg+xml" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'%3E%3Crect width='32' height='32' rx='6' fill='%23100f0d'/%3E%3Crect x='2' y='2' width='28' height='28' rx='5' fill='%2318160f' stroke='%23453e30'/%3E%3Ctext x='16' y='21' font-family='Arial,sans-serif' font-weight='800' font-size='14' fill='%23ff8a3d' text-anchor='middle'%3EOL%3C/text%3E%3Crect x='9' y='24' width='14' height='2' rx='1' fill='%23ff8a3d'/%3E%3C/svg%3E">
  <link rel="preload" href="{{ url_for('static', filename='fonts/ibm-plex-sans-latin-400-normal.woff2') }}" as="font" type="font/woff2" crossorigin>
  <link rel="preload" href="{{ url_for('static', filename='fonts/big-shoulders-display-latin-700-normal.woff2') }}" as="font" type="font/woff2" crossorigin>
  <link rel="stylesheet" href="{{ url_for('static', filename='css/style.css') }}">
  {% block extra_head %}{% endblock %}
</head>
<body>
  {% if current_user.is_authenticated %}
  <div class="app-shell">
    <aside class="sidebar">
      <div class="brand">
        <div class="brand-mark">OL</div>
        <div class="brand-text">
          <span class="brand-name">OpsLab</span>
          <span class="brand-sub">SERVER PANEL</span>
        </div>
      </div>

      <a class="nav-link {{ 'active' if request.endpoint == 'dashboard.index' or request.endpoint == 'dashboard.root' }}" href="{{ url_for('dashboard.index') }}">
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="7" height="9" rx="1.5"/><rect x="14" y="3" width="7" height="5" rx="1.5"/><rect x="14" y="12" width="7" height="9" rx="1.5"/><rect x="3" y="16" width="7" height="5" rx="1.5"/></svg>
        Dashboard
      </a>
      <a class="nav-link {{ 'active' if request.blueprint == 'systemctl' }}" href="{{ url_for('systemctl.index') }}">
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="4" width="18" height="7" rx="1.5"/><rect x="3" y="13" width="18" height="7" rx="1.5"/><circle cx="7" cy="7.5" r="0.6" fill="currentColor" stroke="none"/><circle cx="7" cy="16.5" r="0.6" fill="currentColor" stroke="none"/></svg>
        Services
      </a>
      <a class="nav-link {{ 'active' if request.blueprint == 'nginx' }}" href="{{ url_for('nginx.index') }}">
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3c2.5 2.5 3.8 5.7 3.8 9s-1.3 6.5-3.8 9c-2.5-2.5-3.8-5.7-3.8-9s1.3-6.5 3.8-9z"/></svg>
        Nginx
      </a>
      <a class="nav-link {{ 'active' if request.blueprint == 'firewall' }}" href="{{ url_for('firewall.index') }}">
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3l7 3v6c0 4.5-3 7.7-7 9-4-1.3-7-4.5-7-9V6l7-3z"/></svg>
        Firewall
      </a>
      {% if current_user.has_permission('security.view') %}
      <a class="nav-link {{ 'active' if request.blueprint == 'security' }}" href="{{ url_for('security.index') }}">
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3l7 3v6c0 4.5-3 7.7-7 9-4-1.3-7-4.5-7-9V6l7-3z"/><path d="M9.5 12l1.8 1.8L15 10"/></svg>
        Security
      </a>
      {% endif %}
      {% if current_user.has_permission('dns.view') %}
      <a class="nav-link {{ 'active' if request.blueprint == 'dns' }}" href="{{ url_for('dns.index') }}">
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M6 18a4 4 0 01-.6-7.95A5.5 5.5 0 0116 8.5a4.5 4.5 0 011 8.9"/><path d="M12 12v6M9.5 15.5L12 18l2.5-2.5"/></svg>
        DNS
      </a>
      {% endif %}
      <a class="nav-link {{ 'active' if request.blueprint == 'networking' }}" href="{{ url_for('networking.index') }}">
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="5" cy="6" r="2.2"/><circle cx="19" cy="6" r="2.2"/><circle cx="12" cy="18" r="2.2"/><path d="M6.8 7.6L11 16M17.2 7.6L13 16"/></svg>
        Networking
      </a>
      <a class="nav-link {{ 'active' if request.blueprint == 'installers' }}" href="{{ url_for('installers.index') }}">
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 12.5v5a1.5 1.5 0 01-1.5 1.5h-15A1.5 1.5 0 013 17.5v-5"/><path d="M7 9l5 5 5-5M12 14V3"/></svg>
        Installers
      </a>
      <a class="nav-link {{ 'active' if request.blueprint == 'users' }}" href="{{ url_for('users.index') }}">
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="9" cy="8" r="3.2"/><path d="M3 20c0-3.3 2.7-6 6-6s6 2.7 6 6"/><path d="M16.5 6.2a3.2 3.2 0 010 6.1M21 20c0-2.8-1.9-5.1-4.5-5.8"/></svg>
        Users
      </a>
      <a class="nav-link {{ 'active' if request.blueprint == 'logs' }}" href="{{ url_for('logs.index') }}">
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="4" width="18" height="16" rx="1.5"/><path d="M7 9l3 2.5L7 14M13 14h4"/></svg>
        Logs
      </a>

      <div class="sidebar-footer">
        <a class="nav-link {{ 'active' if request.blueprint == 'settings' }}" href="{{ url_for('settings.appearance') }}">
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 00.34 1.87l.06.06a2 2 0 11-2.83 2.83l-.06-.06a1.7 1.7 0 00-1.87-.34 1.7 1.7 0 00-1 1.55V21a2 2 0 11-4 0v-.09A1.7 1.7 0 009 19.36a1.7 1.7 0 00-1.87.34l-.06.06a2 2 0 11-2.83-2.83l.06-.06A1.7 1.7 0 004.64 15a1.7 1.7 0 00-1.55-1H3a2 2 0 110-4h.09A1.7 1.7 0 004.64 9a1.7 1.7 0 00-.34-1.87l-.06-.06a2 2 0 112.83-2.83l.06.06A1.7 1.7 0 009 4.64a1.7 1.7 0 001-1.55V3a2 2 0 114 0v.09a1.7 1.7 0 001 1.55 1.7 1.7 0 001.87-.34l.06-.06a2 2 0 112.83 2.83l-.06.06A1.7 1.7 0 0019.36 9a1.7 1.7 0 001.55 1H21a2 2 0 110 4h-.09a1.7 1.7 0 00-1.55 1z"/></svg>
          Settings
        </a>
        <div class="sidebar-user">
          <div class="sidebar-user-avatar">{{ current_user.username[:2] | upper }}</div>
          <div>
            <div class="sidebar-user-name">{{ current_user.username }}</div>
            <div class="sidebar-user-role">{{ current_user.role.name if current_user.role else '—' }}</div>
          </div>
        </div>
        <a class="nav-link nav-exit" href="{{ url_for('auth.logout') }}">
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M9 21H5a2 2 0 01-2-2V5a2 2 0 012-2h4"/><path d="M16 17l5-5-5-5M21 12H9"/></svg>
          Log out
        </a>
      </div>
    </aside>

    <main class="main">
      {% with messages = get_flashed_messages(with_categories=true) %}
        {% if messages %}
          {% for category, message in messages %}
            <div class="flash flash-{{ category }}">{{ message }}</div>
          {% endfor %}
        {% endif %}
      {% endwith %}
      {% block content %}{% endblock %}
    </main>
  </div>
  {% else %}
    {% block auth_content %}{% endblock %}
  {% endif %}

  <script src="{{ url_for('static', filename='js/theme.js') }}"></script>
  {% block scripts %}{% endblock %}
</body>
</html>
BASE_EOF

cat > "$APP_DIR/static/css/style.css" <<'CSS_EOF'
/* Fonts are self-hosted in static/fonts (see @font-face block below) to
   avoid a render-blocking round trip to a font CDN on every navigation —
   this is a classic server-rendered multi-page app with no client-side
   routing, so that cost is paid on every single page load. */
@font-face {
  font-family: 'IBM Plex Sans';
  font-style: normal;
  font-weight: 400;
  font-display: swap;
  src: url('../fonts/ibm-plex-sans-latin-400-normal.woff2') format('woff2');
}
@font-face {
  font-family: 'IBM Plex Sans';
  font-style: normal;
  font-weight: 500;
  font-display: swap;
  src: url('../fonts/ibm-plex-sans-latin-500-normal.woff2') format('woff2');
}
@font-face {
  font-family: 'IBM Plex Sans';
  font-style: normal;
  font-weight: 600;
  font-display: swap;
  src: url('../fonts/ibm-plex-sans-latin-600-normal.woff2') format('woff2');
}
@font-face {
  font-family: 'IBM Plex Sans';
  font-style: normal;
  font-weight: 700;
  font-display: swap;
  src: url('../fonts/ibm-plex-sans-latin-700-normal.woff2') format('woff2');
}
@font-face {
  font-family: 'Big Shoulders Display';
  font-style: normal;
  font-weight: 500;
  font-display: swap;
  src: url('../fonts/big-shoulders-display-latin-500-normal.woff2') format('woff2');
}
@font-face {
  font-family: 'Big Shoulders Display';
  font-style: normal;
  font-weight: 600;
  font-display: swap;
  src: url('../fonts/big-shoulders-display-latin-600-normal.woff2') format('woff2');
}
@font-face {
  font-family: 'Big Shoulders Display';
  font-style: normal;
  font-weight: 700;
  font-display: swap;
  src: url('../fonts/big-shoulders-display-latin-700-normal.woff2') format('woff2');
}
@font-face {
  font-family: 'Big Shoulders Display';
  font-style: normal;
  font-weight: 800;
  font-display: swap;
  src: url('../fonts/big-shoulders-display-latin-800-normal.woff2') format('woff2');
}
@font-face {
  font-family: 'JetBrains Mono';
  font-style: normal;
  font-weight: 400;
  font-display: swap;
  src: url('../fonts/jetbrains-mono-latin-400-normal.woff2') format('woff2');
}
@font-face {
  font-family: 'JetBrains Mono';
  font-style: normal;
  font-weight: 500;
  font-display: swap;
  src: url('../fonts/jetbrains-mono-latin-500-normal.woff2') format('woff2');
}
@font-face {
  font-family: 'JetBrains Mono';
  font-style: normal;
  font-weight: 600;
  font-display: swap;
  src: url('../fonts/jetbrains-mono-latin-600-normal.woff2') format('woff2');
}
@font-face {
  font-family: 'JetBrains Mono';
  font-style: normal;
  font-weight: 700;
  font-display: swap;
  src: url('../fonts/jetbrains-mono-latin-700-normal.woff2') format('woff2');
}

/* =========================================================
   OpsLab Server Panel — design tokens
   Direction: rack-mounted equipment. This is a root-access tool for
   physical/virtual servers — the visual language borrows from actual
   19" rack gear: warm graphite chassis, engraved nameplates, punch-hole
   rack rails, jack/channel numbering, and a copper LED for "live/armed"
   state instead of the usual SaaS blue-gradient glow.
   Display: Big Shoulders Display (condensed, set in caps — nameplate
   engraving). Body: IBM Plex Sans. Data/readouts: JetBrains Mono.
   ========================================================= */
:root {
  --bg-void: #100f0d;
  --bg-panel: #18160f;
  --bg-panel-raised: #211e17;
  --bg-panel-hover: #2b2720;
  --border-subtle: #2c2820;
  --border-strong: #453e30;

  --accent: #ff8a3d;
  --accent-deep: #b5541a;
  --accent-dim: rgba(255, 138, 61, 0.14);
  --accent-ink: #3d2712;
  --data: #2dd4bf;
  --data-dim: rgba(45, 212, 191, 0.14);

  --text-primary: #f3ede1;
  --text-secondary: #a89c87;
  --text-muted: #6b6153;

  --ok: #4ade80;
  --ok-dim: rgba(74, 222, 128, 0.14);
  --warn: #f5c518;
  --warn-dim: rgba(245, 197, 24, 0.14);
  --danger: #f2495c;
  --danger-dim: rgba(242, 73, 92, 0.14);

  --font-body: 'IBM Plex Sans', -apple-system, BlinkMacSystemFont, sans-serif;
  --font-display: 'Big Shoulders Display', 'IBM Plex Sans', sans-serif;
  --font-mono: 'JetBrains Mono', 'Courier New', monospace;

  --radius-sm: 3px;
  --radius: 5px;
  --radius-lg: 7px;
  --radius-xl: 9px;
  --radius-pill: 999px;

  --shadow-card: 0 1px 0 rgba(0,0,0,0.5), 0 14px 28px -20px rgba(0,0,0,0.7);
  --shadow-pop: 0 24px 50px -22px rgba(0,0,0,0.75);
  --rivet: radial-gradient(circle at 34% 32%, #5c5240, #221e17 72%);
}

* { box-sizing: border-box; }

html, body {
  margin: 0;
  padding: 0;
  background: var(--bg-void);
  color: var(--text-primary);
  font-family: var(--font-body);
  font-size: 15px;
  min-height: 100vh;
  -webkit-font-smoothing: antialiased;
}

/* Faint brushed-metal grain + a single warm floodlight from the top-left,
   like a rack cabinet lit from one work lamp rather than an even glow. */
body {
  background-image:
    radial-gradient(ellipse 900px 500px at 6% -8%, rgba(255, 138, 61, 0.08), transparent 55%),
    repeating-linear-gradient(180deg, rgba(255,255,255,0.012) 0px, rgba(255,255,255,0.012) 1px, transparent 1px, transparent 3px);
  background-attachment: fixed;
}

a { color: var(--data); text-decoration: none; }
a:hover { color: var(--accent); }

*:focus-visible {
  outline: 2px solid var(--accent);
  outline-offset: 2px;
  border-radius: 3px;
}

::selection { background: var(--accent); color: #1a1207; }

::-webkit-scrollbar { width: 10px; height: 10px; }
::-webkit-scrollbar-track { background: transparent; }
::-webkit-scrollbar-thumb { background: var(--border-strong); border-radius: 8px; }
::-webkit-scrollbar-thumb:hover { background: var(--accent-deep); }

.mono { font-family: var(--font-mono); }

h1, h2, h3 {
  font-family: var(--font-display);
  font-weight: 700;
  letter-spacing: 0.01em;
}

code {
  font-family: var(--font-mono);
  font-size: 0.9em;
  background: var(--bg-void);
  border: 1px solid var(--border-subtle);
  border-radius: 4px;
  padding: 1px 5px;
}

/* =========================================================
   Shell / sidebar — styled as a patch bay: each link is a numbered
   jack (J1, J2, ...) via a CSS counter, no markup changes needed.
   ========================================================= */
.app-shell {
  display: flex;
  min-height: 100vh;
  counter-reset: jack;
}

.sidebar {
  width: 256px;
  flex-shrink: 0;
  background:
    linear-gradient(180deg, rgba(255,138,61,0.05), transparent 160px),
    var(--bg-panel);
  border-right: 1px solid var(--border-subtle);
  padding: 20px 14px 16px;
  display: flex;
  flex-direction: column;
  gap: 2px;
  position: sticky;
  top: 0;
  height: 100vh;
  overflow-y: auto;
}

.brand {
  display: flex;
  align-items: center;
  gap: 11px;
  padding: 6px 8px 20px;
  margin-bottom: 10px;
  border-bottom: 1px solid var(--border-subtle);
  position: relative;
}
/* Nameplate mounting screws, top corners of the sidebar block */
.brand::after {
  content: "";
  position: absolute;
  top: 0; left: 50%;
  width: 3px; height: 3px;
  border-radius: 50%;
  background: var(--border-strong);
  box-shadow: -108px 2px 0 var(--border-strong), 108px 2px 0 var(--border-strong);
}

.brand-mark {
  flex-shrink: 0;
  width: 36px;
  height: 36px;
  border-radius: var(--radius);
  background: var(--bg-void);
  border: 1px solid var(--border-strong);
  display: flex;
  align-items: center;
  justify-content: center;
  font-family: var(--font-display);
  font-weight: 700;
  font-size: 16px;
  color: var(--accent);
  letter-spacing: 0.02em;
  position: relative;
}
.brand-mark::after {
  content: "";
  position: absolute;
  bottom: 4px; left: 50%;
  transform: translateX(-50%);
  width: 14px; height: 2px;
  border-radius: 1px;
  background: var(--accent);
  box-shadow: 0 0 6px 1px var(--accent);
}

.brand-text { line-height: 1.2; }
.brand-text .brand-name {
  display: block;
  font-family: var(--font-display);
  font-weight: 700;
  font-size: 18px;
  color: var(--text-primary);
  letter-spacing: 0.02em;
  text-transform: uppercase;
}
.brand-text .brand-sub {
  display: block;
  font-family: var(--font-mono);
  font-size: 9.5px;
  color: var(--text-muted);
  font-weight: 600;
  letter-spacing: 0.16em;
  margin-top: 3px;
}

.nav-link {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 9px 12px;
  border-radius: var(--radius);
  color: var(--text-secondary);
  font-size: 13.5px;
  font-weight: 500;
  position: relative;
  transition: background 0.12s ease, color 0.12s ease;
  counter-increment: jack;
}
.nav-link svg { flex-shrink: 0; opacity: 0.7; }
.nav-link:hover { background: var(--bg-panel-hover); color: var(--text-primary); }
.nav-link:hover svg { opacity: 1; }
.nav-link.active {
  background: var(--bg-panel-raised);
  color: var(--text-primary);
  box-shadow: inset 2px 0 0 var(--accent);
}
.nav-link.active svg { opacity: 1; color: var(--accent); }
/* Jack channel number, right-aligned, like a patch bay label strip */
.nav-link::after {
  content: "J" counter(jack);
  margin-left: auto;
  font-family: var(--font-mono);
  font-size: 9.5px;
  color: var(--text-muted);
  letter-spacing: 0.04em;
  opacity: 0.7;
}
.nav-link.active::after { color: var(--accent); opacity: 1; }
.nav-link.nav-exit { counter-increment: none; }
.nav-link.nav-exit::after { content: none; }

.sidebar-footer {
  margin-top: auto;
  padding-top: 14px;
  border-top: 1px solid var(--border-subtle);
}
.sidebar-user {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 6px 8px 12px;
}
.sidebar-user-avatar {
  width: 32px;
  height: 32px;
  border-radius: var(--radius);
  background: var(--bg-void);
  border: 1px solid var(--accent-deep);
  display: flex;
  align-items: center;
  justify-content: center;
  font-family: var(--font-mono);
  font-size: 11px;
  font-weight: 700;
  color: var(--accent);
  flex-shrink: 0;
}
.sidebar-user-name { font-size: 12.5px; color: var(--text-primary); font-weight: 600; line-height: 1.3; }
.sidebar-user-role {
  font-size: 10px;
  color: var(--text-muted);
  font-family: var(--font-mono);
  letter-spacing: 0.06em;
  text-transform: uppercase;
}

/* =========================================================
   Main content / topbar
   ========================================================= */
.main {
  flex: 1;
  padding: 30px 40px 60px;
  max-width: 1440px;
  min-width: 0;
  counter-reset: rackunit;
}

.topbar {
  display: flex;
  justify-content: space-between;
  align-items: flex-start;
  gap: 16px;
  margin-bottom: 26px;
  padding-bottom: 20px;
  border-bottom: 1px solid var(--border-subtle);
  flex-wrap: wrap;
}

.page-eyebrow {
  font-family: var(--font-mono);
  font-size: 10.5px;
  letter-spacing: 0.14em;
  text-transform: uppercase;
  color: var(--data);
  margin: 0 0 8px;
  display: flex;
  align-items: center;
  gap: 6px;
}

.page-title {
  font-family: var(--font-display);
  font-size: 32px;
  font-weight: 700;
  margin: 0;
  letter-spacing: 0.01em;
  text-transform: uppercase;
}
.page-sub { color: var(--text-muted); font-size: 13px; margin-top: 6px; }

.topbar-actions { display: flex; gap: 8px; flex-wrap: wrap; align-items: center; }

/* =========================================================
   Cards / grid — each card reads as a mounted rack module: a squared
   chassis, two top rivets, and a "U##" unit tag stamped top-right
   (a real CSS counter, not static markup — it renumbers itself as
   cards are added/removed on any page, no template changes needed).
   ========================================================= */
.grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(230px, 1fr));
  gap: 16px;
}

.grid-2 { grid-template-columns: 1fr 1fr; }

.card {
  background: var(--bg-panel);
  border: 1px solid var(--border-subtle);
  border-radius: var(--radius-lg);
  padding: 22px 22px 20px;
  box-shadow: var(--shadow-card);
  position: relative;
  counter-increment: rackunit;
}
.card::before {
  content: "";
  position: absolute;
  top: 9px; left: 12px;
  width: 4px; height: 4px;
  border-radius: 50%;
  background: var(--rivet);
}
.card::after {
  content: "U" counter(rackunit, decimal-leading-zero);
  position: absolute;
  top: 8px; right: 12px;
  font-family: var(--font-mono);
  font-size: 9px;
  letter-spacing: 0.06em;
  color: var(--text-muted);
  opacity: 0.55;
}
.card.flush::before, .card.flush::after { display: none; }

.card.stat {
  overflow: hidden;
  padding-top: 24px;
}
/* Caution-stripe bezel: the one bold, deliberately loud accent on the
   page — reserved for stat cards only so it stays a signature rather
   than wallpaper. */
.card.stat::before {
  content: "";
  position: absolute;
  top: 0; left: 0; right: 0;
  height: 3px;
  background: repeating-linear-gradient(
    -45deg,
    var(--accent) 0px, var(--accent) 6px,
    transparent 6px, transparent 12px
  );
  opacity: 0.65;
  box-shadow: none;
  border-radius: 0;
}
.card.stat::after {
  top: 10px;
}

.card.danger-outline { border-color: rgba(242, 73, 92, 0.4); }
.card.flush { padding: 0; overflow: hidden; }
.card.tight { margin-bottom: 16px; }

.card-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 4px;
}

.card-label {
  font-family: var(--font-mono);
  font-size: 11px;
  letter-spacing: 0.08em;
  text-transform: uppercase;
  color: var(--text-muted);
  margin-bottom: 10px;
  display: flex;
  align-items: center;
  gap: 8px;
}

.card-value {
  font-size: 30px;
  font-weight: 700;
  font-family: var(--font-mono);
  letter-spacing: -0.01em;
}
.card-value.line { font-size: 18px; }
.card-value small { font-size: 13px; color: var(--text-muted); font-weight: 500; }

.card-meta { color: var(--text-muted); font-size: 12.5px; margin-top: 10px; font-family: var(--font-mono); line-height: 1.7; }

.card.stat .card-header { margin-bottom: 10px; }
.card.stat .card-value { margin-top: 2px; }

/* Trend chip used inline next to a stat card's label */
.trend-chip {
  display: inline-flex;
  align-items: center;
  gap: 3px;
  font-family: var(--font-mono);
  font-size: 11px;
  font-weight: 600;
  padding: 3px 8px;
  border-radius: var(--radius-pill);
  border: 1px solid transparent;
}
.trend-chip.up { color: var(--ok); background: var(--ok-dim); border-color: rgba(74, 222, 128, 0.3); }
.trend-chip.down { color: var(--danger); background: var(--danger-dim); border-color: rgba(242, 73, 92, 0.3); }
.trend-chip.flat { color: var(--text-muted); background: var(--bg-panel-raised); border-color: var(--border-subtle); }

/* =========================================================
   Chart cards (Dashboard traffic / per-core panels)
   ========================================================= */
.chart-card .card-header { margin-bottom: 2px; }
.chart-legend { display: flex; gap: 14px; font-size: 11.5px; color: var(--text-muted); font-family: var(--font-mono); }
.chart-legend span { display: inline-flex; align-items: center; gap: 5px; }
.chart-legend .dot { width: 7px; height: 7px; border-radius: 50%; display: inline-block; }
.chart-svg-wrap { margin-top: 6px; }
.chart-svg-wrap svg { width: 100%; height: auto; display: block; overflow: visible; }
.chart-axis-labels {
  display: flex;
  justify-content: space-between;
  font-family: var(--font-mono);
  font-size: 10px;
  color: var(--text-muted);
  margin-top: 6px;
}

.progress-track {
  height: 6px;
  border-radius: 3px;
  background: var(--border-subtle);
  overflow: hidden;
  margin-top: 12px;
}
.progress-fill {
  height: 100%;
  background: var(--accent);
  border-radius: 3px;
  transition: width 0.6s ease;
}
.progress-fill.ok { background: var(--ok); }
.progress-fill.warn { background: var(--warn); }
.progress-fill.danger { background: var(--danger); }

/* =========================================================
   Buttons
   ========================================================= */
.btn, .btn-primary, .btn-secondary, .btn-danger, .btn-ghost {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  gap: 7px;
  border: none;
  border-radius: var(--radius);
  padding: 9px 16px;
  font-size: 13px;
  font-weight: 600;
  font-family: var(--font-body);
  cursor: pointer;
  white-space: nowrap;
  transition: filter 0.12s ease, border-color 0.12s ease, color 0.12s ease, background 0.12s ease;
}
.btn:active, .btn-primary:active, .btn-secondary:active, .btn-danger:active, .btn-ghost:active { transform: translateY(1px); }

.btn-primary, button.btn-primary, input.btn-primary, a.btn-primary {
  background: var(--accent);
  color: #1a1207;
  width: auto;
}
.btn-primary:hover { filter: brightness(1.12); color: #1a1207; }

.btn-secondary, button.btn-secondary, a.btn-secondary {
  background: var(--bg-panel-raised);
  border: 1px solid var(--border-strong);
  color: var(--text-secondary);
}
.btn-secondary:hover { color: var(--text-primary); border-color: var(--data); }

.btn-ghost {
  background: transparent;
  border: 1px solid var(--border-subtle);
  color: var(--text-secondary);
}
.btn-ghost:hover { color: var(--text-primary); border-color: var(--border-strong); background: var(--bg-panel-hover); }

.btn-danger, button.btn-danger, a.btn-danger {
  background: var(--bg-panel-raised);
  border: 1px solid var(--border-strong);
  color: var(--danger);
}
.btn-danger:hover { border-color: var(--danger); background: var(--danger-dim); }

.btn-sm { padding: 5px 10px; font-size: 11.5px; border-radius: var(--radius-sm); }
.btn-block { width: 100%; }

.btn-row { display: flex; gap: 8px; flex-wrap: wrap; align-items: center; }

/* legacy full-width primary button (auth forms) */
.auth-card .btn-primary { width: 100%; padding: 11px; }

/* =========================================================
   Badges / status — status dots now read like real panel LEDs:
   a bright core, a dark rim, and a soft bleed of light around them.
   ========================================================= */
.badge {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  font-family: var(--font-mono);
  font-size: 11px;
  font-weight: 600;
  letter-spacing: 0.02em;
  padding: 4px 9px;
  border-radius: var(--radius-pill);
  border: 1px solid var(--border-strong);
  color: var(--text-secondary);
  background: var(--bg-panel-raised);
  white-space: nowrap;
}
.badge-ok { color: var(--ok); border-color: rgba(74, 222, 128, 0.35); background: var(--ok-dim); }
.badge-warn { color: var(--warn); border-color: rgba(245, 197, 24, 0.35); background: var(--warn-dim); }
.badge-danger { color: var(--danger); border-color: rgba(242, 73, 92, 0.35); background: var(--danger-dim); }
.badge-muted { color: var(--text-muted); }

.status-dot {
  display: inline-block;
  width: 8px; height: 8px;
  border-radius: 50%;
  margin-right: 6px;
  background: radial-gradient(circle at 35% 30%, #8a8070, var(--text-muted) 75%);
  flex-shrink: 0;
}
.status-dot.ok { background: radial-gradient(circle at 35% 30%, #a6f5c2, var(--ok) 70%); box-shadow: 0 0 0 3px var(--ok-dim); }
.status-dot.warn { background: radial-gradient(circle at 35% 30%, #fbe38a, var(--warn) 70%); box-shadow: 0 0 0 3px var(--warn-dim); }
.status-dot.danger { background: radial-gradient(circle at 35% 30%, #f9aeb8, var(--danger) 70%); box-shadow: 0 0 0 3px var(--danger-dim); }
.status-dot.live { animation: pulse-dot 2s ease-in-out infinite; }

@media (prefers-reduced-motion: no-preference) {
  @keyframes pulse-dot {
    0%, 100% { box-shadow: 0 0 0 0 var(--ok-dim); }
    50% { box-shadow: 0 0 0 4px var(--ok-dim); }
  }
}

.pill {
  display: inline-flex;
  align-items: center;
  gap: 8px;
  background: var(--bg-panel-raised);
  border: 1px solid var(--border-subtle);
  border-radius: var(--radius);
  padding: 6px 10px;
  font-size: 12px;
}
.pill form { margin: 0; }

/* =========================================================
   Tables
   ========================================================= */
.table-wrap { overflow-x: auto; }
table.data-table {
  width: 100%;
  border-collapse: collapse;
  font-size: 13.5px;
}
table.data-table thead th {
  text-align: left;
  padding: 12px 18px;
  font-family: var(--font-mono);
  font-size: 10.5px;
  letter-spacing: 0.08em;
  text-transform: uppercase;
  color: var(--text-muted);
  border-bottom: 1px solid var(--border-subtle);
  background: rgba(255,255,255,0.015);
  white-space: nowrap;
}
table.data-table tbody td {
  padding: 12px 18px;
  border-bottom: 1px solid var(--border-subtle);
  color: var(--text-secondary);
  vertical-align: middle;
}
table.data-table tbody tr:last-child td { border-bottom: none; }
table.data-table tbody tr:hover { background: rgba(255,255,255,0.015); }
table.data-table td.primary { color: var(--text-primary); }
table.data-table td.actions form { display: inline; }

.table-actions { display: flex; gap: 6px; flex-wrap: wrap; }

.empty-state {
  padding: 40px 20px;
  text-align: center;
  color: var(--text-muted);
  font-size: 13.5px;
}
.empty-state strong { color: var(--text-secondary); display: block; margin-bottom: 4px; font-size: 14px; }

/* =========================================================
   Forms (setup/login + module forms)
   ========================================================= */
.auth-shell {
  min-height: 100vh;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 24px;
  position: relative;
}

.auth-brand {
  display: flex;
  align-items: center;
  gap: 12px;
  justify-content: center;
  margin-bottom: 22px;
}

.auth-card {
  width: 100%;
  max-width: 400px;
  background: var(--bg-panel);
  border: 1px solid var(--border-subtle);
  border-radius: var(--radius-lg);
  padding: 34px 32px;
  box-shadow: var(--shadow-pop);
}

.auth-card h1 { font-family: var(--font-display); font-size: 24px; margin: 0 0 4px; text-align: center; text-transform: uppercase; }
.auth-card p.sub { color: var(--text-muted); font-size: 13px; margin: 0 0 24px; text-align: center; }

.field { margin-bottom: 16px; }
.field label { display: block; font-size: 12.5px; color: var(--text-secondary); margin-bottom: 6px; font-weight: 500; }
.field-inline { display: flex; align-items: center; gap: 8px; margin: 0; }
.field-row { display: flex; gap: 8px; align-items: flex-end; flex-wrap: wrap; }

.field input[type="text"],
.field input[type="email"],
.field input[type="password"],
.field input[type="number"],
.field input:not([type]),
.field select,
.field textarea {
  width: 100%;
  background: var(--bg-void);
  border: 1px solid var(--border-strong);
  border-radius: var(--radius);
  padding: 10px 12px;
  color: var(--text-primary);
  font-size: 14px;
  font-family: var(--font-body);
}
.field textarea { font-family: var(--font-mono); font-size: 13px; resize: vertical; }
.field input:focus, .field select:focus, .field textarea:focus {
  outline: none;
  border-color: var(--data);
  box-shadow: 0 0 0 3px var(--data-dim);
}
.field input[type="checkbox"] { width: auto; accent-color: var(--accent); }

.form-errors { color: var(--danger); font-size: 12.5px; margin-top: 4px; }

.flash {
  padding: 11px 14px;
  border-radius: var(--radius);
  font-size: 13px;
  margin-bottom: 14px;
  border: 1px solid var(--border-subtle);
  background: var(--bg-panel-raised);
}
.flash-error { border-color: var(--danger); color: var(--danger); background: var(--danger-dim); }
.flash-success { border-color: var(--ok); color: var(--ok); background: var(--ok-dim); }
.flash-info { border-color: var(--border-strong); color: var(--text-secondary); }

/* =========================================================
   Log / console panes
   ========================================================= */
.console-pane {
  margin: 0;
  padding: 16px 18px;
  font-size: 12.5px;
  line-height: 1.65;
  white-space: pre-wrap;
  word-break: break-all;
  overflow-y: auto;
  color: var(--text-secondary);
}

/* =========================================================
   Log tabs (Logs page)
   ========================================================= */
.tab-row { display: flex; gap: 6px; flex-wrap: wrap; }
.tab-link {
  font-family: var(--font-mono);
  font-size: 11.5px;
  padding: 7px 13px;
  border-radius: var(--radius);
  border: 1px solid var(--border-strong);
  color: var(--text-muted);
}
.tab-link:hover { color: var(--text-primary); }
.tab-link.active { background: var(--bg-panel-raised); color: var(--text-primary); border-color: var(--accent); }

/* =========================================================
   Modals (systemctl create — editor)
   ========================================================= */
.modal-overlay {
  display: none; position: fixed; inset: 0; background: rgba(8,6,4,0.75);
  z-index: 100; align-items: center; justify-content: center; padding: 24px;
  backdrop-filter: blur(2px);
}
.modal-overlay.open { display: flex; }
.modal-box {
  background: var(--bg-panel); border: 1px solid var(--border-subtle); border-radius: var(--radius-lg);
  width: 100%; display: flex; flex-direction: column; overflow: hidden;
  box-shadow: var(--shadow-pop);
}
.modal-browse { max-width: 520px; max-height: 70vh; }
.modal-editor { max-width: 980px; height: 82vh; }
.modal-header {
  display:flex; justify-content:space-between; align-items:center;
  padding: 14px 18px; border-bottom: 1px solid var(--border-subtle);
}
.modal-header h3 { margin: 0; font-size: 14px; font-family: var(--font-mono); }
.modal-close { background:none; border:none; color: var(--text-muted); font-size: 18px; cursor:pointer; line-height:1; }
.modal-close:hover { color: var(--text-primary); }

.browse-list { overflow-y: auto; flex: 1; padding: 6px; }
.browse-item {
  display:flex; align-items:center; gap:8px; padding: 8px 10px; border-radius: var(--radius-sm);
  cursor: pointer; font-size: 13px; color: var(--text-secondary);
}
.browse-item:hover { background: var(--bg-panel-hover); color: var(--text-primary); }
.browse-item .icon { width: 16px; text-align:center; color: var(--text-muted); }

#monaco-container { flex: 1; min-height: 0; }
.editor-footer { padding: 10px 18px; border-top: 1px solid var(--border-subtle); display:flex; justify-content:flex-end; gap:8px; align-items:center; }
.editor-save-status { font-size: 12px; color: var(--text-muted); margin-right: auto; }

.detect-row { display:flex; gap:8px; align-items:flex-end; margin-bottom: 16px; }
.detect-hint { font-size: 12.5px; color: var(--text-muted); margin-top: 6px; }
.detect-hint.found { color: var(--ok); }

/* =========================================================
   Responsive
   ========================================================= */
@media (max-width: 880px) {
  .app-shell { flex-direction: column; }
  .sidebar { width: 100%; height: auto; position: relative; flex-direction: row; flex-wrap: wrap; padding: 14px; }
  .brand { border-bottom: none; padding-bottom: 8px; margin-bottom: 0; width: 100%; }
  .brand::after { display: none; }
  .nav-link::after { display: none; }
  .sidebar-footer { margin-top: 0; padding-top: 8px; border-top: none; width: 100%; }
  .main { padding: 22px 18px 40px; }
  .grid-2 { grid-template-columns: 1fr; }
}

/* =========================================================
   THEME: Compact / Data-Dense
   Applied via [data-theme="compact"] on <html>. Reuses every
   existing component class (.card, .data-table, .btn, .badge,
   .nav-link, .page-title, ...) so any page built with the shared
   component set re-skins automatically — no per-page markup needed.
   Direction: tighter rack unit, higher information density, a
   floating console panel rather than an edge-to-edge cabinet.
   ========================================================= */
[data-theme="compact"] {
  --bg-void: #0b0c10;
  --bg-panel: #14161c;
  --bg-panel-raised: #1b1e26;
  --bg-panel-hover: #232733;
  --border-subtle: #262a35;
  --border-strong: #383e4d;

  --accent: #ff7a1a;
  --accent-deep: #c9600f;
  --accent-dim: rgba(255, 122, 26, 0.14);
  --accent-ink: #2c1300;
  --data: #38bdf8;
  --data-dim: rgba(56, 189, 248, 0.14);

  --text-primary: #eef1f7;
  --text-secondary: #9198a8;
  --text-muted: #5c6376;

  --radius-sm: 3px;
  --radius: 4px;
  --radius-lg: 6px;
  --radius-xl: 7px;
}

[data-theme="compact"] body {
  background-image:
    radial-gradient(ellipse 1100px 600px at 50% -12%, rgba(56, 189, 248, 0.05), transparent 55%);
  padding: 14px;
}

/* Floating console shell instead of edge-to-edge cabinet */
[data-theme="compact"] .app-shell {
  gap: 14px;
  max-width: 1760px;
  margin: 0 auto;
}
[data-theme="compact"] .sidebar {
  width: 216px;
  border: 1px solid var(--border-subtle);
  border-radius: var(--radius-xl);
  height: calc(100vh - 28px);
  top: 14px;
  padding: 16px 10px 12px;
  background: var(--bg-panel);
}
[data-theme="compact"] .brand { padding: 4px 6px 14px; margin-bottom: 6px; }
[data-theme="compact"] .brand::after { display: none; }
[data-theme="compact"] .brand-mark { width: 30px; height: 30px; font-size: 13px; }
[data-theme="compact"] .brand-text .brand-name { font-size: 15px; }
[data-theme="compact"] .brand-text .brand-sub { font-size: 8.5px; }

[data-theme="compact"] .nav-link { padding: 7px 10px; font-size: 12.5px; }
[data-theme="compact"] .nav-link::after { content: none; }
[data-theme="compact"] .nav-link.active { box-shadow: none; border-left: 2px solid var(--accent); background: var(--bg-panel-raised); }

[data-theme="compact"] .main {
  padding: 14px 22px 40px;
  max-width: none;
  counter-reset: none;
}

/* Breadcrumb-style page header: SYSTEM / SERVICES on one compact line */
[data-theme="compact"] .topbar { margin-bottom: 18px; padding-bottom: 14px; align-items: center; }
[data-theme="compact"] .page-eyebrow {
  display: inline;
  font-size: 11px;
  color: var(--text-muted);
  margin: 0;
}
[data-theme="compact"] .page-eyebrow::after { content: " / "; color: var(--text-muted); }
[data-theme="compact"] .page-title {
  display: inline;
  font-family: var(--font-body);
  font-size: 13px;
  font-weight: 700;
  letter-spacing: 0.02em;
  text-transform: uppercase;
  vertical-align: middle;
}
[data-theme="compact"] .page-sub { display: block; font-size: 12px; margin-top: 3px; }

[data-theme="compact"] .btn, [data-theme="compact"] .btn-primary,
[data-theme="compact"] .btn-secondary, [data-theme="compact"] .btn-danger,
[data-theme="compact"] .btn-ghost {
  padding: 7px 13px;
  font-size: 12px;
  border-radius: var(--radius-sm);
}

/* Cards: drop the rack-unit rivet/stamp ornaments for a cleaner dense grid */
[data-theme="compact"] .card { padding: 14px 16px 13px; border-radius: var(--radius); }
[data-theme="compact"] .card::before, [data-theme="compact"] .card::after { display: none; }
[data-theme="compact"] .card-value { font-size: 22px; }
[data-theme="compact"] .grid { gap: 10px; }

/* Tables: the core of the "data dense" read — tight rows, small type */
[data-theme="compact"] table.data-table { font-size: 12.5px; }
[data-theme="compact"] table.data-table thead th { padding: 8px 14px; font-size: 10px; }
[data-theme="compact"] table.data-table tbody td { padding: 7px 14px; }

[data-theme="compact"] .badge { padding: 2px 7px; font-size: 10px; }
[data-theme="compact"] .status-dot { width: 6px; height: 6px; }

[data-theme="compact"] .modal-box,
[data-theme="compact"] .auth-card { border-radius: var(--radius-lg); }

@media (max-width: 880px) {
  [data-theme="compact"] body { padding: 0; }
  [data-theme="compact"] .sidebar { height: auto; top: 0; border-radius: 0; }
}

/* =========================================================
   Theme switcher control (Settings → Appearance)
   ========================================================= */
.theme-picker { display: grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); gap: 16px; }
.theme-option {
  position: relative;
  display: block;
  cursor: pointer;
  border: 1px solid var(--border-subtle);
  border-radius: var(--radius-lg);
  padding: 14px;
  background: var(--bg-panel-raised);
  transition: border-color 0.12s ease, background 0.12s ease;
}
.theme-option:hover { border-color: var(--border-strong); }
.theme-option input { position: absolute; opacity: 0; pointer-events: none; }
.theme-option.selected { border-color: var(--accent); background: var(--accent-dim); }

.theme-preview {
  display: flex;
  gap: 5px;
  height: 92px;
  border-radius: var(--radius);
  overflow: hidden;
  border: 1px solid var(--border-subtle);
  margin-bottom: 12px;
  background: #100f0d;
  padding: 6px;
}
.theme-preview .tp-side { width: 26%; border-radius: 3px; background: #18160f; }
.theme-preview .tp-main { flex: 1; border-radius: 3px; background: #211e17; padding: 6px; display: flex; flex-direction: column; gap: 4px; }
.theme-preview .tp-bar { height: 6px; border-radius: 2px; background: #ff8a3d; width: 40%; }
.theme-preview .tp-row { height: 5px; border-radius: 2px; background: #2c2820; }
.theme-preview .tp-row:nth-child(3) { width: 92%; }
.theme-preview .tp-row:nth-child(4) { width: 78%; }
.theme-preview .tp-row:nth-child(5) { width: 85%; }

.theme-preview.compact { padding: 4px; background: #0b0c10; }
.theme-preview.compact .tp-side { background: #14161c; border-radius: 5px; width: 24%; }
.theme-preview.compact .tp-main { background: transparent; padding: 3px; gap: 3px; }
.theme-preview.compact .tp-bar { background: #ff7a1a; height: 5px; width: 55%; }
.theme-preview.compact .tp-row { height: 3px; background: #1b1e26; border-radius: 1px; }

.theme-option-label { display: flex; align-items: center; justify-content: space-between; gap: 8px; }
.theme-option-name { font-weight: 600; font-size: 13.5px; color: var(--text-primary); }
.theme-option-desc { font-size: 12px; color: var(--text-muted); margin-top: 2px; }
.theme-option-check {
  width: 17px; height: 17px; border-radius: 50%;
  border: 1px solid var(--border-strong);
  flex-shrink: 0;
  display: flex; align-items: center; justify-content: center;
}
.theme-option.selected .theme-option-check { border-color: var(--accent); background: var(--accent); }
.theme-option.selected .theme-option-check::after {
  content: ""; width: 7px; height: 7px; border-radius: 50%; background: #1a1207;
}
CSS_EOF

cat > "$APP_DIR/static/js/theme.js" <<'JS_EOF'
/* OpsLab theme engine
 * Two themes: "modern" (default, rack-gear dark) and "compact" (data-dense).
 * Persisted client-side in localStorage so the choice sticks across pages
 * and sessions without needing a server round trip. If the panel later
 * gains a per-user "theme" column, swap localStorage for a fetch() to a
 * /settings/theme endpoint in setTheme() below — applyStoredTheme() runs
 * from an inline <head> script (see base.html) so there is no flash of
 * the wrong theme on load.
 */
(function (window, document) {
  var STORAGE_KEY = 'opslab-theme';
  var VALID = ['modern', 'compact'];

  function getStoredTheme() {
    try {
      var t = window.localStorage.getItem(STORAGE_KEY);
      return VALID.indexOf(t) !== -1 ? t : 'modern';
    } catch (e) {
      return 'modern';
    }
  }

  function applyStoredTheme() {
    var t = getStoredTheme();
    if (t === 'modern') {
      document.documentElement.removeAttribute('data-theme');
    } else {
      document.documentElement.setAttribute('data-theme', t);
    }
    return t;
  }

  function setTheme(theme) {
    if (VALID.indexOf(theme) === -1) return;
    try { window.localStorage.setItem(STORAGE_KEY, theme); } catch (e) {}
    applyStoredTheme();
    document.dispatchEvent(new CustomEvent('opslab-theme-changed', { detail: { theme: theme } }));
  }

  window.OpsLabTheme = {
    get: getStoredTheme,
    set: setTheme,
    apply: applyStoredTheme,
    THEMES: [
      { id: 'modern', name: 'Modern Dark', desc: 'Rack-gear cabinet, full detail, spacious layout.' },
      { id: 'compact', name: 'Compact / Data-Dense', desc: 'Tighter rows, breadcrumb headers, more on screen.' }
    ]
  };
})(window, document);
JS_EOF

echo "Wrote templates/base.html, static/css/style.css, static/js/theme.js"

# --- patch app.py (exact string match on your real file, not a guess) -------
if grep -q "modules.settings.routes" "$APP_DIR/app.py"; then
  echo "app.py already wires up modules.settings.routes — leaving it alone."
else
  python3 - "$APP_DIR/app.py" <<'PYEOF'
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    content = f.read()

import_anchor = "    from modules.dns.routes import dns_bp\n"
register_anchor = "    app.register_blueprint(dns_bp)\n"

if import_anchor not in content or register_anchor not in content:
    print("PATCH_SKIPPED: expected anchor lines not found (app.py may have changed).")
    sys.exit(0)

content = content.replace(
    import_anchor,
    import_anchor + "    from modules.settings.routes import settings_bp\n",
    1,
)
content = content.replace(
    register_anchor,
    register_anchor + "    app.register_blueprint(settings_bp)\n",
    1,
)

with open(path, "w", encoding="utf-8") as f:
    f.write(content)

print("PATCH_APPLIED: app.py now imports and registers settings_bp")
PYEOF
  if [ $? -ne 0 ]; then
    echo "ERROR: patch step failed unexpectedly. Rolling back." >&2
    restore_backup
    exit 1
  fi
fi

if ! grep -q "modules.settings.routes" "$APP_DIR/app.py"; then
  echo "ERROR: app.py could not be patched (anchor lines not found) — this app.py differs from what this script expects." >&2
  echo "Nothing was changed in app.py. Send me the current app.py again and I'll rebuild the patch." >&2
  restore_backup
  exit 1
fi

# --- validate before ever touching the running service -----------------------
if ! python3 -m py_compile "$APP_DIR/app.py"; then
  echo "ERROR: app.py failed to compile after patching. Rolling back." >&2
  restore_backup
  exit 1
fi
if ! python3 -m py_compile "$APP_DIR/modules/settings/routes.py"; then
  echo "ERROR: modules/settings/routes.py failed to compile. Rolling back." >&2
  restore_backup
  exit 1
fi

# --- restart and verify --------------------------------------------------------
echo "Restarting $SERVICE_NAME ..."
systemctl restart "$SERVICE_NAME"
sleep 3

if ! systemctl is-active --quiet "$SERVICE_NAME"; then
  echo "ERROR: $SERVICE_NAME is not active after restart. Rolling back." >&2
  restore_backup
  exit 1
fi

if journalctl -u "$SERVICE_NAME" --since "10 seconds ago" --no-pager 2>/dev/null | grep -qi "Traceback\|BuildError\|Error:"; then
  echo "ERROR: errors found in the service log right after restart. Rolling back." >&2
  journalctl -u "$SERVICE_NAME" --since "10 seconds ago" --no-pager | tail -n 25
  restore_backup
  exit 1
fi

echo
echo "Done. Settings > Appearance is live at /settings/appearance."
echo "Backup of previous files: $BACKUP_DIR"
echo "Manual rollback if you ever need it:"
echo "  cp -r $BACKUP_DIR/* $APP_DIR/ && systemctl restart $SERVICE_NAME"
