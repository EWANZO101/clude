from datetime import datetime
from flask_sqlalchemy import SQLAlchemy
from flask_login import UserMixin
from werkzeug.security import generate_password_hash, check_password_hash

db = SQLAlchemy()


class User(UserMixin, db.Model):
    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(150), nullable=False)
    email = db.Column(db.String(150), unique=True, nullable=False, index=True)
    password_hash = db.Column(db.String(255), nullable=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    def set_password(self, password):
        self.password_hash = generate_password_hash(password)

    def check_password(self, password):
        return check_password_hash(self.password_hash, password)

# (slug, label, icon-emoji, accepted extensions hint shown to user)
CATEGORIES = [
    ("documents", "Client Documents", "📄"),
    ("contracts", "Contracts & Agreements", "📝"),
    ("pdfs", "PDFs", "📕"),
    ("word", "Word Documents", "📘"),
    ("project_files", "Project Files", "🗂️"),
    ("images", "Images & Photos", "🖼️"),
    ("videos", "Videos", "🎬"),
    ("it", "IT-Related Files", "💻"),
    ("quotes_invoices", "Quotes & Invoices", "💷"),
    ("project_info", "Project Information", "📋"),
    ("completed_work", "Completed Work", "✅"),
    ("other", "Other", "📎"),
]
CATEGORY_SLUGS = [c[0] for c in CATEGORIES]
CATEGORY_LABELS = {c[0]: c[1] for c in CATEGORIES}
CATEGORY_ICONS = {c[0]: c[2] for c in CATEGORIES}

PROJECT_STATUSES = ["Planning", "Active", "On Hold", "Completed"]
CLIENT_STATUSES = ["Active", "Inactive", "Archived"]


class Client(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(150), nullable=False)
    company = db.Column(db.String(150))
    email = db.Column(db.String(150))
    phone = db.Column(db.String(50))
    address = db.Column(db.Text)
    status = db.Column(db.String(20), default="Active")
    summary = db.Column(db.Text)  # short overview / description of the client
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    files = db.relationship("FileItem", backref="client", cascade="all, delete-orphan", lazy="dynamic")
    notes = db.relationship("Note", backref="client", cascade="all, delete-orphan", lazy="dynamic")
    projects = db.relationship("Project", backref="client", cascade="all, delete-orphan", lazy="dynamic")

    @property
    def file_count(self):
        return self.files.count()

    @property
    def initials(self):
        parts = (self.company or self.name).split()
        letters = "".join(p[0] for p in parts[:2] if p)
        return letters.upper() or "?"


class FileItem(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    client_id = db.Column(db.Integer, db.ForeignKey("client.id"), nullable=False)
    category = db.Column(db.String(30), nullable=False, default="other")
    original_filename = db.Column(db.String(300), nullable=False)
    stored_filename = db.Column(db.String(300), nullable=False)
    filesize = db.Column(db.Integer, default=0)
    description = db.Column(db.String(400))
    uploaded_at = db.Column(db.DateTime, default=datetime.utcnow)

    @property
    def category_label(self):
        return CATEGORY_LABELS.get(self.category, "Other")

    @property
    def ext(self):
        return self.original_filename.rsplit(".", 1)[-1].lower() if "." in self.original_filename else ""

    @property
    def is_image(self):
        return self.ext in {"png", "jpg", "jpeg", "gif", "webp", "bmp", "svg"}


class Note(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    client_id = db.Column(db.Integer, db.ForeignKey("client.id"), nullable=False)
    title = db.Column(db.String(200), nullable=False)
    content = db.Column(db.Text)
    pinned = db.Column(db.Boolean, default=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    updated_at = db.Column(db.DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)


class Project(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    client_id = db.Column(db.Integer, db.ForeignKey("client.id"), nullable=False)
    name = db.Column(db.String(200), nullable=False)
    description = db.Column(db.Text)
    status = db.Column(db.String(20), default="Planning")
    due_date = db.Column(db.Date)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
