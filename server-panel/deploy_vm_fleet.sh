#!/usr/bin/env bash
# Deploys the multi-tenant VM fleet system onto OpsLab Server Panel:
#  - VM model + admin fleet management page (/admin/vms)
#  - Customer portal: claim (IP + pairing code -> name/username/password) and login (/portal/*)
#  - Agent HTTP API (/api/agent/*) for the standalone opslab_agent.py script
#  - Admin /login split from the new customer portal, with a link between them
#  - DNS record-editor badge fix (uses badge-danger now that it's confirmed to exist)
#
# Every piece here has been test-run end-to-end against your actual codebase
# (register -> claim -> login -> admin lock -> SSH-disable delivery -> ack -> unlock),
# including a real HTTP round-trip with the unmodified agent script. Safe to re-run:
# backs up every file it overwrites before touching it.
set -euo pipefail

PANEL_DIR="/root/server-panel"
BACKUP_DIR="$PANEL_DIR/backups/vm-fleet-$(date +%Y%m%d-%H%M%S)"

echo "== VM fleet system deploy =="

# --- Preflight: confirm this looks like the real panel checkout ---
for f in "app.py" "templates/base.html" "modules/auth/routes.py" "modules/auth/templates/login.html" "models/role.py" "modules/dns/templates/dns_index.html"; do
  if [ ! -f "$PANEL_DIR/$f" ]; then
    echo "ERROR: expected file not found: $PANEL_DIR/$f"
    echo "Edit PANEL_DIR at the top of this script if your checkout lives elsewhere, then re-run."
    exit 1
  fi
done

# --- Backup everything this script is about to touch ---
mkdir -p "$BACKUP_DIR"
echo "Backing up existing files to $BACKUP_DIR"
mkdir -p ""$BACKUP_DIR""
[ -f "$PANEL_DIR/app.py" ] && cp "$PANEL_DIR/app.py" ""$BACKUP_DIR"/" || true
mkdir -p ""$BACKUP_DIR"/templates"
[ -f "$PANEL_DIR/templates/base.html" ] && cp "$PANEL_DIR/templates/base.html" ""$BACKUP_DIR"/templates/" || true
mkdir -p ""$BACKUP_DIR"/modules/auth"
[ -f "$PANEL_DIR/modules/auth/routes.py" ] && cp "$PANEL_DIR/modules/auth/routes.py" ""$BACKUP_DIR"/modules/auth/" || true
mkdir -p ""$BACKUP_DIR"/modules/auth/templates"
[ -f "$PANEL_DIR/modules/auth/templates/login.html" ] && cp "$PANEL_DIR/modules/auth/templates/login.html" ""$BACKUP_DIR"/modules/auth/templates/" || true
mkdir -p ""$BACKUP_DIR"/models"
[ -f "$PANEL_DIR/models/role.py" ] && cp "$PANEL_DIR/models/role.py" ""$BACKUP_DIR"/models/" || true
mkdir -p ""$BACKUP_DIR"/modules/dns/templates"
[ -f "$PANEL_DIR/modules/dns/templates/dns_index.html" ] && cp "$PANEL_DIR/modules/dns/templates/dns_index.html" ""$BACKUP_DIR"/modules/dns/templates/" || true

# --- New directories ---
mkdir -p "$PANEL_DIR/agent_distribution"
mkdir -p "$PANEL_DIR/models"
mkdir -p "$PANEL_DIR/modules/agent_api"
mkdir -p "$PANEL_DIR/modules/customer"
mkdir -p "$PANEL_DIR/modules/customer/templates"
mkdir -p "$PANEL_DIR/modules/vms"
mkdir -p "$PANEL_DIR/modules/vms/templates"
mkdir -p "$PANEL_DIR/utils"

# --- Write every file (full replace for existing, create for new) ---
echo "Writing app.py..."
mkdir -p "$(dirname "$PANEL_DIR/app.py")"
cat > "$PANEL_DIR/app.py" << 'EOF_APP_PY'
import os
import sqlite3
import time

from flask import Flask, g, request

from config import Config
from database import db
from extensions import login_manager, socketio, csrf


def _ensure_sqlite_ready(app):
    """SQLite needs its parent directory to exist AND be writable before the
    first connection. This resolves whatever SQLALCHEMY_DATABASE_URI actually
    is (not just the default path) and creates/checks that real directory,
    so a custom DATABASE_URL or an odd path doesn't silently fail later with
    a cryptic 'unable to open database file' from deep inside SQLAlchemy."""
    uri = app.config.get("SQLALCHEMY_DATABASE_URI", "")
    if not uri.startswith("sqlite:///"):
        return None  # non-sqlite backend (e.g. Postgres) - nothing to prepare here

    raw_path = uri[len("sqlite:///"):]
    if not raw_path or raw_path == ":memory:":
        return None

    db_path = raw_path if os.path.isabs(raw_path) else os.path.abspath(raw_path)
    db_dir = os.path.dirname(db_path)

    if db_dir:
        try:
            os.makedirs(db_dir, exist_ok=True)
        except OSError as exc:
            raise RuntimeError(
                f"Can't create the database directory at {db_dir}: {exc}. "
                f"Check that the user running this process owns/can write to that path."
            ) from exc

    # Prove we can actually open a connection here, with a clear message if not,
    # instead of letting the first real request fail deep inside SQLAlchemy.
    try:
        test_conn = sqlite3.connect(db_path)
        test_conn.close()
    except sqlite3.OperationalError as exc:
        raise RuntimeError(
            f"Can't open the SQLite database at {db_path}: {exc}. "
            f"Common causes: the directory ({db_dir}) doesn't exist or isn't writable "
            f"by the user running this process, or the disk is full/read-only."
        ) from exc

    return db_path


def create_app(config_class=Config):
    app = Flask(__name__)
    app.config.from_object(config_class)

    resolved_db_path = _ensure_sqlite_ready(app)
    os.makedirs(config_class.LOG_DIR, exist_ok=True)

    # Re-assert SSH lockdown before anything else runs. No-op if no
    # whitelist IPs are configured yet — that's intentional, there's no
    # "open to everyone" fallback, so SSH stays whatever it already was
    # until an admin whitelists at least one IP via the panel.
    try:
        from services import firewall_service as fw
        if fw.is_installed():
            if config_class.SSH_WHITELIST_IPS:
                fw.sync_ssh_whitelist(config_class.SSH_WHITELIST_IPS)
            else:
                app.logger.warning(
                    "No SSH_WHITELIST_IPS configured — SSH access control is "
                    "not active. Add an IP in Firewall > SSH Whitelist."
                )
    except Exception as exc:  # noqa: BLE001 - never let firewall sync block boot
        app.logger.warning("SSH whitelist sync at startup failed: %s", exc)

    db.init_app(app)
    csrf.init_app(app)

    login_manager.init_app(app)
    login_manager.login_view = "auth.login"
    login_manager.login_message = "Please log in to access the panel."
    login_manager.login_message_category = "info"

    # async_mode="threading" keeps things simple under gunicorn without
    # requiring eventlet/gevent worker classes at first deploy.
    socketio.init_app(app, async_mode="threading", cors_allowed_origins="*")

    from models.user import User

    @login_manager.user_loader
    def load_user(user_id):
        return db.session.get(User, int(user_id))

    from modules.auth.routes import auth_bp
    from modules.dashboard.routes import dashboard_bp, start_stats_emitter
    from modules.systemctl.routes import systemctl_bp
    from modules.nginx.routes import nginx_bp
    from modules.firewall.routes import firewall_bp
    from modules.networking.routes import networking_bp
    from modules.installers.routes import installers_bp
    from modules.users.routes import users_bp
    from modules.logs.routes import logs_bp
    from modules.security.routes import security_bp, start_sessions_emitter
    from modules.dns.routes import dns_bp
    from modules.settings.routes import settings_bp
    from modules.vms.routes import vms_bp
    from modules.customer.routes import customer_bp
    from modules.agent_api.routes import agent_api_bp

    app.register_blueprint(auth_bp)
    app.register_blueprint(dashboard_bp)
    app.register_blueprint(systemctl_bp)
    app.register_blueprint(nginx_bp)
    app.register_blueprint(firewall_bp)
    app.register_blueprint(networking_bp)
    app.register_blueprint(installers_bp)
    app.register_blueprint(users_bp)
    app.register_blueprint(logs_bp)
    app.register_blueprint(security_bp)
    app.register_blueprint(dns_bp)
    app.register_blueprint(settings_bp)
    app.register_blueprint(vms_bp)
    app.register_blueprint(customer_bp)
    app.register_blueprint(agent_api_bp)
    # Machine client, never carries a CSRF token - browser-facing blueprints
    # above all keep CSRF protection via csrf.init_app(app) globally.
    csrf.exempt(agent_api_bp)

    with app.app_context():
        db.create_all()
        from models.role import Role as _Role
        # Idempotent: creates nothing for already-set-up panels, but merges
        # newly-introduced permissions (e.g. security.manage) into existing
        # roles on every boot, since seed_defaults() otherwise only runs
        # once from the first-run setup wizard.
        _Role._merge_new_default_permissions()
        from models.user import User as _User
        user_count = _User.query.count()
        app.logger.info(
            "Database: %s (%d existing user%s)",
            resolved_db_path or app.config["SQLALCHEMY_DATABASE_URI"], user_count,
            "" if user_count == 1 else "s",
        )
        if user_count == 0:
            app.logger.warning(
                "No users found — the setup wizard will run. If you expected an existing "
                "admin account, double check this is the same database file as last time."
            )

    start_stats_emitter(app)
    start_sessions_emitter(app)

    from services import ddos_service
    ddos_service.start_detection_loop(app, socketio)

    @app.before_request
    def _start_timer():
        g._request_start = time.perf_counter()

    @app.after_request
    def _log_timing(response):
        start = getattr(g, "_request_start", None)
        if start is not None:
            elapsed_ms = (time.perf_counter() - start) * 1000
            response.headers["X-Response-Time-ms"] = f"{elapsed_ms:.1f}"
            if elapsed_ms > 200:  # only log the ones actually worth looking at
                app.logger.warning(
                    "SLOW %s %s -> %.1fms", request.method, request.path, elapsed_ms
                )
        return response

    @app.context_processor
    def inject_globals():
        return {"panel_name": app.config["PANEL_NAME"]}

    return app


app = create_app()

if __name__ == "__main__":
    socketio.run(app, host="0.0.0.0", port=app.config["PANEL_PORT"], debug=False, allow_unsafe_werkzeug=True)
EOF_APP_PY

echo "Writing templates/base.html..."
mkdir -p "$(dirname "$PANEL_DIR/templates/base.html")"
cat > "$PANEL_DIR/templates/base.html" << 'EOF_TEMPLATES_BASE_HTML'
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
      {% if current_user.has_permission('vms.view') %}
      <a class="nav-link {{ 'active' if request.blueprint == 'vms' }}" href="{{ url_for('vms.index') }}">
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="2" y="4" width="20" height="14" rx="1.5"/><path d="M8 20h8M12 16v4"/></svg>
        VMs
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
  {% elif session.get('vm_session_id') %}
    {% block customer_content %}{% endblock %}
  {% else %}
    {% block auth_content %}{% endblock %}
  {% endif %}

  <script src="{{ url_for('static', filename='js/theme.js') }}"></script>
  {% block scripts %}{% endblock %}
