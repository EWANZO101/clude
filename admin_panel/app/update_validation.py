import hashlib
import json
import os
import zipfile

from app.models import SUPPORTED_OS, UpdatePackage

REQUIRED_MANIFEST = "update.json"
RESCUE_PREFIX = "rescue/"

MAX_MANIFEST_SIZE = 1024 * 64  # 64KB — plenty for a metadata file, guards against abuse

# How many of a package's zip entries to keep for the "Package contents" debug
# view on the release detail page — enough to diagnose a real upload mistake
# (a handful of stray files, or an entirely wrong directory tree) without
# storing an unbounded listing for a zip with thousands of entries.
MAX_STORED_FILE_LIST_ENTRIES = 500

# Content firewall — added after the v1.0.2 incident (2026-09-08): a package
# whose *payload* is simply the wrong application sailed straight through
# every check above, because none of them look past "does this zip have the
# shape of a package" to "is this actually the Kiosk App". That upload was,
# byte for byte, a snapshot of the Admin Panel's own source tree (it even
# had its own update.json + rescue/ stapled on) — it had `admin_panel.db`,
# `migrations/`, and Admin-only blueprints sitting right at the top level.
# The checks below would have rejected it immediately.
KIOSK_PACKAGE_ALLOWED_TOP_LEVEL = {"update.json", "run.py", "requirements.txt", "rescue", "app"}

# Any of these appearing ANYWHERE in the archive means this is not the
# Kiosk App — these are Admin-Panel-only names that have no reason to ever
# ship to a kiosk machine.
ADMIN_PANEL_FINGERPRINTS = (
    "admin_panel.db",
    "migrations/",
    "app/blueprints/agent_api.py",
    "app/blueprints/companies.py",
    "app/blueprints/instances.py",
    "app/blueprints/releases.py",
    "app/blueprints/platform.py",
    "app/blueprints/rollouts.py",
    "app/blueprints/dev_files.py",
    "data/dev_file_backups/",
)

# The Kiosk App's own model module always defines this class — its actual
# marker of identity (see kiosk_app/app/models.py). The Admin Panel's
# models.py defines `User` instead, never `LocalUser`.
KIOSK_MODELS_PATH = "app/models.py"
KIOSK_MODELS_MARKER = "class LocalUser"
MAX_ZIP_ENTRY_TEXT_SCAN_BYTES = 1024 * 1024 * 2  # 2MB — a source .py file has no business being bigger


def sha256_of_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def validate_update_zip(file_path: str, expected_version: str, product_id: int = None, supported_os: list = None):
    """Runs the checks from spec Section 18 before a package is ever offered
    to an instance: ZIP structure, required files, version consistency,
    OS compatibility declaration, and a Section 17 rescue component that must
    remain available independently of the main application.

    product_id=None (or the "kiosk" Product's id) runs exactly the checks
    this function has always run — zero behavior change for Kiosk uploads.
    Any OTHER product_id runs only the generic zip-safety checks below
    (_validate_generic_update_zip) instead: the Kiosk-specific fingerprint/
    allowlist/rescue-component rules are meaningless (and would always fail)
    for a package that was never shaped like the Kiosk App in the first
    place, e.g. inventory-ops's release zips.

    Returns (ok: bool, errors: list[str], metadata: dict).
    Signature/authentication verification (spec Section 18's "Update
    signature/authentication") is deferred to Part 8 alongside the rest of
    the security hardening work — noted here rather than silently skipped.
    """
    from app.models import kiosk_product_id

    if product_id is not None and product_id != kiosk_product_id():
        return _validate_generic_update_zip(file_path, expected_version, supported_os=supported_os)
    return _validate_kiosk_update_zip(file_path, expected_version)


