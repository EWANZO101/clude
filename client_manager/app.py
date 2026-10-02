import os
import re
import uuid
from datetime import datetime

from flask import (
    Flask, render_template, request, redirect, url_for,
    flash, send_from_directory, abort
)
from werkzeug.utils import secure_filename
from sqlalchemy import or_
from flask_login import (
    LoginManager, UserMixin, login_user, logout_user,
    login_required, current_user,
)
from flask_wtf import CSRFProtect

from models import (
    db, User, Client, FileItem, Note, Project,
    CATEGORIES, CATEGORY_SLUGS, CATEGORY_LABELS, CATEGORY_ICONS,
    PROJECT_STATUSES, CLIENT_STATUSES,
)

BASE_DIR = os.path.abspath(os.path.dirname(__file__))
UPLOAD_DIR = os.path.join(BASE_DIR, "uploads")

EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")


def create_app():
    app = Flask(__name__)
    # IMPORTANT: override this via the SECRET_KEY environment variable in
    # production — it's what protects sessions and CSRF tokens.
    app.config["SECRET_KEY"] = os.environ.get("SECRET_KEY", "dev-secret-key-change-me")
    app.config["SQLALCHEMY_DATABASE_URI"] = "sqlite:///" + os.path.join(BASE_DIR, "client_manager.db")
    app.config["SQLALCHEMY_TRACK_MODIFICATIONS"] = False
    app.config["MAX_CONTENT_LENGTH"] = 512 * 1024 * 1024  # 512 MB per upload
    app.config["UPLOAD_DIR"] = UPLOAD_DIR

    # Session / cookie hardening
    app.config["SESSION_COOKIE_HTTPONLY"] = True
    app.config["SESSION_COOKIE_SAMESITE"] = "Lax"
    # If you serve this over HTTPS (recommended for anything beyond localhost),
    # set SESSION_COOKIE_SECURE=true in your environment.
    app.config["SESSION_COOKIE_SECURE"] = os.environ.get("SESSION_COOKIE_SECURE", "false").lower() == "true"

    # Optional invite code: if SIGNUP_CODE is set in the environment, anyone
    # signing up must enter it. Leave unset to allow open signup (fine for a
    # single-user local install).
    app.config["SIGNUP_CODE"] = os.environ.get("SIGNUP_CODE", "")

    db.init_app(app)
    os.makedirs(UPLOAD_DIR, exist_ok=True)

    with app.app_context():
        db.create_all()

    # CSRF protection on every state-changing (POST/PUT/PATCH/DELETE) request
    csrf = CSRFProtect(app)

    login_manager = LoginManager()
    login_manager.login_view = "login"
    login_manager.login_message = "Please log in to continue."
    login_manager.login_message_category = "error"
    login_manager.init_app(app)

    @login_manager.user_loader
    def load_user(user_id):
        return db.session.get(User, int(user_id))

    register_template_helpers(app)
    register_auth_routes(app)
    register_routes(app)
    return app


def register_template_helpers(app):
    @app.template_filter("filesize")
    def filesize_filter(num):
        if not num:
            return "0 B"
        for unit in ["B", "KB", "MB", "GB"]:
            if num < 1024:
                return f"{num:.0f} {unit}" if unit == "B" else f"{num:.1f} {unit}"
            num /= 1024
        return f"{num:.1f} TB"

    @app.template_filter("dt")
    def dt_filter(value, fmt="%d %b %Y, %H:%M"):
        if not value:
            return ""
        return value.strftime(fmt)

    @app.context_processor
    def inject_globals():
        return dict(
            CATEGORIES=CATEGORIES,
            CATEGORY_LABELS=CATEGORY_LABELS,
            CATEGORY_ICONS=CATEGORY_ICONS,
            PROJECT_STATUSES=PROJECT_STATUSES,
            CLIENT_STATUSES=CLIENT_STATUSES,
            sidebar_clients=(
                Client.query.order_by(Client.name.asc()).limit(30).all()
                if current_user.is_authenticated else []
            ),
        )