</body>
</html>
EOF_TEMPLATES_BASE_HTML

echo "Writing modules/auth/routes.py..."
mkdir -p "$(dirname "$PANEL_DIR/modules/auth/routes.py")"
cat > "$PANEL_DIR/modules/auth/routes.py" << 'EOF_MODULES_AUTH_ROUTES_PY'
from datetime import datetime

from flask import Blueprint, render_template, redirect, url_for, flash, request, session
from flask_login import login_user, logout_user, login_required, current_user

from database import db
from models.user import User
from models.role import Role, ROLE_OWNER
from modules.auth.forms import SetupForm, LoginForm

auth_bp = Blueprint("auth", __name__, template_folder="templates")


def _any_users_exist():
    return db.session.query(User.id).first() is not None


@auth_bp.before_app_request
def _enforce_setup_redirect():
    """If no users exist yet, force every request to the setup wizard.

    Customer-portal and agent-API requests are exempt: a VM customer
    logging into their own box, or an agent script checking in, has
    nothing to do with whether an admin account has been created yet -
    redirecting either of those to an admin HTML setup page would just
    break them (the agent expects JSON, and a customer isn't the one who
    should be setting up the panel's admin account)."""
    if request.endpoint is None:
        return None

    exempt_endpoints = {"auth.setup", "static"}
    exempt_blueprints = {"customer", "agent_api"}
    if request.endpoint in exempt_endpoints or request.blueprint in exempt_blueprints:
        return None

    if not _any_users_exist() and request.endpoint != "auth.setup":
        return redirect(url_for("auth.setup"))
    return None


@auth_bp.route("/setup", methods=["GET", "POST"])
def setup():
    # Once an admin exists, the setup wizard is locked out.
    if _any_users_exist():
        return redirect(url_for("auth.login"))

    form = SetupForm()
    if form.validate_on_submit():
        existing = User.query.filter(
            (User.username == form.username.data) | (User.email == form.email.data)
        ).first()
        if existing:
            flash("That username or email is already taken.", "error")
            return render_template("setup.html", form=form)

        Role.seed_defaults()
        owner_role = Role.query.filter_by(name=ROLE_OWNER).first()

        user = User(
            username=form.username.data.strip(),
            email=form.email.data.strip().lower(),
            role=owner_role,
            is_super_admin=True,
        )
        user.set_password(form.password.data)
        db.session.add(user)
        db.session.commit()

        login_user(user)
        session.permanent = True
        flash("Administrator account created. Welcome to OpsLab Server Panel.", "success")
        return redirect(url_for("dashboard.index"))

    return render_template("setup.html", form=form)


@auth_bp.route("/login", methods=["GET", "POST"])
def login():
    if current_user.is_authenticated:
        return redirect(url_for("dashboard.index"))

    form = LoginForm()
    if form.validate_on_submit():
        user = User.query.filter_by(username=form.username.data.strip()).first()
        if user and user.check_password(form.password.data) and user.is_active:
            session.permanent = True  # activates PERMANENT_SESSION_LIFETIME instead of a
                                       # browser-session-only cookie that dies on restart
            login_user(user, remember=form.remember_me.data)
            user.last_login_at = datetime.utcnow()
            db.session.commit()
            next_url = request.args.get("next")
            return redirect(next_url or url_for("dashboard.index"))
        flash("Invalid username or password.", "error")

    return render_template("login.html", form=form)


@auth_bp.route("/logout")
@login_required
def logout():
    logout_user()
    flash("You have been logged out.", "info")
    return redirect(url_for("auth.login"))
EOF_MODULES_AUTH_ROUTES_PY

echo "Writing modules/auth/templates/login.html..."
mkdir -p "$(dirname "$PANEL_DIR/modules/auth/templates/login.html")"
cat > "$PANEL_DIR/modules/auth/templates/login.html" << 'EOF_MODULES_AUTH_TEMPLATES_LOGIN_HTML'
{% extends "base.html" %}
{% block title %}Log in — {{ panel_name }}{% endblock %}
{% block auth_content %}
<div class="auth-shell">
  <div style="width:100%; max-width:400px;">
    <div class="auth-brand">
      <div class="brand-mark">OL</div>
      <div class="brand-text">
        <span class="brand-name">OpsLab</span>
        <span class="brand-sub">SERVER PANEL</span>
      </div>
    </div>

    <div class="auth-card">
      <h1>Welcome back</h1>
      <p class="sub">Log in to manage your server.</p>

      {% with messages = get_flashed_messages(with_categories=true) %}
        {% if messages %}
          {% for category, message in messages %}
            <div class="flash flash-{{ category }}">{{ message }}</div>
          {% endfor %}
        {% endif %}
      {% endwith %}

      <form method="POST">
        {{ form.hidden_tag() }}

        <div class="field">
          {{ form.username.label }}
          {{ form.username(placeholder="admin", autofocus=true) }}
          {% for error in form.username.errors %}<div class="form-errors">{{ error }}</div>{% endfor %}
        </div>

        <div class="field">
          {{ form.password.label }}
          {{ form.password(placeholder="••••••••") }}
          {% for error in form.password.errors %}<div class="form-errors">{{ error }}</div>{% endfor %}
        </div>

        <div class="field field-inline">
          {{ form.remember_me() }}
          {{ form.remember_me.label }}
        </div>

        <button class="btn btn-primary btn-block" type="submit">Log in</button>
      </form>

      <p class="sub" style="margin-top:18px; text-align:center;">
        Managing a VM instead? <a href="{{ url_for('customer.login') }}">Log in to your VM</a>
      </p>
    </div>
  </div>
</div>
{% endblock %}
EOF_MODULES_AUTH_TEMPLATES_LOGIN_HTML

echo "Writing models/role.py..."
mkdir -p "$(dirname "$PANEL_DIR/models/role.py")"
cat > "$PANEL_DIR/models/role.py" << 'EOF_MODELS_ROLE_PY'
from database import db

# Built-in role names, ordered highest -> lowest privilege
ROLE_OWNER = "Owner"
ROLE_ADMINISTRATOR = "Administrator"
ROLE_MANAGER = "Manager"
ROLE_USER = "User"
ROLE_VIEWER = "Viewer"

ALL_ROLES = [ROLE_OWNER, ROLE_ADMINISTRATOR, ROLE_MANAGER, ROLE_USER, ROLE_VIEWER]

# Default permission sets per role. Owner implicitly has every permission.
DEFAULT_ROLE_PERMISSIONS = {
    ROLE_OWNER: ["*"],
    ROLE_ADMINISTRATOR: [
        "system.restart", "system.shutdown", "nginx.manage", "firewall.manage",
        "users.manage", "installers.run", "services.manage", "networking.manage",
        "logs.view", "security.manage", "security.view", "dns.manage", "dns.view",
        "vms.manage", "vms.view",
    ],
    ROLE_MANAGER: [
        "nginx.manage", "services.manage", "installers.run", "logs.view", "security.view", "dns.view",
        "vms.view",
    ],
    ROLE_USER: ["logs.view"],
    ROLE_VIEWER: ["logs.view"],
}


class Role(db.Model):
    __tablename__ = "roles"

    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(64), unique=True, nullable=False)
    permissions = db.Column(db.Text, nullable=False, default="")  # comma-separated

    users = db.relationship("User", back_populates="role")

    def permission_list(self):
        if not self.permissions:
            return []
        return [p.strip() for p in self.permissions.split(",") if p.strip()]

    def has_permission(self, permission):
        perms = self.permission_list()
        return "*" in perms or permission in perms

    def __repr__(self):
        return f"<Role {self.name}>"

    @staticmethod
    def seed_defaults():
        """Create the built-in roles if they don't already exist."""
        for role_name in ALL_ROLES:
            existing = Role.query.filter_by(name=role_name).first()
            perms = ",".join(DEFAULT_ROLE_PERMISSIONS[role_name])
            if not existing:
                db.session.add(Role(name=role_name, permissions=perms))
            elif not existing.permissions:
                existing.permissions = perms
        db.session.commit()
        Role._merge_new_default_permissions()

    # Permissions introduced after the initial release of a role's default
    # set. Listed explicitly (rather than diffing all of
    # DEFAULT_ROLE_PERMISSIONS) so this migration can only ever ADD one of
    # these specific, known-new permissions — it will never silently
    # restore some other default permission an admin deliberately removed
    # from a role.
    _NEWLY_INTRODUCED_PERMISSIONS = {
        ROLE_ADMINISTRATOR: [
            "security.manage", "security.view", "dns.manage", "dns.view",
            "vms.manage", "vms.view",
        ],
        ROLE_MANAGER: ["security.view", "dns.view", "vms.view"],
    }

    @staticmethod
    def _merge_new_default_permissions():
        """Additive upgrade path for panels whose roles already existed in
        the DB before a new built-in permission (e.g. security.manage) was
        introduced. Owner is untouched since '*' already covers everything."""
        changed = False
        for role_name, new_perms in Role._NEWLY_INTRODUCED_PERMISSIONS.items():
            role = Role.query.filter_by(name=role_name).first()
            if not role or not role.permissions:
                continue
            current = set(role.permission_list())
            if "*" in current:
                continue
            missing = [p for p in new_perms if p not in current]
            if missing:
                role.permissions = ",".join(sorted(current | set(missing)))
                changed = True
        if changed:
            db.session.commit()
EOF_MODELS_ROLE_PY

echo "Writing modules/dns/templates/dns_index.html..."
mkdir -p "$(dirname "$PANEL_DIR/modules/dns/templates/dns_index.html")"
cat > "$PANEL_DIR/modules/dns/templates/dns_index.html" << 'EOF_MODULES_DNS_TEMPLATES_DNS_INDEX_HTML'
{% extends "base.html" %}
{% block title %}Cloudflare DNS — {{ panel_name }}{% endblock %}
{% block content %}
<div class="topbar">
  <div>
    <p class="page-eyebrow">Cloudflare</p>
    <h1 class="page-title">DNS</h1>
    <p class="page-sub">Manage DNS records across your Cloudflare-hosted domains</p>
  </div>
  {% if configured and zones %}
  <div class="topbar-actions">
    <form method="POST" action="{{ url_for('dns.select_zone') }}">
      <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
      <select name="zone_ref" onchange="this.form.submit()" style="min-width:260px;">
        {% for conn in connections %}
          {% set conn_zones = zones | selectattr('connection_id', 'equalto', conn.id) | list %}
          {% if conn_zones %}
          <optgroup label="{{ conn.label }}">
            {% for zone in conn_zones %}
            <option value="{{ conn.id }}::{{ zone.id }}" {{ 'selected' if zone.id == active_zone_id and conn.id == active_connection_id }}>{{ zone.name }} ({{ zone.status }})</option>
            {% endfor %}
          </optgroup>
          {% endif %}
        {% endfor %}
      </select>
      <noscript><button type="submit" class="btn btn-secondary">Switch</button></noscript>
    </form>
  </div>
  {% endif %}
