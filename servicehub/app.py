import os
import re
from functools import wraps
from datetime import timedelta

from flask import (
    Flask, render_template, redirect, url_for, request, session,
    flash, jsonify, abort
)
from flask_wtf import CSRFProtect

from models import db, AdminUser, Service
import systemd_ctl as ctl

BASE_DIR = os.path.abspath(os.path.dirname(__file__))


def create_app():
    app = Flask(__name__)

    app.config["SECRET_KEY"] = os.environ.get("SERVICEHUB_SECRET_KEY", "change-me-in-.env")
    app.config["SQLALCHEMY_DATABASE_URI"] = os.environ.get(
        "SERVICEHUB_DATABASE_URI", f"sqlite:///{os.path.join(BASE_DIR, 'servicehub.db')}"
    )
    app.config["SQLALCHEMY_TRACK_MODIFICATIONS"] = False
    app.config["PERMANENT_SESSION_LIFETIME"] = timedelta(hours=12)
    # Behind nginx TLS in production - set SERVICEHUB_COOKIE_SECURE=1 there.
    app.config["SESSION_COOKIE_SECURE"] = os.environ.get("SERVICEHUB_COOKIE_SECURE", "0") == "1"
    app.config["SESSION_COOKIE_HTTPONLY"] = True
    app.config["SESSION_COOKIE_SAMESITE"] = "Lax"

    db.init_app(app)
    CSRFProtect(app)  # initialized up front - do not skip this again

    with app.app_context():
        db.create_all()

    register_routes(app)
    return app


# ---------- helpers ----------

SLUG_RE = re.compile(r"[^a-z0-9-]+")


def slugify(name):
    s = name.strip().lower().replace(" ", "-").replace("_", "-")
    s = SLUG_RE.sub("", s)
    s = re.sub(r"-+", "-", s).strip("-")
    return s or "service"


def login_required(view):
    @wraps(view)
    def wrapped(*args, **kwargs):
        if not session.get("user_id"):
            return redirect(url_for("login", next=request.path))
        return view(*args, **kwargs)
    return wrapped


def any_admin_exists():
    return AdminUser.query.first() is not None


# ---------- routes ----------