def _validate_generic_update_zip(file_path: str, expected_version: str, supported_os: list = None):
    """Minimal safety-only validation for a non-Kiosk product's release zip:
    a valid, uncorrupted archive with no path-traversal entries. Deliberately
    does not require update.json/rescue/ or check for any particular
    application fingerprint — those are Kiosk App packaging conventions,
    not a platform-wide requirement, and a product with its own different
    (and simpler) release shape — see inventory_ops/tools/
    build_inventory_ops_release.py — shouldn't be forced to imitate them.

    supported_os comes straight from the upload form (there's no update.json
    to derive it from here) — passed through as metadata["supported_os"]
    unchanged; the caller is responsible for validating its contents."""
    errors = []
    metadata = {
        "version": expected_version, "supported_os": supported_os or [],
        "has_rescue": False, "file_list": [], "file_list_truncated": False,
    }

    try:
        zf = zipfile.ZipFile(file_path)
    except zipfile.BadZipFile:
        return False, ["The uploaded file is not a valid ZIP archive."], metadata

    with zf:
        bad_result = zf.testzip()
        if bad_result is not None:
            errors.append(f"Package integrity check failed — corrupt entry: {bad_result}")

        names = zf.namelist()
        file_names_only = sorted(n for n in names if not n.endswith("/"))
        metadata["file_list"] = file_names_only[:MAX_STORED_FILE_LIST_ENTRIES]
        metadata["file_list_truncated"] = len(file_names_only) > MAX_STORED_FILE_LIST_ENTRIES

        for name in names:
            if name.startswith("/") or ".." in name.split("/"):
                errors.append(f"Rejected unsafe path inside archive: {name}")

        if errors:
            return False, errors, metadata

        # If a manifest happens to be present, cross-check its version —
        # optional here (unlike the Kiosk path), since not every product's
        # build script writes one.
        if REQUIRED_MANIFEST in names:
            info = zf.getinfo(REQUIRED_MANIFEST)
            if info.file_size <= MAX_MANIFEST_SIZE:
                try:
                    manifest = json.loads(zf.read(REQUIRED_MANIFEST).decode("utf-8"))
                except (ValueError, UnicodeDecodeError):
                    manifest = None
                if isinstance(manifest, dict):
                    manifest_version = str(manifest.get("version", "")).strip()
                    if manifest_version and manifest_version != expected_version:
                        errors.append(
                            f"update.json version ('{manifest_version}') does not match "
                            f"the version entered on the upload form ('{expected_version}')."
                        )

    ok = len(errors) == 0
    return ok, errors, metadata


def _validate_kiosk_update_zip(file_path: str, expected_version: str):
    errors = []
    metadata = {"version": None, "supported_os": [], "has_rescue": False, "file_list": [], "file_list_truncated": False}

    try:
        zf = zipfile.ZipFile(file_path)
    except zipfile.BadZipFile:
        return False, ["The uploaded file is not a valid ZIP archive."], metadata

    with zf:
        bad_result = zf.testzip()
        if bad_result is not None:
            errors.append(f"Package integrity check failed — corrupt entry: {bad_result}")

        names = zf.namelist()

        # Captured up front, before any rejection below, so "what was actually
        # in this upload" (the release detail page's "Package contents" debug
        # view) is available even for a package that fails validation and is
        # rejected outright a few lines down — that's precisely the case
        # someone needs it for.
        file_names_only = sorted(n for n in names if not n.endswith("/"))
        metadata["file_list"] = file_names_only[:MAX_STORED_FILE_LIST_ENTRIES]
        metadata["file_list_truncated"] = len(file_names_only) > MAX_STORED_FILE_LIST_ENTRIES

        # Zip-slip / path traversal protection — never trust archive paths.
        for name in names:
            if name.startswith("/") or ".." in name.split("/"):
                errors.append(f"Rejected unsafe path inside archive: {name}")

        if errors:
            # Don't bother reading further (traversal attempt / corrupt archive)
            # — reject outright rather than continue processing an unsafe file.
            return False, errors, metadata

        # --- content firewall: is this even the Kiosk App? -----------------
        fingerprint_hits = [
            fp for fp in ADMIN_PANEL_FINGERPRINTS
            if any(name == fp or name.startswith(fp) for name in names)
        ]
        if fingerprint_hits:
            errors.append(
                "This package contains files that belong to the Admin Panel, not the "
                f"Kiosk App: {fingerprint_hits}. It looks like the wrong source was "
                "packaged — build the release from kiosk_app/ instead (see "
                "'Build Kiosk Release')."
            )

        top_level = {name.split("/", 1)[0] for name in names if name}
        unexpected_top_level = sorted(top_level - KIOSK_PACKAGE_ALLOWED_TOP_LEVEL)
        if unexpected_top_level:
            errors.append(
                f"Package has unexpected top-level entries not part of the Kiosk App "
                f"shape: {unexpected_top_level} (allowed: {sorted(KIOSK_PACKAGE_ALLOWED_TOP_LEVEL)})."
            )

        if KIOSK_MODELS_PATH not in names:
            errors.append(f"Missing {KIOSK_MODELS_PATH} — every Kiosk App package ships its own models.")
        else:
            info = zf.getinfo(KIOSK_MODELS_PATH)
            if info.file_size <= MAX_ZIP_ENTRY_TEXT_SCAN_BYTES:
                try:
                    models_src = zf.read(KIOSK_MODELS_PATH).decode("utf-8", errors="replace")
                except OSError:
                    models_src = ""
                if KIOSK_MODELS_MARKER not in models_src:
                    errors.append(
                        f"{KIOSK_MODELS_PATH} does not define {KIOSK_MODELS_MARKER!r} — this "
                        "doesn't look like the Kiosk App's own models (wrong payload)."
                    )

        if errors:
            # Same reasoning as the traversal/corruption check above: once we
            # know this isn't even the right application, there's nothing
            # useful left to validate — reject outright.
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


