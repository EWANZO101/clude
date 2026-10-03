import os
import uuid

from flask import current_app

ALLOWED_EXTENSIONS = {"pdf", "png", "jpg", "jpeg", "doc", "docx", "txt"}


def allowed_file(filename):
    return "." in filename and filename.rsplit(".", 1)[1].lower() in ALLOWED_EXTENSIONS


def save_upload(file_storage):
    """Saves an uploaded werkzeug FileStorage under a UUID name (never trust
    the original filename for the on-disk path). Returns the stored filename,
    or None if the file type isn't allowed."""
    if not file_storage or not file_storage.filename or not allowed_file(file_storage.filename):
        return None
    ext = file_storage.filename.rsplit(".", 1)[1].lower()
    stored_name = f"{uuid.uuid4()}.{ext}"
    dest = os.path.join(current_app.config["UPLOAD_FOLDER"], stored_name)
    file_storage.save(dest)
    return stored_name


def upload_path(stored_filename):
    return os.path.join(current_app.config["UPLOAD_FOLDER"], stored_filename)