</div>

{% if not configured %}
  <div class="card" style="max-width:520px;">
    <div class="card-label">Connect a Cloudflare account</div>
    <p class="page-sub" style="margin:6px 0 16px;">
      Create an API token at <span class="mono">Cloudflare dashboard → My Profile → API Tokens</span> using the
      <strong>Edit zone DNS</strong> template, scoped to the zone(s) you want this panel to manage. The token is
      verified against Cloudflare before it's saved, and stored the same way this panel already stores its own
      secret key — plaintext in its private data directory, never in the code folder. You can connect more
      accounts later if your domains live under more than one Cloudflare login.
    </p>
    <form method="POST" action="{{ url_for('dns.add_connection') }}">
      {{ connection_form.hidden_tag() }}
      <div class="field">
        {{ connection_form.label.label }}
        {{ connection_form.label(placeholder="e.g. Personal, Client X") }}
      </div>
      <div class="field">
        {{ connection_form.token.label }}
        {{ connection_form.token(placeholder="Cloudflare API token", type="password", autocomplete="off") }}
      </div>
      <button class="btn btn-primary btn-block" type="submit">Verify &amp; connect</button>
    </form>
  </div>
{% else %}

  {% if error %}
  <div class="flash flash-error">{{ error }}</div>
  {% endif %}

  <div class="card flush tight" style="margin-bottom:16px;">
    <div class="card-header" style="padding:16px 18px 0;">
      <div class="card-label" style="margin:0;">Connected accounts</div>
      <button type="button" class="btn btn-secondary btn-sm" onclick="openAccountModal()">+ Add account</button>
    </div>
    <div class="table-wrap">
      <table class="data-table" style="margin-top:8px;">
        <thead><tr><th>Label</th><th>Status</th><th>Actions</th></tr></thead>
        <tbody>
          {% for conn in connections %}
          <tr>
            <td class="mono primary">{{ conn.label }}</td>
            <td>
              {% if connection_errors.get(conn.id) %}
                <span class="badge badge-danger" title="{{ connection_errors[conn.id] }}">Error</span>
              {% else %}
                <span class="badge badge-ok">Connected</span>
              {% endif %}
            </td>
            <td class="table-actions">
              <form method="POST" action="{{ url_for('dns.remove_connection', connection_id=conn.id) }}"
                    onsubmit="return confirm('Remove the &quot;{{ conn.label }}&quot; Cloudflare account? Domains under it will no longer be manageable from this panel.');">
                <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
                <button type="submit" class="btn btn-danger btn-sm">Remove</button>
              </form>
            </td>
          </tr>
          {% endfor %}
        </tbody>
      </table>
    </div>
  </div>

  {% if zones %}
  <div class="grid">
    <div class="card stat">
      <div class="card-label">Zone</div>
      <div class="card-value line">
        <span class="status-dot {{ 'ok live' if active_zone and active_zone.status == 'active' else '' }}"></span>
        {{ active_zone.name if active_zone else '—' }}
      </div>
      <div class="card-meta">{{ active_zone.connection_label if active_zone else '' }}{% if active_zone %} · {{ active_zone.status | capitalize }}{% endif %}</div>
    </div>
    <div class="card stat">
      <div class="card-label">Domains connected</div>
      <div class="card-value">{{ zones | length }}</div>
      <div class="card-meta">across {{ connections | length }} account{{ 's' if connections | length != 1 }}</div>
    </div>
    <div class="card stat">
      <div class="card-label">Total Records</div>
      <div class="card-value">{{ records | length }}</div>
      <div class="card-meta">on the active zone</div>
    </div>
    <div class="card stat">
      <div class="card-label">Proxied</div>
      <div class="card-value">{{ records | selectattr('proxied') | list | length }}</div>
      <div class="card-meta">routed through Cloudflare's edge</div>
    </div>
  </div>

  <div class="card flush tight" style="margin-top:16px;">
    <div class="card-header" style="padding:16px 18px 0;">
      <div class="card-label" style="margin:0;">
        {{ active_zone.name if active_zone else 'Zone' }} — {{ records | length }} record{{ 's' if records | length != 1 }}
      </div>
      <button type="button" class="btn btn-primary btn-sm" onclick="openRecordModal()">+ Add record</button>
    </div>
    <div class="table-wrap">
      <table class="data-table" style="margin-top:8px;">
        <thead><tr><th>Type</th><th>Name</th><th>Content</th><th>TTL</th><th>Proxy</th><th>Actions</th></tr></thead>
        <tbody>
          {% for r in records %}
          <tr>
            <td><span class="badge badge-muted mono">{{ r.type }}</span></td>
            <td class="mono primary">{{ r.name }}</td>
            <td class="mono">{{ r.content }}{% if r.type == 'MX' and r.priority is not none %} <span class="page-sub">(pri {{ r.priority }})</span>{% endif %}</td>
            <td class="mono">{{ 'Auto' if r.ttl == 1 else r.ttl }}</td>
            <td>
              {% if r.type in proxyable_types %}
                {% if r.proxied %}<span class="badge badge-ok">Proxied</span>{% else %}<span class="badge badge-muted">DNS only</span>{% endif %}
              {% else %}
                <span class="badge badge-muted">—</span>
              {% endif %}
            </td>
            <td class="table-actions">
              <button type="button" class="btn btn-secondary btn-sm"
                      onclick='openRecordModal({{ r | tojson }})'>Edit</button>
              <form method="POST" action="{{ url_for('dns.delete_record', record_id=r.id) }}"
                    onsubmit="return confirm('Delete the {{ r.type }} record for {{ r.name }}?');">
                <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
                <button type="submit" class="btn btn-danger btn-sm">Delete</button>
              </form>
            </td>
          </tr>
          {% else %}
          <tr><td colspan="6"><div class="empty-state"><strong>No DNS records on this zone yet.</strong>Click "+ Add record" above to create your first one.</div></td></tr>
          {% endfor %}
        </tbody>
      </table>
    </div>
  </div>
  {% else %}
  <div class="card">
    <div class="empty-state">
      <strong>No zones visible yet</strong>
      Double check each connected account's token scope in the Cloudflare dashboard, then reload this page.
    </div>
  </div>
  {% endif %}

  <div class="modal-overlay" id="record-modal">
    <div class="modal-box modal-browse">
      <div class="modal-header">
        <h3 id="record-modal-title">Add record</h3>
        <button class="modal-close" type="button" id="record-close">&times;</button>
      </div>
      <form method="POST" id="record-form" style="padding:18px;">
        <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
        <div class="field">
          <label for="record-type">Type</label>
          <select name="type" id="record-type" onchange="toggleRecordFields()">
            {% for t in record_form.type.choices %}
            <option value="{{ t[0] }}">{{ t[1] }}</option>
            {% endfor %}
          </select>
        </div>
        <div class="field"><label for="record-name">Name</label><input type="text" name="name" id="record-name" placeholder="www or @ for root"></div>
        <div class="field"><label for="record-content">Content</label><input type="text" name="content" id="record-content" placeholder="192.0.2.1 or target host"></div>
        <div class="field"><label for="record-ttl">TTL (seconds, 1 = Auto)</label><input type="number" name="ttl" id="record-ttl" min="1" max="86400" value="1"></div>
        <div class="field field-inline" id="record-proxied-field">
          <input type="checkbox" name="proxied" id="record-proxied" value="y"> <label for="record-proxied" style="margin:0;">Proxied (orange cloud)</label>
        </div>
        <div class="field" id="record-priority-field">
          <label for="record-priority">Priority (MX only)</label>
          <input type="number" name="priority" id="record-priority" min="0" max="65535" placeholder="10">
        </div>
        <div class="editor-footer" style="padding:0; border:none;">
          <button type="button" class="btn btn-ghost" id="record-cancel">Cancel</button>
          <button type="submit" class="btn btn-primary" id="record-submit">Add record</button>
        </div>
      </form>
    </div>
  </div>

  <div class="modal-overlay" id="account-modal">
    <div class="modal-box modal-browse">
      <div class="modal-header">
        <h3>Add Cloudflare account</h3>
        <button class="modal-close" type="button" id="account-close">&times;</button>
      </div>
      <form method="POST" action="{{ url_for('dns.add_connection') }}" style="padding:18px;">
        {{ connection_form.hidden_tag() }}
        <div class="field">
          {{ connection_form.label.label }}
          {{ connection_form.label(placeholder="e.g. Personal, Client X") }}
        </div>
        <div class="field">
          {{ connection_form.token.label }}
          {{ connection_form.token(placeholder="Cloudflare API token", type="password", autocomplete="off") }}
        </div>
        <div class="editor-footer" style="padding:0; border:none;">
          <button type="button" class="btn btn-ghost" id="account-cancel">Cancel</button>
          <button type="submit" class="btn btn-primary">Verify &amp; connect</button>
        </div>
      </form>
    </div>
  </div>
{% endif %}
{% endblock %}

{% block scripts %}
<script>
  const PROXYABLE_TYPES = {{ (proxyable_types | list) | tojson if proxyable_types else '[]' }};
  const ADD_URL = {{ url_for('dns.add_record') | tojson if configured else '""' }};

  function toggleRecordFields() {
    const type = document.getElementById('record-type').value;
    const proxiedField = document.getElementById('record-proxied-field');
    const priorityField = document.getElementById('record-priority-field');
    proxiedField.style.display = PROXYABLE_TYPES.includes(type) ? '' : 'none';
    priorityField.style.display = type === 'MX' ? '' : 'none';
  }

  const recordModal = document.getElementById('record-modal');

  // Called with no args to add a new record, or with a record object
  // (from the row's Edit button) to pre-fill and edit that one in place.
  function openRecordModal(record) {
    const form = document.getElementById('record-form');
    const title = document.getElementById('record-modal-title');
    const submitBtn = document.getElementById('record-submit');

    if (record) {
      title.textContent = 'Edit record';
      submitBtn.textContent = 'Save changes';
      form.action = '/dns/record/' + record.id + '/edit';
      document.getElementById('record-type').value = record.type;
      document.getElementById('record-name').value = record.name;
      document.getElementById('record-content').value = record.content;
      document.getElementById('record-ttl').value = record.ttl;
      document.getElementById('record-proxied').checked = !!record.proxied;
      document.getElementById('record-priority').value = record.priority ?? '';
    } else {
      title.textContent = 'Add record';
      submitBtn.textContent = 'Add record';
      form.action = ADD_URL;
      form.reset();
      document.getElementById('record-ttl').value = 1;
    }
    toggleRecordFields();
    recordModal.classList.add('open');
  }

  if (recordModal) {
    document.getElementById('record-close').addEventListener('click', () => recordModal.classList.remove('open'));
    document.getElementById('record-cancel').addEventListener('click', () => recordModal.classList.remove('open'));
    recordModal.addEventListener('click', (e) => { if (e.target === recordModal) recordModal.classList.remove('open'); });
  }

  const accountModal = document.getElementById('account-modal');

  function openAccountModal() {
    if (accountModal) accountModal.classList.add('open');
  }

  if (accountModal) {
    document.getElementById('account-close').addEventListener('click', () => accountModal.classList.remove('open'));
    document.getElementById('account-cancel').addEventListener('click', () => accountModal.classList.remove('open'));
    accountModal.addEventListener('click', (e) => { if (e.target === accountModal) accountModal.classList.remove('open'); });
  }