def register_auth_routes(app):

    @app.route("/signup", methods=["GET", "POST"])
    def signup():
        if current_user.is_authenticated:
            return redirect(url_for("dashboard"))

        if request.method == "POST":
            name = request.form.get("name", "").strip()
            email = request.form.get("email", "").strip().lower()
            password = request.form.get("password", "")
            confirm = request.form.get("confirm_password", "")
            code = request.form.get("signup_code", "")

            errors = []
            if not name:
                errors.append("Please enter your name.")
            if not EMAIL_RE.match(email):
                errors.append("Please enter a valid email address.")
            elif User.query.filter_by(email=email).first():
                errors.append("An account with that email already exists.")
            if len(password) < 8:
                errors.append("Password must be at least 8 characters.")
            if password != confirm:
                errors.append("Passwords do not match.")
            if app.config["SIGNUP_CODE"] and code != app.config["SIGNUP_CODE"]:
                errors.append("Invalid invite code.")

            if errors:
                for e in errors:
                    flash(e, "error")
                return render_template("signup.html", name=name, email=email,
                                        require_code=bool(app.config["SIGNUP_CODE"]))

            user = User(name=name, email=email)
            user.set_password(password)
            db.session.add(user)
            db.session.commit()
            login_user(user)
            flash(f"Welcome, {user.name}! Your account has been created.", "success")
            return redirect(url_for("dashboard"))

        return render_template("signup.html", name="", email="",
                                require_code=bool(app.config["SIGNUP_CODE"]))

    @app.route("/login", methods=["GET", "POST"])
    def login():
        if current_user.is_authenticated:
            return redirect(url_for("dashboard"))

        if request.method == "POST":
            email = request.form.get("email", "").strip().lower()
            password = request.form.get("password", "")
            remember = bool(request.form.get("remember"))
            user = User.query.filter_by(email=email).first()

            if user and user.check_password(password):
                login_user(user, remember=remember)
                flash(f"Welcome back, {user.name}.", "success")
                next_url = request.args.get("next")
                # Only follow "next" if it's a safe relative path (avoids open-redirect)
                if next_url and next_url.startswith("/") and not next_url.startswith("//"):
                    return redirect(next_url)
                return redirect(url_for("dashboard"))

            flash("Incorrect email or password.", "error")
            return render_template("login.html", email=email)

        return render_template("login.html", email="")

    @app.route("/logout", methods=["POST"])
    @login_required
    def logout():
        logout_user()
        flash("You have been logged out.", "success")
        return redirect(url_for("login"))


