"""
Agent-side package validation (spec Section 18) — run again independently
after download, never trusting that "the Admin Panel already validated it
at upload time" is enough. A package could in principle be corrupted in
transit even if its SHA-256 matches (extremely unlikely, but the checksum
check below catches that specific case), or the Admin Panel's own record
could theoretically be stale — this module doesn't assume either can't
happen.

Deliberately mirrors app/update_validation.py from the Admin Panel project
(same required update.json + rescue/ structure, same zip-slip protection)
rather than trusting a pre-validated flag from the server.
"""
import hashlib
import json
import zipfile

REQUIRED_MANIFEST = "update.json"
RESCUE_PREFIX = "rescue/"


class PackageValidationError(Exception):
    pass


def sha256_of_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def verify_checksum(path: str, expected_sha256: str) -> None:
    actual = sha256_of_file(path)
    if actual.lower() != expected_sha256.lower():
        raise PackageValidationError(
            f"checksum mismatch: expected {expected_sha256}, got {actual} "
            f"— download may be corrupt or tampered with"
        )


def validate_package_structure(path: str, expected_version: str) -> dict:
    """Returns manifest metadata on success; raises PackageValidationError
    with a specific reason on any failure. Never partially trusts a
    malformed archive — the first structural problem found stops validation."""
    try:
        zf = zipfile.ZipFile(path)
    except zipfile.BadZipFile as e:
        raise PackageValidationError(f"not a valid ZIP archive: {e}") from e

    with zf:
        bad = zf.testzip()
        if bad is not None:
            raise PackageValidationError(f"corrupt entry in archive: {bad}")

        names = zf.namelist()
        for name in names:
            if name.startswith("/") or ".." in name.split("/"):
                raise PackageValidationError(f"unsafe path in archive: {name}")

        if REQUIRED_MANIFEST not in names:
            raise PackageValidationError(f"missing {REQUIRED_MANIFEST}")

        try:
            manifest = json.loads(zf.read(REQUIRED_MANIFEST).decode("utf-8"))
        except (ValueError, UnicodeDecodeError) as e:
            raise PackageValidationError(f"{REQUIRED_MANIFEST} is not valid JSON: {e}") from e

        if not isinstance(manifest, dict):
            raise PackageValidationError(f"{REQUIRED_MANIFEST} must be a JSON object")

        manifest_version = str(manifest.get("version", "")).strip()
        if manifest_version != expected_version:
            raise PackageValidationError(
                f"version mismatch: manifest says {manifest_version!r}, "
                f"expected {expected_version!r}"
            )

        has_rescue = any(n.startswith(RESCUE_PREFIX) and not n.endswith("/") for n in names)
        if not has_rescue:
            raise PackageValidationError(f"missing required '{RESCUE_PREFIX}' component")

        return manifest