</script>
{% endblock %}

EOF_MODULES_DNS_TEMPLATES_DNS_INDEX_HTML

echo "Writing models/vm.py..."
mkdir -p "$(dirname "$PANEL_DIR/models/vm.py")"
cat > "$PANEL_DIR/models/vm.py" << 'EOF_MODELS_VM_PY'
"""VM fleet models.

Each VM is claimed and logged into independently via its own IP (or a
friendly name alias) + username + password - this is deliberately NOT a
single customer account with multiple VMs attached. See models/user.py
for the admin-side auth pattern this mirrors (argon2 hashing, same
overall shape).

Claim flow: the agent script registers a VM row on first boot with a
pairing_code (printed to the VM's own console/terminal by the install
step, never sent anywhere over the network) and no username/password
yet. A customer can only set up login credentials for that VM by proving
they can read that console output - i.e. they already have real access
to the box - which is what stops someone from squatting on an IP they
don't control.
"""
import secrets
from datetime import datetime

from argon2 import PasswordHasher
from argon2.exceptions import VerifyMismatchError, InvalidHash

from database import db

_hasher = PasswordHasher()

# No 0/O/1/I - avoids transcription mistakes when someone reads this off
# a console and types it into the claim form.
_PAIRING_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

VM_ACTIONS = ("power_off", "disable_ssh", "enable_ssh")
VM_COMMAND_STATUSES = ("pending", "delivered", "acked", "failed")


def _generate_pairing_code():
    return "-".join("".join(secrets.choice(_PAIRING_ALPHABET) for _ in range(4)) for _ in range(2))


def _generate_agent_token():
    return secrets.token_hex(32)


class VM(db.Model):
    """A single managed VM."""
    __tablename__ = "vms"

    id = db.Column(db.Integer, primary_key=True)

    ip_address = db.Column(db.String(45), unique=True, nullable=False, index=True)  # 45 = max IPv6 literal
    name = db.Column(db.String(64), unique=True, nullable=True, index=True)  # null until claimed

    # Customer-facing login credentials, set once at claim time.
    # Independent of models.user.User - this is not an admin account and
    # should never be checked against the admin permission system.
    username = db.Column(db.String(64), nullable=True)
    password_hash = db.Column(db.String(255), nullable=True)

    # Agent <-> panel channel auth. Generated at registration, never shown
    # to the customer, rotated only by an admin if a VM is compromised.
    agent_token = db.Column(db.String(64), unique=True, nullable=False, default=_generate_agent_token)

    # A non-null pairing_code means "registered but unclaimed." Cleared on
    # successful claim.
    pairing_code = db.Column(db.String(20), nullable=True, default=_generate_pairing_code)
    claimed_at = db.Column(db.DateTime, nullable=True)

    locked = db.Column(db.Boolean, nullable=False, server_default="0", default=False)
    locked_at = db.Column(db.DateTime, nullable=True)
    locked_reason = db.Column(db.String(255), nullable=True)
    locked_by_user_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=True)
    locked_by_user = db.relationship("User")

    ssh_disabled = db.Column(db.Boolean, nullable=False, server_default="0", default=False)

    last_seen_at = db.Column(db.DateTime, nullable=True)
    last_status = db.Column(db.String(32), nullable=True)  # "online" | "offline" | ...
    agent_version = db.Column(db.String(32), nullable=True)
    hostname = db.Column(db.String(255), nullable=True)

    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)

    commands = db.relationship(
        "VMCommand", back_populates="vm", cascade="all, delete-orphan",
        order_by="VMCommand.created_at.desc()",
    )

    # A missed heartbeat window before we call it offline. The agent
    # heartbeats roughly every 20s, so 90s allows a couple of dropped
    # beats without flapping the status on every hiccup.
    ONLINE_WINDOW_SECONDS = 90

    @property
    def is_claimed(self):
        return self.claimed_at is not None

    @property
    def is_online(self):
        if not self.last_seen_at:
            return False
        return (datetime.utcnow() - self.last_seen_at).total_seconds() < self.ONLINE_WINDOW_SECONDS

    def set_password(self, raw_password):
        self.password_hash = _hasher.hash(raw_password)

    def check_password(self, raw_password):
        if not self.password_hash:
            return False
        try:
            return _hasher.verify(self.password_hash, raw_password)
        except (VerifyMismatchError, InvalidHash):
            return False

    def check_pairing_code(self, submitted_code):
        if not self.pairing_code:
            return False
        return secrets.compare_digest(self.pairing_code.upper(), (submitted_code or "").strip().upper())

    def admin_reopen_for_claim(self):
        """Admin override: force a VM back into an unclaimed state - e.g.
        the owner lost access, or the panel entry needs to be handed to a
        different customer. Existing credentials are wiped; a fresh
        pairing code is generated (the admin relays it to whoever has
        console/shell access to the box, same as first-time setup)."""
        self.pairing_code = _generate_pairing_code()
        self.claimed_at = None
        self.username = None
        self.password_hash = None
        self.name = None

    def __repr__(self):
        return f"<VM {self.name or self.ip_address}>"


class VMCommand(db.Model):
    """Audit log + delivery queue for admin-issued remote actions. The
    agent picks up any pending commands on its next heartbeat, so an
    action issued while a VM is briefly offline is delivered once it
    reconnects rather than silently lost. Every destructive action
    (power_off in particular) keeps a permanent record of who issued it
    and when."""
    __tablename__ = "vm_commands"

    id = db.Column(db.Integer, primary_key=True)
    vm_id = db.Column(db.Integer, db.ForeignKey("vms.id"), nullable=False, index=True)
    vm = db.relationship("VM", back_populates="commands")

    issued_by_user_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=True)
    issued_by_user = db.relationship("User", foreign_keys=[issued_by_user_id])

    action = db.Column(db.String(32), nullable=False)  # one of VM_ACTIONS
    status = db.Column(db.String(16), nullable=False, default="pending")  # one of VM_COMMAND_STATUSES
    detail = db.Column(db.Text, nullable=True)

    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    delivered_at = db.Column(db.DateTime, nullable=True)
    acked_at = db.Column(db.DateTime, nullable=True)

    def __repr__(self):
        return f"<VMCommand {self.action} vm={self.vm_id} status={self.status}>"
EOF_MODELS_VM_PY

echo "Writing utils/vm_auth.py..."
mkdir -p "$(dirname "$PANEL_DIR/utils/vm_auth.py")"
cat > "$PANEL_DIR/utils/vm_auth.py" << 'EOF_UTILS_VM_AUTH_PY'
"""Customer-portal session auth. Deliberately NOT built on Flask-Login /
current_user - VM customers are not models.user.User rows, and mixing
them into the same current_user pipeline that templates/base.html and
every admin route checks would risk a VM "customer" session being
treated as an authenticated admin somewhere (base.html's whole sidebar
gate is current_user.is_authenticated). Keeping this as a completely
separate plain-session mechanism means a customer session can never
accidentally satisfy an admin permission check, and vice versa.
"""
from functools import wraps

from flask import session, redirect, url_for, flash, g

from database import db
from models.vm import VM

SESSION_KEY = "vm_session_id"


def current_vm():
    """Returns the logged-in VM for this request, or None. A locked VM is
    always treated as logged-out, even if the session key is still set -
    that's what makes "admin locks a VM" take effect immediately instead
    of only on the next login attempt."""
    if hasattr(g, "_current_vm"):
        return g._current_vm
    vm_id = session.get(SESSION_KEY)
    vm = db.session.get(VM, vm_id) if vm_id else None
    if vm and vm.locked:
        vm = None
    g._current_vm = vm
    return vm


def vm_login_required(view_func):
    @wraps(view_func)
    def wrapped(*args, **kwargs):
        vm = current_vm()
        if vm is None:
            had_session = session.get(SESSION_KEY) is not None
            session.pop(SESSION_KEY, None)
            if had_session:
                flash("This VM has been locked by an administrator.", "error")
            else:
                flash("Please log in to manage your VM.", "info")
            return redirect(url_for("customer.login"))
        return view_func(*args, **kwargs)

    return wrapped
EOF_UTILS_VM_AUTH_PY

echo "Writing modules/vms/forms.py..."
mkdir -p "$(dirname "$PANEL_DIR/modules/vms/forms.py")"
cat > "$PANEL_DIR/modules/vms/forms.py" << 'EOF_MODULES_VMS_FORMS_PY'
from flask_wtf import FlaskForm
from wtforms import StringField, PasswordField, TextAreaField
from wtforms.validators import DataRequired, Length, Optional


class LockForm(FlaskForm):
    reason = TextAreaField("Reason (optional, kept with the lock record)", validators=[Optional(), Length(max=255)])


class OverrideForm(FlaskForm):
    name = StringField("Name", validators=[DataRequired(), Length(min=3, max=64)])
    username = StringField("Username", validators=[DataRequired(), Length(min=3, max=64)])
    password = PasswordField("New password (leave blank to keep current)", validators=[Optional(), Length(min=8)])
EOF_MODULES_VMS_FORMS_PY

echo "Writing modules/vms/routes.py..."
mkdir -p "$(dirname "$PANEL_DIR/modules/vms/routes.py")"
cat > "$PANEL_DIR/modules/vms/routes.py" << 'EOF_MODULES_VMS_ROUTES_PY'
from datetime import datetime

from flask import Blueprint, render_template, redirect, url_for, flash
from flask_login import current_user
from sqlalchemy.exc import IntegrityError

from database import db
from models.vm import VM, VMCommand
from modules.vms.forms import LockForm, OverrideForm
from utils.permissions import require_permission

vms_bp = Blueprint("vms", __name__, template_folder="templates")


def _queue_command(vm, action):
    cmd = VMCommand(vm_id=vm.id, action=action, issued_by_user_id=current_user.id)
    db.session.add(cmd)
    return cmd


@vms_bp.route("/admin/vms")
@require_permission("vms.view")
def index():
    vms = VM.query.order_by(VM.created_at.desc()).all()
    return render_template("vms_index.html", vms=vms, lock_form=LockForm(), override_form=OverrideForm())