def format_file_listing(metadata: dict) -> str | None:
    """Renders the "file_list" captured by validate_update_zip into the
    newline-joined text stored on UpdatePackage.file_listing and shown as
    the release detail page's "Package contents" debug view — the answer
    to "what files were actually in this upload" for a package that failed
    validation, independent of and alongside the validation_log's list of
    *why* it failed."""
    names = metadata.get("file_list") or []
    if not names:
        return None
    text = "\n".join(names)
    if metadata.get("file_list_truncated"):
        text += f"\n… truncated, first {len(names)} entries only"
    return text


def register_package_from_zip(dest_path: str, version: str, release_notes: str, uploaded_by_id: int,
                               product_id: int = None, supported_os: list = None):
    """Shared tail of every path that turns an on-disk zip into an
    UpdatePackage row (web upload, `flask upload-release`, `flask
    build-kiosk-release`) — one place that always runs the same validation
    (including the content-firewall checks above) so no entry point can
    accidentally skip it. Does NOT add the row to the session or commit —
    callers pair `db.session.add(package)` with their own log_action + commit.

    product_id defaults to the "kiosk" Product when omitted, so every
    existing caller (the CLI commands, which only ever build Kiosk
    releases) needs no change at all to keep working exactly as before.
    supported_os is only used for a non-kiosk product (kiosk always derives
    it from the zip's own update.json, ignoring this param) — there's no
    manifest to read it from otherwise.

    Returns (ok, val_errors, package)."""
    from app.models import kiosk_product_id

    resolved_product_id = product_id if product_id is not None else kiosk_product_id()
    file_size = os.path.getsize(dest_path)
    checksum = sha256_of_file(dest_path)
    ok, val_errors, metadata = validate_update_zip(
        dest_path, expected_version=version, product_id=resolved_product_id, supported_os=supported_os,
    )

    package = UpdatePackage(
        product_id=resolved_product_id,
        version=version,
        release_notes=release_notes or None,
        supported_os=",".join(metadata.get("supported_os") or []),
        file_path=dest_path,
        file_size=file_size,
        checksum_sha256=checksum,
        status="validated" if ok else "invalid",
        validation_log="\n".join(val_errors) if val_errors else None,
        has_rescue_component=metadata.get("has_rescue", False),
        file_listing=format_file_listing(metadata),
        uploaded_by_id=uploaded_by_id,
    )
    return ok, val_errors, package


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


def repair_package(file_path: str, version: str, supported_os: list, donor_rescue_files: dict) -> str:
    """General-purpose structural repair for a package that failed
    validation because it's missing update.json and/or a rescue/
    component — NOT for a version mismatch inside an otherwise-present
    manifest (see peek_manifest_version / the Auto-fix version action for
    that case).

    Rewrites the zip at file_path in place: drops any existing (missing,
    broken, or partial) update.json and rescue/* entries, then writes a
    fresh manifest for this package's own version/supported_os and the
    rescue/ files copied byte-for-byte from a known-good donor package.
    Everything else in the archive is carried over untouched.

    This can't fix a package whose actual payload is wrong (e.g. the
    wrong directory got zipped up) — it only makes the archive
    structurally complete enough to pass validate_update_zip. Returns the
    sha256 of the rewritten file.
    """
    tmp_path = file_path + ".repair.tmp"
    with zipfile.ZipFile(file_path) as src, zipfile.ZipFile(tmp_path, "w", zipfile.ZIP_DEFLATED) as dst:
        for item in src.infolist():
            name = item.filename
            if name == REQUIRED_MANIFEST or name.startswith(RESCUE_PREFIX):
                continue  # dropped — replaced below with known-good versions
            dst.writestr(item, src.read(name))

        manifest = json.dumps({"version": version, "supported_os": supported_os}, indent=2)
        dst.writestr(REQUIRED_MANIFEST, manifest)

        for rescue_name, rescue_bytes in donor_rescue_files.items():
            dst.writestr(rescue_name, rescue_bytes)

    os.replace(tmp_path, file_path)
    return sha256_of_file(file_path)
