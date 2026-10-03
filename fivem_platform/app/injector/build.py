import io
import os
import re
import zipfile
import hashlib

from app.injector.templates import render_platform_files, FXMANIFEST_INJECTION


class InjectorError(ValueError):
    """Raised when the uploaded zip isn't a usable FiveM resource."""


MAX_UPLOAD_BYTES = 50 * 1024 * 1024  # 50MB, generous for a script resource


def _find_fxmanifest(names):
    """Finds the shallowest fxmanifest.lua (or .fxmanifest.lua / __resource.lua
    for older resources) in the zip. Returns (manifest_path, root_dir)."""
    candidates = [
        n for n in names
        if os.path.basename(n).lower() in ("fxmanifest.lua", "__resource.lua")
    ]
    if not candidates:
        return None, None

    # Prefer the one with the fewest path segments (closest to zip root).
    candidates.sort(key=lambda n: n.count("/"))
    manifest_path = candidates[0]
    root_dir = os.path.dirname(manifest_path)
    root_dir = root_dir + "/" if root_dir else ""
    return manifest_path, root_dir


def _sanitize_resource_name(name: str) -> str:
    name = re.sub(r"[^a-zA-Z0-9_-]", "_", name).strip("_")
    return name or "protected_resource"


def extract_modules_from_upload(upload_bytes: bytes):
    """Reads every client/server/shared script referenced in the uploaded
    resource's fxmanifest.lua and returns a list of
    {'name': slug, 'side': 'client'|'server', 'code': str, 'source_path': str}
    ready to be published as Modules - this is what makes an upload
    immediately deliverable through CloudLoader's API with no separate
    zip/file-install step. Shared scripts are returned twice (once per
    side) since Module.side is single-valued.

    Raises InjectorError under the same conditions as build_protected_package.
    """
    from app.injector.manifest import parse_manifest_scripts

    try:
        source_zip = zipfile.ZipFile(io.BytesIO(upload_bytes))
    except zipfile.BadZipFile:
        raise InjectorError("That doesn't look like a valid .zip file.")

    names = [n for n in source_zip.namelist() if not n.endswith("/")]
    manifest_path, root_dir = _find_fxmanifest(names)
    if manifest_path is None:
        raise InjectorError(
            "No fxmanifest.lua (or __resource.lua) found. This doesn't look "
            "like a FiveM resource."
        )

    manifest_text = source_zip.read(manifest_path).decode("utf-8", errors="replace")
    scripts = parse_manifest_scripts(manifest_text)

    def slugify(path):
        base = re.sub(r"\.lua$", "", path, flags=re.IGNORECASE)
        return re.sub(r"[^a-zA-Z0-9_]", "_", base).strip("_").lower() or "module"

    modules = []

    def add(path, side, name_suffix=""):
        full_path = root_dir + path
        if full_path not in source_zip.namelist():
            return  # referenced in manifest but not actually in the zip - skip quietly
        code = source_zip.read(full_path).decode("utf-8", errors="replace")
        modules.append({
            "name": slugify(path) + name_suffix,
            "side": side,
            "code": code,
            "source_path": path,
        })

    for path in scripts["server"]:
        add(path, "server")
    for path in scripts["client"]:
        add(path, "client")
    for path in scripts["shared"]:
        # Shared scripts become two modules (one per side) - suffix the name
        # so they don't collide with the one-name-per-product uniqueness.
        add(path, "server", name_suffix="_server")
        add(path, "client", name_suffix="_client")

    return modules


def build_protected_package(upload_bytes: bytes, product, site_name: str, api_base: str):
    """Takes the raw bytes of a developer's uploaded script.zip and a Product,
    returns (protected_zip_bytes, resource_name, checksum_sha256).

    Raises InjectorError with a human-readable message if the zip doesn't
    look like a valid FiveM resource.
    """
    if len(upload_bytes) > MAX_UPLOAD_BYTES:
        raise InjectorError("File is too large (max 50MB).")

    try:
        source_zip = zipfile.ZipFile(io.BytesIO(upload_bytes))
    except zipfile.BadZipFile:
        raise InjectorError("That doesn't look like a valid .zip file.")

    if source_zip.testzip() is not None:
        raise InjectorError("The zip file is corrupted.")

    names = [n for n in source_zip.namelist() if not n.endswith("/")]
    if not names:
        raise InjectorError("The zip file is empty.")

    manifest_path, root_dir = _find_fxmanifest(names)
    if manifest_path is None:
        raise InjectorError(
            "No fxmanifest.lua (or __resource.lua) found. This doesn't look "
            "like a FiveM resource."
        )

    resource_name = _sanitize_resource_name(
        root_dir.rstrip("/") if root_dir else product.product_id.lower()
    )

    original_manifest = source_zip.read(manifest_path).decode("utf-8", errors="replace")

    platform_files = render_platform_files(
        site_name=site_name,
        api_base=api_base,
        product_id=product.product_id,
        api_key=product.api_key,
        product_version=product.version,
    )

    injected_manifest = original_manifest.rstrip() + "\n" + FXMANIFEST_INJECTION.format(site_name=site_name)

    out_buffer = io.BytesIO()
    with zipfile.ZipFile(out_buffer, "w", zipfile.ZIP_DEFLATED) as out_zip:
        # Copy every original file as-is, except the manifest which gets the
        # injection appended.
        for name in names:
            data = source_zip.read(name)
            if name == manifest_path:
                out_zip.writestr(name, injected_manifest)
            else:
                out_zip.writestr(name, data)

        # Add the platform/ folder under the same root the resource lives in.
        for rel_path, content in platform_files.items():
            out_zip.writestr(root_dir + rel_path, content)

    protected_bytes = out_buffer.getvalue()
    checksum = hashlib.sha256(protected_bytes).hexdigest()

    return protected_bytes, resource_name, checksum