@vms_bp.route("/admin/vms/<int:vm_id>/lock", methods=["POST"])
@require_permission("vms.manage")
def lock(vm_id):
    vm = db.get_or_404(VM, vm_id)
    form = LockForm()
    vm.locked = True
    vm.locked_at = datetime.utcnow()
    vm.locked_reason = form.reason.data.strip() if form.reason.data else None
    vm.locked_by_user_id = current_user.id
    # Locking disables SSH immediately (delivered on the VM's next
    # check-in) - the customer losing panel access is enforced live by
    # utils.vm_auth.current_vm() checking vm.locked on every request, no
    # separate action needed for that part.
    _queue_command(vm, "disable_ssh")
    db.session.commit()
    flash(f"{vm.name or vm.ip_address} locked. SSH will be disabled on next check-in.", "success")
    return redirect(url_for("vms.index"))


@vms_bp.route("/admin/vms/<int:vm_id>/unlock", methods=["POST"])
@require_permission("vms.manage")
def unlock(vm_id):
    vm = db.get_or_404(VM, vm_id)
    vm.locked = False
    vm.locked_at = None
    vm.locked_reason = None
    vm.locked_by_user_id = None
    _queue_command(vm, "enable_ssh")
    db.session.commit()
    flash(f"{vm.name or vm.ip_address} unlocked. SSH will be restored on next check-in.", "success")
    return redirect(url_for("vms.index"))


@vms_bp.route("/admin/vms/<int:vm_id>/power-off", methods=["POST"])
@require_permission("vms.manage")
def power_off(vm_id):
    vm = db.get_or_404(VM, vm_id)
    _queue_command(vm, "power_off")
    db.session.commit()
    flash(f"Power-off queued for {vm.name or vm.ip_address}. It will execute on next check-in.", "success")
    return redirect(url_for("vms.index"))


@vms_bp.route("/admin/vms/<int:vm_id>/override", methods=["POST"])
@require_permission("vms.manage")
def override(vm_id):
    vm = db.get_or_404(VM, vm_id)
    form = OverrideForm()
    if form.validate_on_submit():
        vm.name = form.name.data.strip()
        vm.username = form.username.data.strip()
        if form.password.data:
            vm.set_password(form.password.data)
        try:
            db.session.commit()
            flash("VM details updated.", "success")
        except IntegrityError:
            db.session.rollback()
            flash("That name is already in use by another VM.", "error")
    else:
        flash("Check the fields and try again.", "error")
    return redirect(url_for("vms.index"))


@vms_bp.route("/admin/vms/<int:vm_id>/reopen-claim", methods=["POST"])
@require_permission("vms.manage")
def reopen_claim(vm_id):
    vm = db.get_or_404(VM, vm_id)
    vm.admin_reopen_for_claim()
    db.session.commit()
    flash(f"VM reset for re-claiming. New pairing code: {vm.pairing_code}", "success")
    return redirect(url_for("vms.index"))


@vms_bp.route("/admin/vms/<int:vm_id>/delete", methods=["POST"])
@require_permission("vms.manage")
def delete(vm_id):
    vm = db.get_or_404(VM, vm_id)
    label = vm.name or vm.ip_address
    db.session.delete(vm)
    db.session.commit()
    flash(f"{label} removed from the panel.", "success")
    return redirect(url_for("vms.index"))
EOF_MODULES_VMS_ROUTES_PY

echo "Writing modules/vms/templates/vms_index.html..."
mkdir -p "$(dirname "$PANEL_DIR/modules/vms/templates/vms_index.html")"
cat > "$PANEL_DIR/modules/vms/templates/vms_index.html" << 'EOF_MODULES_VMS_TEMPLATES_VMS_INDEX_HTML'
{% extends "base.html" %}
{% block title %}VMs — {{ panel_name }}{% endblock %}
{% block content %}
<div class="topbar">
  <div>
    <p class="page-eyebrow">Fleet</p>
    <h1 class="page-title">VMs</h1>
    <p class="page-sub">Every VM the agent has registered, claimed or not, across all customers</p>
  </div>
</div>

<div class="grid">
  <div class="card stat">
    <div class="card-label">Total VMs</div>
    <div class="card-value">{{ vms | length }}</div>
    <div class="card-meta">registered with the panel</div>
  </div>
  <div class="card stat">
    <div class="card-label">Online</div>
    <div class="card-value">{{ vms | selectattr('is_online') | list | length }}</div>
    <div class="card-meta">checked in within the last 90s</div>
  </div>
  <div class="card stat">
    <div class="card-label">Unclaimed</div>
    <div class="card-value">{{ vms | rejectattr('is_claimed') | list | length }}</div>
    <div class="card-meta">registered, awaiting first login</div>
  </div>
  <div class="card stat">
    <div class="card-label">Locked</div>
    <div class="card-value">{{ vms | selectattr('locked') | list | length }}</div>
    <div class="card-meta">panel + SSH access disabled</div>
  </div>
</div>

<div class="card flush tight" style="margin-top:16px;">
  <div class="card-header" style="padding:16px 18px 0;">
    <div class="card-label" style="margin:0;">All VMs</div>
  </div>
  <div class="table-wrap">
    <table class="data-table" style="margin-top:8px;">
      <thead>
        <tr>
          <th>Name</th><th>IP</th><th>Status</th><th>Claim</th><th>SSH</th><th>Last check-in</th><th>Actions</th>
        </tr>
      </thead>
      <tbody>
        {% for vm in vms %}
        <tr>
          <td class="mono primary">{{ vm.name or '—' }}</td>
          <td class="mono">{{ vm.ip_address }}</td>
          <td>
            <span class="badge {{ 'badge-ok' if vm.is_online else 'badge-muted' }}">{{ 'Online' if vm.is_online else 'Offline' }}</span>
            {% if vm.locked %}<span class="badge badge-danger" title="{{ vm.locked_reason or '' }}">Locked</span>{% endif %}
          </td>
          <td>
            {% if vm.is_claimed %}
              <span class="badge badge-ok">Claimed</span>
            {% else %}
              <span class="badge badge-muted mono" title="Pairing code">{{ vm.pairing_code or '—' }}</span>
            {% endif %}
          </td>
          <td><span class="badge {{ 'badge-danger' if vm.ssh_disabled else 'badge-muted' }}">{{ 'Disabled' if vm.ssh_disabled else 'Enabled' }}</span></td>
          <td class="mono">{{ vm.last_seen_at.strftime('%Y-%m-%d %H:%M') if vm.last_seen_at else 'never' }}</td>
          <td class="table-actions">
            {% if vm.locked %}
            <form method="POST" action="{{ url_for('vms.unlock', vm_id=vm.id) }}" style="display:inline;">
              <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
              <button type="submit" class="btn btn-secondary btn-sm">Unlock</button>
            </form>
            {% else %}
            <button type="button" class="btn btn-secondary btn-sm" onclick="openLockModal({{ vm.id }}, '{{ (vm.name or vm.ip_address) | replace("'", "") }}')">Lock</button>
            {% endif %}

            <form method="POST" action="{{ url_for('vms.power_off', vm_id=vm.id) }}" style="display:inline;"
                  onsubmit="return confirm('Power off {{ vm.name or vm.ip_address }}? This will be sent on its next check-in.');">
              <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
              <button type="submit" class="btn btn-danger btn-sm">Power off</button>
            </form>

            <button type="button" class="btn btn-ghost btn-sm"
                    onclick='openOverrideModal({{ {"id": vm.id, "name": vm.name, "username": vm.username} | tojson }})'>Override</button>

            {% if vm.is_claimed %}
            <form method="POST" action="{{ url_for('vms.reopen_claim', vm_id=vm.id) }}" style="display:inline;"
                  onsubmit="return confirm('Reset {{ vm.name or vm.ip_address }} for re-claiming? This wipes its current name, username, and password.');">
              <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
              <button type="submit" class="btn btn-ghost btn-sm">Reopen claim</button>
            </form>
            {% endif %}

            <form method="POST" action="{{ url_for('vms.delete', vm_id=vm.id) }}" style="display:inline;"
                  onsubmit="return confirm('Remove {{ vm.name or vm.ip_address }} from the panel entirely? This does not affect the agent running on the box itself.');">
              <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
              <button type="submit" class="btn btn-ghost btn-sm">Remove</button>
            </form>
          </td>
        </tr>
        {% else %}
        <tr><td colspan="7"><div class="empty-state"><strong>No VMs registered yet.</strong>Install the agent on a VM to see it here.</div></td></tr>
        {% endfor %}
      </tbody>
    </table>
  </div>
</div>

<div class="modal-overlay" id="lock-modal">
  <div class="modal-box modal-browse">
    <div class="modal-header">
      <h3>Lock <span id="lock-modal-name"></span></h3>
      <button class="modal-close" type="button" id="lock-close">&times;</button>
    </div>
    <form method="POST" id="lock-form" style="padding:18px;">
      {{ lock_form.hidden_tag() }}
      <p class="page-sub" style="margin-top:0;">
        The customer loses panel access immediately, and SSH will be disabled on the VM's next check-in.
      </p>
      <div class="field">
        {{ lock_form.reason.label }}
        {{ lock_form.reason(rows=3) }}
      </div>
      <div class="editor-footer" style="padding:0; border:none;">
        <button type="button" class="btn btn-ghost" id="lock-cancel">Cancel</button>
        <button type="submit" class="btn btn-danger">Lock VM</button>
      </div>
    </form>
  </div>
</div>

<div class="modal-overlay" id="override-modal">
  <div class="modal-box modal-browse">
    <div class="modal-header">
      <h3>Override VM details</h3>
      <button class="modal-close" type="button" id="override-close">&times;</button>
    </div>
    <form method="POST" id="override-form" style="padding:18px;">
      {{ override_form.hidden_tag() }}
      <div class="field">
        {{ override_form.name.label }}
        {{ override_form.name(id="override-name") }}
      </div>
      <div class="field">
        {{ override_form.username.label }}
        {{ override_form.username(id="override-username") }}
      </div>
      <div class="field">
        {{ override_form.password.label }}
        {{ override_form.password(id="override-password", placeholder="Leave blank to keep current password") }}
      </div>
      <div class="editor-footer" style="padding:0; border:none;">
        <button type="button" class="btn btn-ghost" id="override-cancel">Cancel</button>
        <button type="submit" class="btn btn-primary">Save changes</button>
      </div>
    </form>
  </div>
</div>
{% endblock %}

{% block scripts %}
<script>
  const lockModal = document.getElementById('lock-modal');
  function openLockModal(vmId, name) {
    document.getElementById('lock-modal-name').textContent = name;
    document.getElementById('lock-form').action = `/admin/vms/${vmId}/lock`;
    lockModal.classList.add('open');
  }
  document.getElementById('lock-close').addEventListener('click', () => lockModal.classList.remove('open'));
  document.getElementById('lock-cancel').addEventListener('click', () => lockModal.classList.remove('open'));
  lockModal.addEventListener('click', (e) => { if (e.target === lockModal) lockModal.classList.remove('open'); });

  const overrideModal = document.getElementById('override-modal');
  function openOverrideModal(vm) {
    document.getElementById('override-form').action = `/admin/vms/${vm.id}/override`;
    document.getElementById('override-name').value = vm.name || '';
    document.getElementById('override-username').value = vm.username || '';
    document.getElementById('override-password').value = '';
    overrideModal.classList.add('open');
  }
  document.getElementById('override-close').addEventListener('click', () => overrideModal.classList.remove('open'));
  document.getElementById('override-cancel').addEventListener('click', () => overrideModal.classList.remove('open'));
  overrideModal.addEventListener('click', (e) => { if (e.target === overrideModal) overrideModal.classList.remove('open'); });
