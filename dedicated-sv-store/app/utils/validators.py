import os
import re

EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")

ALLOWED_IMAGE_EXTENSIONS = {"png", "jpg", "jpeg", "gif", "webp"}
ALLOWED_DOCUMENT_EXTENSIONS = {"pdf", "doc", "docx", "xls", "xlsx", "csv", "txt"}
ALLOWED_UPLOAD_EXTENSIONS = ALLOWED_IMAGE_EXTENSIONS | ALLOWED_DOCUMENT_EXTENSIONS

MAX_UPLOAD_SIZE_BYTES = 20 * 1024 * 1024


def is_valid_email(value):
    return bool(value and EMAIL_RE.match(value))


def is_strong_password(value):
    if not value or len(value) < 10:
        return False
    has_letter = any(c.isalpha() for c in value)
    has_digit = any(c.isdigit() for c in value)
    return has_letter and has_digit


def allowed_file(filename, allowed_extensions=None):
    if not filename or "." not in filename:
        return False
    ext = filename.rsplit(".", 1)[1].lower()
    return ext in (allowed_extensions or ALLOWED_UPLOAD_EXTENSIONS)


def safe_filename(filename):
    from werkzeug.utils import secure_filename

    name = secure_filename(filename)
    return name or "file"


def validate_file_upload(file_storage, allowed_extensions=None, max_size=None):
    """Returns (is_valid, error_message)."""
    if file_storage is None or file_storage.filename == "":
        return False, "No file provided."

    if not allowed_file(file_storage.filename, allowed_extensions):
        return False, "File type is not permitted."

    file_storage.stream.seek(0, os.SEEK_END)
    size = file_storage.stream.tell()
    file_storage.stream.seek(0)
    if size > (max_size or MAX_UPLOAD_SIZE_BYTES):
        return False, "File is too large."

    return True, None
