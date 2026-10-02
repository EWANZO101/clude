"""Storage + validation for ticket attachments (images and videos from 1 second to 5 minutes).

Files live outside the app tree (UPLOAD_ROOT, default /var/lib/opslabs/uploads)
so nginx can serve them via X-Accel-Redirect after Flask checks permissions.
"""
import os
import time
import uuid

UPLOAD_ROOT = os.environ.get("UPLOAD_ROOT", "/var/lib/opslabs/uploads")
MAX_UPLOAD_BYTES = int(os.environ.get("MAX_UPLOAD_BYTES", 2 * 1024 ** 3))   # 2 GB
CHUNK_BYTES = 8 * 1024 * 1024                                              # 8 MB per request
VIDEO_MIN_SECONDS = 1
VIDEO_MAX_SECONDS = 300
PARTIAL_MAX_AGE = 24 * 3600

IMAGE_TYPES = {
    "jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png",
    "gif": "image/gif", "webp": "image/webp", "bmp": "image/bmp",
    "heic": "image/heic", "heif": "image/heif", "avif": "image/avif",
}
VIDEO_TYPES = {
    "mp4": "video/mp4", "m4v": "video/mp4", "mov": "video/quicktime",
    "webm": "video/webm", "mkv": "video/x-matroska", "avi": "video/x-msvideo",
}


class UploadError(ValueError):
    pass


def _ensure_dir(path):
    os.makedirs(path, mode=0o755, exist_ok=True)
    return path


def partial_path(stored_name):
    return os.path.join(_ensure_dir(os.path.join(UPLOAD_ROOT, "partial")), stored_name)


def final_path(ticket_id, stored_name):
    d = _ensure_dir(os.path.join(UPLOAD_ROOT, "tickets", str(int(ticket_id))))
    return os.path.join(d, stored_name)


def final_relpath(ticket_id, stored_name):
    return f"tickets/{int(ticket_id)}/{stored_name}"


def classify(filename, size):
    """Validate name/size up front. Returns (kind, ext, mime, stored_name)."""
    ext = filename.rsplit(".", 1)[-1].lower() if "." in filename else ""
    if ext in IMAGE_TYPES:
        kind, mime = "image", IMAGE_TYPES[ext]
    elif ext in VIDEO_TYPES:
        kind, mime = "video", VIDEO_TYPES[ext]
    else:
        raise UploadError("Only images (JPG, PNG, GIF, WebP, HEIC, AVIF, BMP) "
                          "and videos (MP4, MOV, WebM, MKV, AVI) can be attached.")
    if not isinstance(size, int) or size <= 0:
        raise UploadError("File is empty.")
    if size > MAX_UPLOAD_BYTES:
        raise UploadError(f"File is too large (max {MAX_UPLOAD_BYTES // 1024 ** 3} GB).")
    return kind, ext, mime, f"{uuid.uuid4().hex}.{ext}"


def _looks_like_image(path, ext):
    with open(path, "rb") as f:
        head = f.read(32)
    if head.startswith(b"\xff\xd8\xff"):
        return ext in ("jpg", "jpeg")
    if head.startswith(b"\x89PNG\r\n\x1a\n"):
        return ext == "png"
    if head[:6] in (b"GIF87a", b"GIF89a"):
        return ext == "gif"
    if head[:4] == b"RIFF" and head[8:12] == b"WEBP":
        return ext == "webp"
    if head[:2] == b"BM":
        return ext == "bmp"
    if head[4:8] == b"ftyp":
        brand = head[8:12]
        if ext in ("heic", "heif"):
            return brand in (b"heic", b"heix", b"hevc", b"heim", b"heis", b"mif1", b"msf1")
        if ext == "avif":
            return brand in (b"avif", b"avis", b"mif1")
    return False


def probe_video(path):
    """Return duration in seconds if the file is a real video, else raise."""
    try:
        import av
    except ImportError:                               # pragma: no cover
        raise UploadError("Video checking isn't available on the server.")
    try:
        with av.open(path) as c:
            fmt = (c.format.name or "").lower()
            if "pipe" in fmt or fmt in ("image2", "gif", "apng", "webp"):
                raise UploadError("That file is an image, not a video.")
            vstreams = [s for s in c.streams if s.type == "video"]
            if not vstreams:
                raise UploadError("That file has no video track.")
            if c.duration:
                return c.duration / 1_000_000          # av.time_base is microseconds
            s = vstreams[0]
            if s.duration and s.time_base:
                return float(s.duration * s.time_base)
    except UploadError:
        raise
    except Exception:
        raise UploadError("That file couldn't be read as a video.")
    raise UploadError("Couldn't work out how long that video is.")


def verify(path, kind, ext):
    """Content check once all bytes are in. Returns duration (videos) or None."""
    if kind == "image":
        if not _looks_like_image(path, ext):
            raise UploadError("That file isn't a valid image.")
        return None
    duration = probe_video(path)
    if duration < VIDEO_MIN_SECONDS or duration > VIDEO_MAX_SECONDS:
        length = (f"{duration:.1f} seconds" if duration < 60
                  else f"{int(duration // 60)}:{int(duration % 60):02d}")
        raise UploadError(f"Videos must be between 1 second and 5 minutes long (this one is {length}).")
    return duration


def sweep_partials():
    """Delete abandoned half-uploads older than a day."""
    d = os.path.join(UPLOAD_ROOT, "partial")
    if not os.path.isdir(d):
        return
    cutoff = time.time() - PARTIAL_MAX_AGE
    for name in os.listdir(d):
        p = os.path.join(d, name)
        try:
            if os.path.getmtime(p) < cutoff:
                os.remove(p)
        except OSError:
            pass