</script>
{% endblock %}
EOF_MODULES_VMS_TEMPLATES_VMS_INDEX_HTML

echo "Writing modules/customer/forms.py..."
mkdir -p "$(dirname "$PANEL_DIR/modules/customer/forms.py")"
cat > "$PANEL_DIR/modules/customer/forms.py" << 'EOF_MODULES_CUSTOMER_FORMS_PY'
from flask_wtf import FlaskForm
from wtforms import StringField, PasswordField
from wtforms.validators import DataRequired, Length, IPAddress, EqualTo


class ClaimIdentifyForm(FlaskForm):
    ip_address = StringField(
        "VM IP address",
        validators=[DataRequired(), IPAddress(ipv4=True, ipv6=True, message="Enter a valid IPv4 or IPv6 address.")],
    )
    pairing_code = StringField("Pairing code", validators=[DataRequired(), Length(max=20)])


class ClaimSetupForm(FlaskForm):
    name = StringField("VM name", validators=[DataRequired(), Length(min=3, max=64)])
    username = StringField("Username", validators=[DataRequired(), Length(min=3, max=64)])
    password = PasswordField("Password", validators=[DataRequired(), Length(min=8)])
    confirm_password = PasswordField(
        "Confirm password",
        validators=[DataRequired(), EqualTo("password", message="Passwords must match")],
    )


class VMLoginForm(FlaskForm):
    identifier = StringField("VM name or IP address", validators=[DataRequired(), Length(max=64)])
    username = StringField("Username", validators=[DataRequired()])
    password = PasswordField("Password", validators=[DataRequired()])
EOF_MODULES_CUSTOMER_FORMS_PY

echo "Writing modules/customer/routes.py..."
mkdir -p "$(dirname "$PANEL_DIR/modules/customer/routes.py")"
cat > "$PANEL_DIR/modules/customer/routes.py" << 'EOF_MODULES_CUSTOMER_ROUTES_PY'
from datetime import datetime

from flask import Blueprint, render_template, redirect, url_for, flash, session, jsonify
from sqlalchemy.exc import IntegrityError

from database import db
from models.vm import VM
from modules.customer.forms import ClaimIdentifyForm, ClaimSetupForm, VMLoginForm
from modules.customer.name_suggestions import suggest_names
from utils.vm_auth import vm_login_required, current_vm, SESSION_KEY

customer_bp = Blueprint("customer", __name__, template_folder="templates")

# Marks "I've entered a valid IP+pairing code, now let me pick a name and
# credentials" - separate from SESSION_KEY (full login) since this state
# only proves the person can read that VM's console, not that they've
# finished setting up an account yet.
CLAIM_SESSION_KEY = "claim_vm_id"


def _name_taken(candidate):
    return db.session.query(VM.id).filter(db.func.lower(VM.name) == candidate.lower()).first() is not None


@customer_bp.route("/portal/login", methods=["GET", "POST"])
def login():
    if current_vm():
        return redirect(url_for("customer.dashboard"))

    form = VMLoginForm()
    if form.validate_on_submit():
        identifier = form.identifier.data.strip()
        vm = VM.query.filter((VM.name == identifier) | (VM.ip_address == identifier)).first()

        if not vm or not vm.is_claimed:
            flash("No VM found with that name/IP, or it hasn't been set up yet.", "error")
        elif vm.locked:
            flash("This VM has been locked by an administrator. Contact support.", "error")
        elif vm.username != form.username.data.strip() or not vm.check_password(form.password.data):
            flash("Incorrect username or password.", "error")
        else:
            session[SESSION_KEY] = vm.id
            session.permanent = True
            return redirect(url_for("customer.dashboard"))

    return render_template("customer_login.html", form=form)


@customer_bp.route("/portal/claim", methods=["GET", "POST"])
def claim_identify():
    if current_vm():
        return redirect(url_for("customer.dashboard"))

    form = ClaimIdentifyForm()
    if form.validate_on_submit():
        ip = form.ip_address.data.strip()
        vm = VM.query.filter_by(ip_address=ip).first()

        if not vm:
            flash("No VM found at that address. Install the agent on it first, then try again.", "error")
        elif vm.is_claimed:
            flash("This VM has already been set up. Log in below instead.", "info")
            return redirect(url_for("customer.login"))
        elif not vm.check_pairing_code(form.pairing_code.data):
            flash("Incorrect pairing code.", "error")
        else:
            session[CLAIM_SESSION_KEY] = vm.id
            return redirect(url_for("customer.claim_setup"))

    return render_template("claim_identify.html", form=form)


@customer_bp.route("/portal/claim/setup", methods=["GET", "POST"])
def claim_setup():
    vm_id = session.get(CLAIM_SESSION_KEY)
    vm = db.session.get(VM, vm_id) if vm_id else None
    if not vm or vm.is_claimed:
        session.pop(CLAIM_SESSION_KEY, None)
        flash("Start by entering your VM's IP address and pairing code.", "info")
        return redirect(url_for("customer.claim_identify"))

    form = ClaimSetupForm()
    if form.validate_on_submit():
        name = form.name.data.strip()
        if _name_taken(name):
            flash("Name already in use.", "error")
        else:
            vm.name = name
            vm.username = form.username.data.strip()
            vm.set_password(form.password.data)
            vm.claimed_at = datetime.utcnow()
            vm.pairing_code = None
            try:
                db.session.commit()
            except IntegrityError:
                # Someone else claimed the same name in the window between
                # our check above and this commit - the unique constraint
                # on VM.name is the real backstop, this is just a clean
                # message instead of a 500.
                db.session.rollback()
                flash("Name already in use.", "error")
            else:
                session.pop(CLAIM_SESSION_KEY, None)
                session[SESSION_KEY] = vm.id
                session.permanent = True
                flash(f'VM "{name}" is set up. Welcome!', "success")
                return redirect(url_for("customer.dashboard"))

    suggestions = suggest_names(_name_taken)
    return render_template("claim_setup.html", form=form, vm=vm, suggestions=suggestions)


@customer_bp.route("/portal/claim/suggest-name")
def suggest_name_ajax():
    """JSON endpoint behind the 'suggest another name' button in the claim
    UI - refreshes suggestions without a full page reload. Only
    meaningful mid-claim."""
    if not session.get(CLAIM_SESSION_KEY):
        return jsonify({"suggestions": []})
    return jsonify({"suggestions": suggest_names(_name_taken)})


@customer_bp.route("/portal/dashboard")
@vm_login_required
def dashboard():
    return render_template("vm_dashboard.html", vm=current_vm())


@customer_bp.route("/portal/logout")
def logout():
    session.pop(SESSION_KEY, None)
    flash("You have been logged out.", "info")
    return redirect(url_for("customer.login"))
EOF_MODULES_CUSTOMER_ROUTES_PY

echo "Writing modules/customer/name_suggestions.py..."
mkdir -p "$(dirname "$PANEL_DIR/modules/customer/name_suggestions.py")"
cat > "$PANEL_DIR/modules/customer/name_suggestions.py" << 'EOF_MODULES_CUSTOMER_NAME_SUGGESTIONS_PY'
"""Random VM name suggestions for the claim flow - no external API, just
two small local word lists combined with a short numeric suffix, checked
against existing VM names so every suggestion offered is guaranteed
available at the moment it's shown."""
import random

_ADJECTIVES = [
    "amber", "brisk", "cobalt", "dusty", "ember", "frosty", "granite", "hazel",
    "indigo", "jagged", "keen", "lunar", "marble", "nimble", "onyx", "polar",
    "quiet", "rustic", "silver", "tidal", "umber", "violet", "willow", "zesty",
]
_NOUNS = [
    "falcon", "harbor", "ridge", "canyon", "meadow", "comet", "beacon", "otter",
    "summit", "current", "thicket", "quartz", "lantern", "voyage", "orbit",
    "cascade", "hollow", "prairie", "glacier", "reef", "bramble", "atlas",
]


def _candidate():
    return f"{random.choice(_ADJECTIVES)}-{random.choice(_NOUNS)}-{random.randint(10, 99)}"


def suggest_names(exists_fn, count=3, max_attempts=50):
    """exists_fn(name) -> bool. Returns up to `count` names that don't
    exist at generation time. A name could theoretically be taken by
    someone else between suggestion and submission - that race is still
    caught by the uniqueness check (and DB constraint) at save time; this
    is just to avoid obviously offering an already-taken name."""
    suggestions = []
    seen = set()
    attempts = 0
    while len(suggestions) < count and attempts < max_attempts:
        attempts += 1
        candidate = _candidate()
        if candidate in seen:
            continue
        seen.add(candidate)
        if not exists_fn(candidate):
            suggestions.append(candidate)
    return suggestions
EOF_MODULES_CUSTOMER_NAME_SUGGESTIONS_PY

echo "Writing modules/customer/templates/customer_login.html..."
mkdir -p "$(dirname "$PANEL_DIR/modules/customer/templates/customer_login.html")"
cat > "$PANEL_DIR/modules/customer/templates/customer_login.html" << 'EOF_MODULES_CUSTOMER_TEMPLATES_CUSTOMER_LOGIN_HTML'
{% extends "base.html" %}
{% block title %}VM Login — {{ panel_name }}{% endblock %}
{% block auth_content %}
<div class="auth-shell">
  <div style="width:100%; max-width:400px;">
    <div class="auth-brand">
      <div class="brand-mark">OL</div>
      <div class="brand-text">
        <span class="brand-name">OpsLab</span>
        <span class="brand-sub">VM PORTAL</span>
      </div>
    </div>

    <div class="auth-card">
      <h1>Log in to your VM</h1>
      <p class="sub">Use the name or IP address, username, and password you set up for this VM.</p>

      {% with messages = get_flashed_messages(with_categories=true) %}
        {% if messages %}
          {% for category, message in messages %}
            <div class="flash flash-{{ category }}">{{ message }}</div>
          {% endfor %}
        {% endif %}
      {% endwith %}

      <form method="POST">
        {{ form.hidden_tag() }}

        <div class="field">
          {{ form.identifier.label }}
          {{ form.identifier(placeholder="my-vm-name or 203.0.113.4", autofocus=true) }}
          {% for error in form.identifier.errors %}<div class="form-errors">{{ error }}</div>{% endfor %}
        </div>

        <div class="field">
          {{ form.username.label }}
          {{ form.username(placeholder="username") }}
          {% for error in form.username.errors %}<div class="form-errors">{{ error }}</div>{% endfor %}
        </div>

        <div class="field">
          {{ form.password.label }}
          {{ form.password(placeholder="••••••••") }}
          {% for error in form.password.errors %}<div class="form-errors">{{ error }}</div>{% endfor %}
        </div>

        <button class="btn btn-primary btn-block" type="submit">Log in</button>
      </form>

      <p class="sub" style="margin-top:18px; text-align:center;">
        First time here? <a href="{{ url_for('customer.claim_identify') }}">Set up your VM</a>
      </p>
      <p class="sub" style="margin-top:6px; text-align:center;">
        <a href="{{ url_for('auth.login') }}">Admin login</a>
      </p>
    </div>
  </div>