def register_routes(app):

    # ---------- Dashboard ----------
    @app.route("/")
    @login_required
    def dashboard():
        q = request.args.get("q", "").strip()
        status = request.args.get("status", "")
        query = Client.query
        if q:
            like = f"%{q}%"
            query = query.filter(or_(Client.name.ilike(like), Client.company.ilike(like)))
        if status:
            query = query.filter(Client.status == status)
        clients = query.order_by(Client.name.asc()).all()

        stats = dict(
            total_clients=Client.query.count(),
            total_files=FileItem.query.count(),
            active_projects=Project.query.filter(Project.status.in_(["Planning", "Active"])).count(),
            total_notes=Note.query.count(),
        )
        return render_template("index.html", clients=clients, q=q, status=status, stats=stats)

    # ---------- Global search ----------
    @app.route("/search")
    @login_required
    def search():
        q = request.args.get("q", "").strip()
        results = dict(clients=[], files=[], notes=[], projects=[])
        if q:
            like = f"%{q}%"
            results["clients"] = Client.query.filter(
                or_(Client.name.ilike(like), Client.company.ilike(like), Client.email.ilike(like))
            ).all()
            results["files"] = FileItem.query.filter(
                or_(FileItem.original_filename.ilike(like), FileItem.description.ilike(like))
            ).all()
            results["notes"] = Note.query.filter(
                or_(Note.title.ilike(like), Note.content.ilike(like))
            ).all()
            results["projects"] = Project.query.filter(
                or_(Project.name.ilike(like), Project.description.ilike(like))
            ).all()
        return render_template("search_results.html", q=q, results=results)

    # ---------- Client CRUD ----------
    @app.route("/clients/new", methods=["GET", "POST"])
    @login_required
    def client_new():
        if request.method == "POST":
            client = Client(
                name=request.form.get("name", "").strip(),
                company=request.form.get("company", "").strip(),
                email=request.form.get("email", "").strip(),
                phone=request.form.get("phone", "").strip(),
                address=request.form.get("address", "").strip(),
                status=request.form.get("status", "Active"),
                summary=request.form.get("summary", "").strip(),
            )
            if not client.name:
                flash("Client name is required.", "error")
                return render_template("client_form.html", client=None, form=request.form)
            db.session.add(client)
            db.session.commit()
            os.makedirs(os.path.join(UPLOAD_DIR, str(client.id)), exist_ok=True)
            flash(f"Client '{client.name}' created.", "success")
            return redirect(url_for("client_detail", client_id=client.id))
        return render_template("client_form.html", client=None, form=None)

    @app.route("/clients/<int:client_id>")
    @login_required
    def client_detail(client_id):
        client = Client.query.get_or_404(client_id)
        tab = request.args.get("tab", "overview")
        files_by_category = {slug: [] for slug in CATEGORY_SLUGS}
        for f in client.files.order_by(FileItem.uploaded_at.desc()).all():
            files_by_category.setdefault(f.category, []).append(f)
        notes = client.notes.order_by(Note.pinned.desc(), Note.updated_at.desc()).all()
        projects = client.projects.order_by(Project.created_at.desc()).all()
        recent_files = client.files.order_by(FileItem.uploaded_at.desc()).limit(5).all()
        return render_template(
            "client_detail.html",
            client=client,
            tab=tab,
            files_by_category=files_by_category,
            notes=notes,
            projects=projects,
            recent_files=recent_files,
        )

    @app.route("/clients/<int:client_id>/edit", methods=["GET", "POST"])
    @login_required
    def client_edit(client_id):
        client = Client.query.get_or_404(client_id)
        if request.method == "POST":
            client.name = request.form.get("name", "").strip()
            client.company = request.form.get("company", "").strip()
            client.email = request.form.get("email", "").strip()
            client.phone = request.form.get("phone", "").strip()
            client.address = request.form.get("address", "").strip()
            client.status = request.form.get("status", "Active")
            client.summary = request.form.get("summary", "").strip()
            if not client.name:
                flash("Client name is required.", "error")
                return render_template("client_form.html", client=client, form=request.form)
            db.session.commit()
            flash("Client updated.", "success")
            return redirect(url_for("client_detail", client_id=client.id))
        return render_template("client_form.html", client=client, form=None)

    @app.route("/clients/<int:client_id>/delete", methods=["POST"])
    @login_required
    def client_delete(client_id):
        client = Client.query.get_or_404(client_id)
        name = client.name
        db.session.delete(client)
        db.session.commit()
        client_dir = os.path.join(UPLOAD_DIR, str(client_id))
        if os.path.isdir(client_dir):
            import shutil
            shutil.rmtree(client_dir, ignore_errors=True)
        flash(f"Client '{name}' and all related data deleted.", "success")
        return redirect(url_for("dashboard"))

    # ---------- File upload / management ----------
    @app.route("/clients/<int:client_id>/upload", methods=["POST"])
    @login_required
    def file_upload(client_id):
        client = Client.query.get_or_404(client_id)
        category = request.form.get("category", "other")
        if category not in CATEGORY_SLUGS:
            category = "other"
        description = request.form.get("description", "").strip()
        uploaded_files = request.files.getlist("files")

        if not uploaded_files or all(f.filename == "" for f in uploaded_files):
            flash("Please choose at least one file to upload.", "error")
            return redirect(url_for("client_detail", client_id=client.id, tab="files"))

        target_dir = os.path.join(UPLOAD_DIR, str(client.id), category)
        os.makedirs(target_dir, exist_ok=True)

        count = 0
        for f in uploaded_files:
            if not f or f.filename == "":
                continue
            original_name = secure_filename(f.filename) or "file"
            stored_name = f"{uuid.uuid4().hex}_{original_name}"
            filepath = os.path.join(target_dir, stored_name)
            f.save(filepath)
            size = os.path.getsize(filepath)
            item = FileItem(
                client_id=client.id,
                category=category,
                original_filename=f.filename,
                stored_filename=stored_name,
                filesize=size,
                description=description,
            )
            db.session.add(item)
            count += 1
        db.session.commit()
        flash(f"Uploaded {count} file(s) to {CATEGORY_LABELS.get(category)}.", "success")
        return redirect(url_for("client_detail", client_id=client.id, tab="files"))

    @app.route("/files/<int:file_id>/download")
    @login_required
    def file_download(file_id):
        item = FileItem.query.get_or_404(file_id)
        directory = os.path.join(UPLOAD_DIR, str(item.client_id), item.category)
        return send_from_directory(directory, item.stored_filename, as_attachment=True,
                                    download_name=item.original_filename)

    @app.route("/files/<int:file_id>/view")
    @login_required
    def file_view(file_id):
        item = FileItem.query.get_or_404(file_id)
        directory = os.path.join(UPLOAD_DIR, str(item.client_id), item.category)
        return send_from_directory(directory, item.stored_filename)

    @app.route("/files/<int:file_id>/delete", methods=["POST"])
    @login_required
    def file_delete(file_id):
        item = FileItem.query.get_or_404(file_id)
        client_id = item.client_id
        filepath = os.path.join(UPLOAD_DIR, str(item.client_id), item.category, item.stored_filename)
        if os.path.isfile(filepath):
            os.remove(filepath)
        db.session.delete(item)
        db.session.commit()
        flash("File deleted.", "success")
        return redirect(url_for("client_detail", client_id=client_id, tab="files"))

    # ---------- Notes ----------
    @app.route("/clients/<int:client_id>/notes/new", methods=["POST"])
    @login_required
    def note_new(client_id):
        client = Client.query.get_or_404(client_id)
        title = request.form.get("title", "").strip() or "Untitled note"
        content = request.form.get("content", "").strip()
        note = Note(client_id=client.id, title=title, content=content)
        db.session.add(note)
        db.session.commit()
        flash("Note added.", "success")
        return redirect(url_for("client_detail", client_id=client.id, tab="notes"))

    @app.route("/notes/<int:note_id>/edit", methods=["POST"])
    @login_required
    def note_edit(note_id):
        note = Note.query.get_or_404(note_id)
        note.title = request.form.get("title", "").strip() or "Untitled note"
        note.content = request.form.get("content", "").strip()
        note.pinned = bool(request.form.get("pinned"))
        db.session.commit()
        flash("Note updated.", "success")
        return redirect(url_for("client_detail", client_id=note.client_id, tab="notes"))

    @app.route("/notes/<int:note_id>/delete", methods=["POST"])
    @login_required
    def note_delete(note_id):
        note = Note.query.get_or_404(note_id)
        client_id = note.client_id
        db.session.delete(note)
        db.session.commit()
        flash("Note deleted.", "success")
        return redirect(url_for("client_detail", client_id=client_id, tab="notes"))

    # ---------- Projects ----------
    @app.route("/clients/<int:client_id>/projects/new", methods=["POST"])
    @login_required
    def project_new(client_id):
        client = Client.query.get_or_404(client_id)
        name = request.form.get("name", "").strip()
        if not name:
            flash("Project name is required.", "error")
            return redirect(url_for("client_detail", client_id=client.id, tab="projects"))
        due_date = request.form.get("due_date") or None
        project = Project(
            client_id=client.id,
            name=name,
            description=request.form.get("description", "").strip(),
            status=request.form.get("status", "Planning"),
            due_date=datetime.strptime(due_date, "%Y-%m-%d").date() if due_date else None,
        )
        db.session.add(project)
        db.session.commit()
        flash("Project created.", "success")
        return redirect(url_for("client_detail", client_id=client.id, tab="projects"))

    @app.route("/projects/<int:project_id>/edit", methods=["POST"])
    @login_required
    def project_edit(project_id):
        project = Project.query.get_or_404(project_id)
        project.name = request.form.get("name", "").strip() or project.name
        project.description = request.form.get("description", "").strip()
        project.status = request.form.get("status", project.status)
        due_date = request.form.get("due_date") or None
        project.due_date = datetime.strptime(due_date, "%Y-%m-%d").date() if due_date else None
        db.session.commit()
        flash("Project updated.", "success")
        return redirect(url_for("client_detail", client_id=project.client_id, tab="projects"))

    @app.route("/projects/<int:project_id>/delete", methods=["POST"])
    @login_required
    def project_delete(project_id):
        project = Project.query.get_or_404(project_id)
        client_id = project.client_id
        db.session.delete(project)
        db.session.commit()
        flash("Project deleted.", "success")
        return redirect(url_for("client_detail", client_id=client_id, tab="projects"))


app = create_app()

if __name__ == "__main__":
    app.run(debug=True, host="0.0.0.0", port=6019)
