import os
import uuid

from flask import current_app

from app.utils.validators import validate_file_upload, ALLOWED_IMAGE_EXTENSIONS, ALLOWED_UPLOAD_EXTENSIONS


def save_public_image(file_storage, subdir):
    """Saves an uploaded image under app/static/uploads/<subdir>/ (publicly
    servable — for marketplace-facing photos only, never for private
    documents) and returns a path relative to the static folder."""
    is_valid, error = validate_file_upload(file_storage, ALLOWED_IMAGE_EXTENSIONS)
    if not is_valid:
        return None, error

    ext = file_storage.filename.rsplit(".", 1)[1].lower()
    filename = f"{uuid.uuid4().hex}.{ext}"
    target_dir = os.path.join(current_app.static_folder, "uploads", subdir)
    os.makedirs(target_dir, exist_ok=True)
    file_storage.save(os.path.join(target_dir, filename))
    return f"uploads/{subdir}/{filename}", None


def save_private_file(file_storage, subdir):
    """Saves an uploaded file under the instance folder (outside the public
    static/ tree) for private documents such as equipment photos, inspection
    reports and shipping paperwork. Returns a path relative to UPLOAD_DIR."""
    is_valid, error = validate_file_upload(file_storage, ALLOWED_UPLOAD_EXTENSIONS)
    if not is_valid:
        return None, error

    ext = file_storage.filename.rsplit(".", 1)[1].lower()
    filename = f"{uuid.uuid4().hex}.{ext}"
    upload_root = current_app.config["UPLOAD_DIR"]
    if not os.path.isabs(upload_root):
        upload_root = os.path.join(current_app.instance_path, "..", upload_root)
    target_dir = os.path.join(upload_root, subdir)
    os.makedirs(target_dir, exist_ok=True)
    file_storage.save(os.path.join(target_dir, filename))
    return f"{subdir}/{filename}", None