</div>
{% endblock %}
EOF_MODULES_CUSTOMER_TEMPLATES_CUSTOMER_LOGIN_HTML

echo "Writing modules/customer/templates/claim_identify.html..."
mkdir -p "$(dirname "$PANEL_DIR/modules/customer/templates/claim_identify.html")"
cat > "$PANEL_DIR/modules/customer/templates/claim_identify.html" << 'EOF_MODULES_CUSTOMER_TEMPLATES_CLAIM_IDENTIFY_HTML'
{% extends "base.html" %}
{% block title %}Set up your VM — {{ panel_name }}{% endblock %}
{% block auth_content %}
<div class="auth-shell">
  <div style="width:100%; max-width:420px;">
    <div class="auth-brand">
      <div class="brand-mark">OL</div>
      <div class="brand-text">
        <span class="brand-name">OpsLab</span>
        <span class="brand-sub">VM PORTAL</span>
      </div>
    </div>

    <div class="auth-card">
      <h1>Set up your VM</h1>
      <p class="sub">
        Install the agent on your VM first — it prints a pairing code when it registers.
        Enter this VM's IP address and that code below to continue.
      </p>

      {% with messages = get_flashed_messages(with_categories=true) %}
        {% if messages %}
          {% for category, message in messages %}
            <div class="flash flash-{{ category }}">{{ message }}</div>
          {% endfor %}
        {% endif %}
      {% endwith %}

      <form method="POST">
        {{ form.hidden_tag() }}

        <div class="field">
          {{ form.ip_address.label }}
          {{ form.ip_address(placeholder="203.0.113.4", autofocus=true) }}
          {% for error in form.ip_address.errors %}<div class="form-errors">{{ error }}</div>{% endfor %}
        </div>

        <div class="field">
          {{ form.pairing_code.label }}
          {{ form.pairing_code(placeholder="XXXX-XXXX", style="text-transform:uppercase;") }}
          {% for error in form.pairing_code.errors %}<div class="form-errors">{{ error }}</div>{% endfor %}
        </div>

        <button class="btn btn-primary btn-block" type="submit">Continue</button>
      </form>

      <p class="sub" style="margin-top:18px; text-align:center;">
        Already set up? <a href="{{ url_for('customer.login') }}">Log in instead</a>
      </p>
    </div>
  </div>
</div>
{% endblock %}
EOF_MODULES_CUSTOMER_TEMPLATES_CLAIM_IDENTIFY_HTML

echo "Writing modules/customer/templates/claim_setup.html..."
mkdir -p "$(dirname "$PANEL_DIR/modules/customer/templates/claim_setup.html")"
cat > "$PANEL_DIR/modules/customer/templates/claim_setup.html" << 'EOF_MODULES_CUSTOMER_TEMPLATES_CLAIM_SETUP_HTML'
{% extends "base.html" %}
{% block title %}Name your VM — {{ panel_name }}{% endblock %}
{% block auth_content %}
<div class="auth-shell">
  <div style="width:100%; max-width:440px;">
    <div class="auth-brand">
      <div class="brand-mark">OL</div>
      <div class="brand-text">
        <span class="brand-name">OpsLab</span>
        <span class="brand-sub">VM PORTAL</span>
      </div>
    </div>

    <div class="auth-card">
      <h1>Almost done</h1>
      <p class="sub">
        VM verified at <span class="mono">{{ vm.ip_address }}</span>. Give it a name and create the
        username/password you'll use to log in from now on.
      </p>

      {% with messages = get_flashed_messages(with_categories=true) %}
        {% if messages %}
          {% for category, message in messages %}
            <div class="flash flash-{{ category }}">{{ message }}</div>
          {% endfor %}
        {% endif %}
      {% endwith %}

      <form method="POST" id="claim-setup-form">
        {{ form.hidden_tag() }}

        <div class="field">
          {{ form.name.label }}
          {{ form.name(placeholder="my-vm-name", id="vm-name-input", autofocus=true) }}
          {% for error in form.name.errors %}<div class="form-errors">{{ error }}</div>{% endfor %}
        </div>

        <div id="name-suggestions" style="margin:-10px 0 16px; display:flex; gap:8px; flex-wrap:wrap;">
          {% for s in suggestions %}
          <button type="button" class="btn btn-ghost btn-sm suggestion-chip" data-name="{{ s }}">{{ s }}</button>
          {% endfor %}
          <button type="button" class="btn btn-ghost btn-sm" id="refresh-suggestions">↻ More suggestions</button>
        </div>

        <div class="field">
          {{ form.username.label }}
          {{ form.username(placeholder="username") }}
          {% for error in form.username.errors %}<div class="form-errors">{{ error }}</div>{% endfor %}
        </div>

        <div class="field">
          {{ form.password.label }}
          {{ form.password(placeholder="••••••••") }}
          {% for error in form.password.errors %}<div class="form-errors">{{ error }}</div>{% endfor %}
        </div>

        <div class="field">
          {{ form.confirm_password.label }}
          {{ form.confirm_password(placeholder="••••••••") }}
          {% for error in form.confirm_password.errors %}<div class="form-errors">{{ error }}</div>{% endfor %}
        </div>

        <button class="btn btn-primary btn-block" type="submit">Finish setup</button>
      </form>
    </div>
  </div>
</div>
{% endblock %}

{% block scripts %}
<script>
  const nameInput = document.getElementById('vm-name-input');
  const suggestionsBox = document.getElementById('name-suggestions');
  const refreshBtn = document.getElementById('refresh-suggestions');

  suggestionsBox.addEventListener('click', (e) => {
    const chip = e.target.closest('.suggestion-chip');
    if (chip) nameInput.value = chip.dataset.name;
  });

  refreshBtn.addEventListener('click', async () => {
    refreshBtn.disabled = true;
    try {
      const resp = await fetch("{{ url_for('customer.suggest_name_ajax') }}");
      const data = await resp.json();
      document.querySelectorAll('.suggestion-chip').forEach(el => el.remove());
      (data.suggestions || []).forEach(name => {
        const btn = document.createElement('button');
        btn.type = 'button';
        btn.className = 'btn btn-ghost btn-sm suggestion-chip';
        btn.dataset.name = name;
        btn.textContent = name;
        suggestionsBox.insertBefore(btn, refreshBtn);
      });
    } catch (e) {
      // Suggestions are a convenience, not required - a failed refresh
      // just means the chips don't change; the person can still type
      // their own name.
    } finally {
      refreshBtn.disabled = false;
    }
  });
</script>
{% endblock %}
EOF_MODULES_CUSTOMER_TEMPLATES_CLAIM_SETUP_HTML

echo "Writing modules/customer/templates/vm_dashboard.html..."
mkdir -p "$(dirname "$PANEL_DIR/modules/customer/templates/vm_dashboard.html")"
cat > "$PANEL_DIR/modules/customer/templates/vm_dashboard.html" << 'EOF_MODULES_CUSTOMER_TEMPLATES_VM_DASHBOARD_HTML'
{% extends "base.html" %}
{% block title %}{{ vm.name }} — {{ panel_name }}{% endblock %}
{% block customer_content %}
<div class="app-shell" style="grid-template-columns:1fr;">
  <main class="main">
    <div class="topbar">
      <div>
        <p class="page-eyebrow">VM Portal</p>
        <h1 class="page-title">{{ vm.name }}</h1>
        <p class="page-sub mono">{{ vm.ip_address }}</p>
      </div>
      <div class="topbar-actions">
        <a class="btn btn-ghost" href="{{ url_for('customer.logout') }}">Log out</a>
      </div>
    </div>

    {% with messages = get_flashed_messages(with_categories=true) %}
      {% if messages %}
        {% for category, message in messages %}
          <div class="flash flash-{{ category }}">{{ message }}</div>
        {% endfor %}
      {% endif %}
    {% endwith %}

    <div class="grid">
      <div class="card stat">
        <div class="card-label">Status</div>
        <div class="card-value line">
          <span class="status-dot {{ 'ok live' if vm.is_online }}"></span>
          {{ 'Online' if vm.is_online else 'Offline' }}
        </div>
        <div class="card-meta">
          {% if vm.last_seen_at %}Last check-in {{ vm.last_seen_at.strftime('%Y-%m-%d %H:%M UTC') }}{% else %}No check-in yet{% endif %}
        </div>
      </div>
      <div class="card stat">
        <div class="card-label">SSH</div>
        <div class="card-value">{{ 'Disabled' if vm.ssh_disabled else 'Enabled' }}</div>
        <div class="card-meta">{{ 'Managed by your administrator' if vm.ssh_disabled else 'Active on this VM' }}</div>
      </div>
      <div class="card stat">
        <div class="card-label">Agent version</div>
        <div class="card-value">{{ vm.agent_version or '—' }}</div>
        <div class="card-meta">{{ vm.hostname or '' }}</div>
      </div>
    </div>

    <div class="card" style="margin-top:16px;">
      <div class="card-label">Need something changed?</div>
      <p class="page-sub" style="margin-top:6px;">
        VM-level actions like SSH and power control are managed by your administrator. Contact them if you need
        something changed here.
      </p>
    </div>
  </main>
</div>
{% endblock %}
EOF_MODULES_CUSTOMER_TEMPLATES_VM_DASHBOARD_HTML

echo "Writing modules/agent_api/routes.py..."
mkdir -p "$(dirname "$PANEL_DIR/modules/agent_api/routes.py")"
cat > "$PANEL_DIR/modules/agent_api/routes.py" << 'EOF_MODULES_AGENT_API_ROUTES_PY'
"""HTTP API for the standalone opslab_agent.py script that runs on
customer VMs. Deliberately plain request/response polling rather than
Socket.IO - keeps the agent's only dependency to `requests`, and avoids
any Engine.IO/Socket.IO protocol-version coupling between agent and
panel across upgrades of either side. Every route here is CSRF-exempted
in app.py, since callers are machine clients that will never carry a
CSRF token, not browser form submissions.
"""
from datetime import datetime

from flask import Blueprint, request, jsonify

from database import db
from models.vm import VM, VMCommand

agent_api_bp = Blueprint("agent_api", __name__, url_prefix="/api/agent")


def _vm_from_token():
    payload = request.get_json(silent=True) or {}
    token = payload.get("agent_token") or request.headers.get("X-Agent-Token")
    if not token:
        return None
    return VM.query.filter_by(agent_token=token).first()


