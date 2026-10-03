import os
import uuid
from werkzeug.utils import secure_filename
from flask import current_app
from flask_wtf.file import FileField, MultipleFileField


def apply_form(form, obj, exclude=()):
    """Copy form field data onto obj, skipping file fields, CSRF token, and
    any field name in `exclude` (use this for fields that collide with a
    SQLAlchemy relationship attribute name, e.g. 'documents' or 'photos')."""
    skip = {"csrf_token"} | set(exclude)
    for name, field in form._fields.items():
        if name in skip:
            continue
        if isinstance(field, (FileField, MultipleFileField)):
            continue
        setattr(obj, name, field.data)


def save_upload(file_storage, subfolder="misc"):
    """Save an uploaded FileStorage to instance uploads, return stored filename (relative)."""
    if not file_storage or not file_storage.filename:
        return None
    original = secure_filename(file_storage.filename)
    ext = original.rsplit(".", 1)[-1].lower() if "." in original else ""
    if ext not in current_app.config["ALLOWED_EXTENSIONS"]:
        return None
    stored_name = f"{uuid.uuid4().hex}.{ext}" if ext else uuid.uuid4().hex
    folder = os.path.join(current_app.config["UPLOAD_FOLDER"], subfolder)
    os.makedirs(folder, exist_ok=True)
    file_storage.save(os.path.join(folder, stored_name))
    return f"{subfolder}/{stored_name}"


def save_uploads(file_storages, subfolder="misc"):
    saved = []
    for f in file_storages or []:
        rel = save_upload(f, subfolder=subfolder)
        if rel:
            saved.append(rel)
    return saved


def delete_upload(rel_path):
    if not rel_path:
        return
    full = os.path.join(current_app.config["UPLOAD_FOLDER"], rel_path)
    if os.path.exists(full):
        try:
            os.remove(full)
        except OSError:
            pass