def register_routes(app):

    @app.before_request
    def enforce_setup():
        # Force the setup wizard until an admin account exists.
        if request.endpoint in ("setup", "static"):
            return
        if not any_admin_exists():
            return redirect(url_for("setup"))

    @app.route("/setup", methods=["GET", "POST"])
    def setup():
        if any_admin_exists():
            return redirect(url_for("login"))

        if request.method == "POST":
            username = request.form.get("username", "").strip()
            password = request.form.get("password", "")
            confirm = request.form.get("confirm", "")

            if len(username) < 3:
                flash("Username needs to be at least 3 characters.", "error")
            elif len(password) < 8:
                flash("Password needs to be at least 8 characters.", "error")
            elif password != confirm:
                flash("Passwords don't match.", "error")
            else:
                admin = AdminUser(username=username)
                admin.set_password(password)
                db.session.add(admin)
                db.session.commit()
                flash("Admin account created. Log in below.", "success")
                return redirect(url_for("login"))

        return render_template("setup.html")

    @app.route("/login", methods=["GET", "POST"])
    def login():
        if session.get("user_id"):
            return redirect(url_for("dashboard"))

        if request.method == "POST":
            username = request.form.get("username", "").strip()
            password = request.form.get("password", "")
            admin = AdminUser.query.filter_by(username=username).first()
            if admin and admin.check_password(password):
                session.permanent = True
                session["user_id"] = admin.id
                session["username"] = admin.username
                return redirect(request.args.get("next") or url_for("dashboard"))
            flash("Wrong username or password.", "error")

        return render_template("login.html")

    @app.route("/logout")
    def logout():
        session.clear()
        return redirect(url_for("login"))

    @app.route("/")
    @login_required
    def dashboard():
        services = Service.query.order_by(Service.name.asc()).all()
        statuses = {s.id: ctl.status(s) for s in services}
        return render_template("dashboard.html", services=services, statuses=statuses)

    @app.route("/api/status")
    @login_required
    def api_status():
        services = Service.query.all()
        return jsonify({s.id: ctl.status(s) for s in services})

    @app.route("/system")
    @login_required
    def system_services():
        managed = {s.unit_name: s for s in Service.query.all()}
        all_units = ctl.list_all_units()
        show_all = request.args.get("all") == "1"
        if not show_all:
            all_units = [u for u in all_units if u["active"] == "active"]
        # Managed-but-not-currently-running units still show up on the
        # ServiceHub dashboard, so no need to force them into this list.
        for u in all_units:
            u["managed_service"] = managed.get(u["unit"])
        all_units.sort(key=lambda u: (u["managed_service"] is None, u["unit"]))
        return render_template("system.html", units=all_units, show_all=show_all)

    @app.route("/services/new", methods=["GET", "POST"])
    @login_required
    def service_new():
        if request.method == "POST":
            svc = build_service_from_form()
            if svc is None:
                return render_template("service_form.html", service=None, form=request.form)

            db.session.add(svc)
            db.session.commit()

            try:
                ctl.write_unit(svc)
                ctl.enable(svc)
                ctl.start(svc)
                flash(f"Service '{svc.name}' created, enabled and started.", "success")
            except ctl.ServiceCtlError as e:
                flash(f"Service saved, but systemd setup failed: {e}", "error")

            return redirect(url_for("service_detail", service_id=svc.id))

        return render_template("service_form.html", service=None, form=None)

    @app.route("/services/<int:service_id>")
    @login_required
    def service_detail(service_id):
        svc = Service.query.get_or_404(service_id)
        st = ctl.status(svc)
        return render_template("service_detail.html", service=svc, status=st)

    @app.route("/services/<int:service_id>/logs")
    @login_required
    def service_logs(service_id):
        svc = Service.query.get_or_404(service_id)
        text = ctl.logs(svc, lines=200)
        return jsonify({"logs": text})

    @app.route("/services/<int:service_id>/edit", methods=["GET", "POST"])
    @login_required
    def service_edit(service_id):
        svc = Service.query.get_or_404(service_id)

        if request.method == "POST":
            old_unit_name = svc.unit_name
            updated = build_service_from_form(existing=svc)
            if updated is None:
                return render_template("service_form.html", service=svc, form=request.form)

            db.session.commit()

            try:
                if old_unit_name != svc.unit_name:
                    # name changed -> remove the old unit before writing the new one
                    class _Ghost:
                        unit_name = old_unit_name
                    ctl.remove(_Ghost())
                ctl.write_unit(svc)
                ctl.enable(svc)
                ctl.restart(svc)
                flash(f"Service '{svc.name}' updated and restarted.", "success")
            except ctl.ServiceCtlError as e:
                flash(f"Service saved, but systemd update failed: {e}", "error")

            return redirect(url_for("service_detail", service_id=svc.id))

        return render_template("service_form.html", service=svc, form=None)

    @app.route("/services/<int:service_id>/delete", methods=["POST"])
    @login_required
    def service_delete(service_id):
        svc = Service.query.get_or_404(service_id)
        try:
            ctl.remove(svc)
        except ctl.ServiceCtlError as e:
            flash(f"Warning: systemd cleanup failed: {e}", "error")
        name = svc.name
        db.session.delete(svc)
        db.session.commit()
        flash(f"Service '{name}' deleted.", "success")
        return redirect(url_for("dashboard"))

    @app.route("/services/<int:service_id>/<action>", methods=["POST"])
    @login_required
    def service_action(service_id, action):
        svc = Service.query.get_or_404(service_id)
        actions = {
            "start": ctl.start,
            "stop": ctl.stop,
            "restart": ctl.restart,
            "enable": ctl.enable,
            "disable": ctl.disable,
        }
        fn = actions.get(action)
        if fn is None:
            abort(404)
        try:
            fn(svc)
            flash(f"{action.capitalize()} sent to '{svc.name}'.", "success")
        except ctl.ServiceCtlError as e:
            flash(f"{action.capitalize()} failed: {e}", "error")

        if request.headers.get("X-Requested-With") == "fetch":
            return jsonify({"ok": True})
        return redirect(request.referrer or url_for("dashboard"))

    @app.route("/services/<int:service_id>/nginx-snippet")
    @login_required
    def nginx_snippet(service_id):
        svc = Service.query.get_or_404(service_id)
        port = svc.port or 8000
        snippet = f"""server {{
    listen 80;
    server_name {svc.slug}.opslabsystems.cloud;

    location / {{
        proxy_pass http://127.0.0.1:{port};
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }}
}}
"""
        return jsonify({"snippet": snippet})


def build_service_from_form(existing=None):
    name = request.form.get("name", "").strip()
    description = request.form.get("description", "").strip()
    working_dir = request.form.get("working_dir", "").strip()
    command = request.form.get("command", "").strip()
    port_raw = request.form.get("port", "").strip()
    run_user = request.form.get("run_user", "www-data").strip() or "www-data"
    restart_policy = request.form.get("restart_policy", "on-failure").strip()
    env_vars = request.form.get("env_vars", "").strip()
    notes = request.form.get("notes", "").strip()

    if not name:
        flash("Name is required.", "error")
        return None
    if not working_dir.startswith("/"):
        flash("Path must be an absolute path (e.g. /var/www/myapp).", "error")
        return None
    if not command:
        flash("Start command is required.", "error")
        return None

    port = None
    if port_raw:
        if not port_raw.isdigit() or not (1 <= int(port_raw) <= 65535):
            flash("Port must be a number between 1 and 65535.", "error")
            return None
        port = int(port_raw)

    if restart_policy not in ("always", "on-failure", "no"):
        restart_policy = "on-failure"

    slug = slugify(name)

    q = Service.query.filter(Service.slug == slug)
    if existing:
        q = q.filter(Service.id != existing.id)
    if q.first() is not None:
        flash("A service with a matching name/slug already exists.", "error")
        return None

    svc = existing or Service()
    svc.name = name
    svc.slug = slug
    svc.description = description
    svc.working_dir = working_dir
    svc.command = command
    svc.port = port
    svc.run_user = run_user
    svc.restart_policy = restart_policy
    svc.env_vars = env_vars
    svc.notes = notes

    if existing is None:
        db.session.add(svc)

    return svc


app = create_app()

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 9500)), debug=False)