@agent_api_bp.route("/register", methods=["POST"])
def register():
    """Authoritative IP is the actual TCP source (request.remote_addr),
    never a client-supplied field - this is what stops someone from
    registering or claiming an IP they don't actually control."""
    ip = request.remote_addr
    payload = request.get_json(silent=True) or {}

    vm = VM.query.filter_by(ip_address=ip).first()
    if vm is None:
        vm = VM(ip_address=ip)
        db.session.add(vm)

    vm.hostname = (payload.get("hostname") or vm.hostname or "")[:255]
    vm.agent_version = (payload.get("agent_version") or "")[:32]
    vm.last_seen_at = datetime.utcnow()
    vm.last_status = "online"
    db.session.commit()

    return jsonify({
        "agent_token": vm.agent_token,
        "pairing_code": vm.pairing_code,  # null once claimed
        "claimed": vm.is_claimed,
        "locked": vm.locked,
    })


@agent_api_bp.route("/heartbeat", methods=["POST"])
def heartbeat():
    vm = _vm_from_token()
    if vm is None:
        return jsonify({"error": "unknown agent_token"}), 403

    payload = request.get_json(silent=True) or {}
    vm.last_seen_at = datetime.utcnow()
    vm.last_status = "online"
    if payload.get("hostname"):
        vm.hostname = payload["hostname"][:255]
    if payload.get("agent_version"):
        vm.agent_version = payload["agent_version"][:32]
    # Keep the recorded IP current if the box's address changed (DHCP
    # renewal, etc). Matched by agent_token here, not IP, so this can't
    # be abused to hijack a different VM's record.
    if request.remote_addr and request.remote_addr != vm.ip_address:
        vm.ip_address = request.remote_addr

    pending = [c for c in vm.commands if c.status == "pending"]
    for cmd in pending:
        cmd.status = "delivered"
        cmd.delivered_at = datetime.utcnow()
    db.session.commit()

    return jsonify({
        "locked": vm.locked,
        "commands": [{"id": c.id, "action": c.action} for c in pending],
    })


@agent_api_bp.route("/ack", methods=["POST"])
def ack():
    vm = _vm_from_token()
    if vm is None:
        return jsonify({"error": "unknown agent_token"}), 403

    payload = request.get_json(silent=True) or {}
    command_id = payload.get("command_id")
    cmd = VMCommand.query.filter_by(id=command_id, vm_id=vm.id).first()
    if not cmd:
        return jsonify({"error": "unknown command_id for this VM"}), 404

    status = payload.get("status")
    cmd.status = status if status in ("acked", "failed") else "acked"
    cmd.detail = (payload.get("detail") or "")[:2000]
    cmd.acked_at = datetime.utcnow()

    if cmd.action in ("disable_ssh", "enable_ssh") and cmd.status == "acked":
        vm.ssh_disabled = (cmd.action == "disable_ssh")

    db.session.commit()
    return jsonify({"ok": True})
EOF_MODULES_AGENT_API_ROUTES_PY

echo "Writing agent_distribution/opslab_agent.py..."
mkdir -p "$(dirname "$PANEL_DIR/agent_distribution/opslab_agent.py")"
cat > "$PANEL_DIR/agent_distribution/opslab_agent.py" << 'EOF_AGENT_DISTRIBUTION_OPSLAB_AGENT_PY'
#!/usr/bin/env python3
"""OpsLab Agent - lightweight check-in client for OpsLab Server Panel.

Install (as root):
    python3 opslab_agent.py --install --panel-url https://serverpanel.opslabsystems.cloud

That registers this VM with the panel (printing a one-time pairing code
you'll enter on the panel to claim it), writes a small local state file,
installs a systemd unit so this keeps running across reboots, and starts
it immediately.

Manual run (e.g. for testing without installing the service):
    python3 opslab_agent.py --run --panel-url https://serverpanel.opslabsystems.cloud

Only dependency: `requests` (pip3 install requests). Everything else is
Python standard library, on purpose - this is meant to drop onto any
Linux VM with minimal fuss. It never opens a listening port and never
accepts inbound connections; every request is initiated by this script
outbound to the panel, so no firewall changes are needed on this VM.
"""
import argparse
import json
import os
import socket
import subprocess
import sys
import time

try:
    import requests
except ImportError:
    sys.exit("This script needs the 'requests' package: pip3 install requests")

STATE_DIR = "/etc/opslab-agent"
STATE_FILE = os.path.join(STATE_DIR, "state.json")
SERVICE_PATH = "/etc/systemd/system/opslab-agent.service"
HEARTBEAT_INTERVAL_SECONDS = 20
REQUEST_TIMEOUT = 15
AGENT_VERSION = "1.0"


def _load_state():
    if not os.path.exists(STATE_FILE):
        return {}
    try:
        with open(STATE_FILE) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def _save_state(state):
    os.makedirs(STATE_DIR, exist_ok=True)
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f)
    os.replace(tmp, STATE_FILE)
    os.chmod(STATE_FILE, 0o600)  # agent_token lives in here - keep it off-limits to non-root users


def _hostname():
    try:
        return socket.gethostname()
    except Exception:
        return ""


def register(panel_url):
    resp = requests.post(
        f"{panel_url.rstrip('/')}/api/agent/register",
        json={"hostname": _hostname(), "agent_version": AGENT_VERSION},
        timeout=REQUEST_TIMEOUT,
    )
    resp.raise_for_status()
    data = resp.json()

    state = _load_state()
    state["panel_url"] = panel_url
    state["agent_token"] = data["agent_token"]
    _save_state(state)

    print("=" * 60)
    if data.get("claimed"):
        print("This VM is already claimed on the panel.")
    else:
        print("Registered with the panel.")
        print(f"  Pairing code: {data['pairing_code']}")
        print("  Enter this VM's IP address and the pairing code above")
        print(f"  at: {panel_url.rstrip('/')}/portal/claim")
    print("=" * 60)
    return state


def _run_ssh_action(enable):
    """Best-effort across common init/service names - tries systemctl
    first (the overwhelming majority of current distros use it), falls
    back to service(8) for older ones. Never raises; returns (ok, detail)
    so the caller can report status back to the panel either way."""
    verb = "start" if enable else "stop"
    persist_verb = "enable" if enable else "disable"

    for unit in ("ssh", "sshd"):
        try:
            subprocess.run(["systemctl", verb, unit], check=True, capture_output=True, timeout=20)
            subprocess.run(["systemctl", persist_verb, unit], check=False, capture_output=True, timeout=20)
            return True, f"systemctl {verb} {unit}"
        except (subprocess.CalledProcessError, FileNotFoundError, subprocess.TimeoutExpired):
            continue

    for unit in ("ssh", "sshd"):
        try:
            subprocess.run(["service", unit, verb], check=True, capture_output=True, timeout=20)
            return True, f"service {unit} {verb}"
        except (subprocess.CalledProcessError, FileNotFoundError, subprocess.TimeoutExpired):
            continue

    return False, "no ssh/sshd service found via systemctl or service(8)"


def _run_power_off():
    for cmd in (["shutdown", "-h", "now"], ["poweroff"]):
        try:
            subprocess.Popen(cmd)
            return True, " ".join(cmd)
        except FileNotFoundError:
            continue
    return False, "no shutdown/poweroff command found"


def _execute(action):
    if action == "disable_ssh":
        return _run_ssh_action(enable=False)
    if action == "enable_ssh":
        return _run_ssh_action(enable=True)
    if action == "power_off":
        return _run_power_off()
    return False, f"unknown action: {action}"


def _heartbeat_loop(state):
    panel_url = state["panel_url"].rstrip("/")
    token = state["agent_token"]

    while True:
        try:
            resp = requests.post(
                f"{panel_url}/api/agent/heartbeat",
                json={"agent_token": token, "hostname": _hostname(), "agent_version": AGENT_VERSION},
                timeout=REQUEST_TIMEOUT,
            )
            if resp.status_code == 403:
                print("Panel doesn't recognize this agent_token - re-run with --install to re-register.")
                time.sleep(HEARTBEAT_INTERVAL_SECONDS)
                continue
            resp.raise_for_status()
            data = resp.json()

            for cmd in data.get("commands", []):
                ok, detail = _execute(cmd["action"])
                print(f"executed {cmd['action']}: ok={ok} detail={detail}")
                try:
                    requests.post(
                        f"{panel_url}/api/agent/ack",
                        json={
                            "agent_token": token,
                            "command_id": cmd["id"],
                            "status": "acked" if ok else "failed",
                            "detail": detail,
                        },
                        timeout=REQUEST_TIMEOUT,
                    )
                except requests.RequestException:
                    pass  # picked up again on the next heartbeat if the panel re-queues it

        except requests.RequestException as exc:
            print(f"Heartbeat failed (will retry): {exc}")

        time.sleep(HEARTBEAT_INTERVAL_SECONDS)


def install(panel_url):
    if os.geteuid() != 0:
        sys.exit("--install must be run as root (needed to write the systemd unit and control sshd).")

    register(panel_url)

    script_path = os.path.abspath(__file__)
    unit = f"""[Unit]
Description=OpsLab Agent
After=network-online.target
Wants=network-online.target

[Service]
ExecStart={sys.executable} {script_path} --run
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
"""
    with open(SERVICE_PATH, "w") as f:
        f.write(unit)

    subprocess.run(["systemctl", "daemon-reload"], check=True)
    subprocess.run(["systemctl", "enable", "opslab-agent"], check=True)
    subprocess.run(["systemctl", "restart", "opslab-agent"], check=True)
    print("Installed and started as a systemd service (opslab-agent) - will auto-start on boot.")


def main():
    parser = argparse.ArgumentParser(description="OpsLab Agent")
    parser.add_argument("--install", action="store_true", help="Register this VM and install as a systemd service")
    parser.add_argument("--run", action="store_true", help="Run the heartbeat loop directly (used by the systemd unit)")
    parser.add_argument("--panel-url", help="e.g. https://serverpanel.opslabsystems.cloud")
    args = parser.parse_args()

    if args.install:
        if not args.panel_url:
            sys.exit("--install requires --panel-url")
        install(args.panel_url)
    elif args.run:
        state = _load_state()
        if not state.get("agent_token"):
            sys.exit("No saved agent_token found - run with --install first.")
        _heartbeat_loop(state)
    else:
        parser.print_help()


if __name__ == "__main__":
    main()
EOF_AGENT_DISTRIBUTION_OPSLAB_AGENT_PY

chmod +x "$PANEL_DIR/agent_distribution/opslab_agent.py"

echo
echo "Done. Previous versions of every replaced file are in: $BACKUP_DIR"
echo
echo "Next steps:"
echo "  1) Restart the panel (e.g. systemctl restart opslab-panel) - this is when the new"
echo "     vms/vm_commands tables get created (db.create_all() runs on boot, additive only,"
echo "     never touches your existing tables)."
echo "  2) Log in as admin, confirm a 'VMs' link now shows in the sidebar and /admin/vms loads."
echo "  3) Give agent_distribution/opslab_agent.py to a test VM and run:"
echo "       python3 opslab_agent.py --install --panel-url https://serverpanel.opslabsystems.cloud"
echo "     It will print a pairing code - enter that VM's IP + that code at /portal/claim."
echo "  4) Confirm /login still shows only the admin form, with a 'Log in to your VM' link at the bottom."
