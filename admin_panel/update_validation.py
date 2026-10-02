import hashlib
import json
import zipfile

from app.models import SUPPORTED_OS

REQUIRED_MANIFEST = "update.json"
RESCUE_PREFIX = "rescue/"

MAX_MANIFEST_SIZE = 1024 * 64  # 64KB — plenty for a metadata file, guards against abuse


def sha256_of_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def peek_manifest_version(file_path: str):
    """Best-effort read of the 'version' field baked into a package's own
    update.json, independent of whatever version string was typed into the
    upload form. Used to offer an "Auto-fix version" action when the two
    disagree — returns None (never raises) if the archive, manifest, or
    field can't be read, so callers can just treat that as "nothing to fix"."""
    try:
        with zipfile.ZipFile(file_path) as zf:
            if REQUIRED_MANIFEST not in zf.namelist():
                return None
            info = zf.getinfo(REQUIRED_MANIFEST)
            if info.file_size > MAX_MANIFEST_SIZE:
                return None
            manifest = json.loads(zf.read(REQUIRED_MANIFEST).decode("utf-8"))
            if not isinstance(manifest, dict):
                return None
            version = str(manifest.get("version", "")).strip()
            return version or None
    except (zipfile.BadZipFile, ValueError, UnicodeDecodeError, KeyError, OSError):
        return None


def validate_update_zip(file_path: str, expected_version: str):
    """Runs the checks from spec Section 18 before a package is ever offered
    to an instance: ZIP structure, required files, version consistency,
    OS compatibility declaration, and a Section 17 rescue component that must
    remain available independently of the main application.

    Returns (ok: bool, errors: list[str], metadata: dict).
    Signature/authentication verification (spec Section 18's "Update
    signature/authentication") is deferred to Part 8 alongside the rest of
    the security hardening work — noted here rather than silently skipped.
    """
    errors = []
    metadata = {"version": None, "supported_os": [], "has_rescue": False}

    try:
        zf = zipfile.ZipFile(file_path)
    except zipfile.BadZipFile:
        return False, ["The uploaded file is not a valid ZIP archive."], metadata

    with zf:
        bad_result = zf.testzip()
        if bad_result is not None:
            errors.append(f"Package integrity check failed — corrupt entry: {bad_result}")

        names = zf.namelist()

        # Zip-slip / path traversal protection — never trust archive paths.
        for name in names:
            if name.startswith("/") or ".." in name.split("/"):
                errors.append(f"Rejected unsafe path inside archive: {name}")

        if errors:
            # Don't bother reading further (traversal attempt / corrupt archive)
            # — reject outright rather than continue processing an unsafe file.
            return False, errors, metadata

        if REQUIRED_MANIFEST not in names:
            errors.append(f"Missing required manifest file: {REQUIRED_MANIFEST}")
        else:
            info = zf.getinfo(REQUIRED_MANIFEST)
            if info.file_size > MAX_MANIFEST_SIZE:
                errors.append(f"{REQUIRED_MANIFEST} is implausibly large — refusing to parse it.")
            else:
                try:
                    manifest = json.loads(zf.read(REQUIRED_MANIFEST).decode("utf-8"))
                except (ValueError, UnicodeDecodeError):
                    errors.append(f"{REQUIRED_MANIFEST} is not valid JSON.")
                    manifest = None

                if manifest is not None:
                    if not isinstance(manifest, dict):
                        errors.append(f"{REQUIRED_MANIFEST} must be a JSON object.")
                    else:
                        manifest_version = str(manifest.get("version", "")).strip()
                        supported_os = manifest.get("supported_os")

                        if not manifest_version:
                            errors.append("update.json is missing a 'version' field.")
                        elif manifest_version != expected_version:
                            errors.append(
                                f"update.json version ('{manifest_version}') does not match "
                                f"the version entered on the upload form ('{expected_version}')."
                            )
                        else:
                            metadata["version"] = manifest_version

                        if not isinstance(supported_os, list) or not supported_os:
                            errors.append(
                                "update.json must include a non-empty 'supported_os' list."
                            )
                        else:
                            unknown = [os_name for os_name in supported_os if os_name not in SUPPORTED_OS]
                            if unknown:
                                errors.append(
                                    f"update.json lists unsupported operating systems: {unknown} "
                                    f"(supported: {SUPPORTED_OS})"
                                )
                            else:
                                metadata["supported_os"] = supported_os

        has_rescue = any(name.startswith(RESCUE_PREFIX) and not name.endswith("/") for name in names)
        metadata["has_rescue"] = has_rescue
        if not has_rescue:
            errors.append(
                f"Package has no '{RESCUE_PREFIX}' component — required so the rescue system "
                f"stays available independently of the main application (spec Section 17)."
            )

    ok = len(errors) == 0
    return ok, errors, metadata
