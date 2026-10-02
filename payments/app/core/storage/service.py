import os
import uuid

from flask import current_app
from werkzeug.utils import secure_filename

from app.extensions import db
from app.core.storage.models import StoredFile

ALLOWED_EXTENSIONS = {
    "bank_statement": {"csv", "ofx", "qfx", "pdf"},
    "module_zip": {"zip"},
    "backup": {"zip", "json", "sql"},
    "checklist_doc": {"txt", "csv", "md"},
    "other": {"csv", "json", "txt", "pdf", "png", "jpg", "jpeg"},
}


def _ext(filename):
    return filename.rsplit(".", 1)[-1].lower() if "." in filename else ""


def save_upload(file_storage, purpose="other", user=None, module_id=None):
    filename = secure_filename(file_storage.filename or "upload")
    ext = _ext(filename)

    allowed = ALLOWED_EXTENSIONS.get(purpose, ALLOWED_EXTENSIONS["other"])
    if ext not in allowed:
        raise ValueError(f"File type .{ext} is not allowed for {purpose}")

    stored_name = f"{uuid.uuid4().hex}.{ext}" if ext else uuid.uuid4().hex
    dest_dir = os.path.join(current_app.config["UPLOAD_FOLDER"], purpose)
    os.makedirs(dest_dir, exist_ok=True)
    dest_path = os.path.join(dest_dir, stored_name)
    file_storage.save(dest_path)

    record = StoredFile(
        user_id=user.id if user else None,
        module_id=module_id,
        original_filename=filename,
        stored_filename=os.path.join(purpose, stored_name),
        content_type=file_storage.content_type,
        size_bytes=os.path.getsize(dest_path),
        purpose=purpose,
    )
    db.session.add(record)
    db.session.commit()
    return record, dest_path


def file_path(stored_file):
    return os.path.join(current_app.config["UPLOAD_FOLDER"], stored_file.stored_filename)
