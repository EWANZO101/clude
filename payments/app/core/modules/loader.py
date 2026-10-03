"""Module install/enable/disable/uninstall pipeline.

Simplifications vs the full spec (tracked in REMAINING_WORK.txt):
- Runs in-process; blueprint registration is dynamic but Flask cannot
  un-register a blueprint at runtime, so disabling a module hides it from
  nav/health but a full unload needs an app restart.
- Third-party pip dependencies listed in the manifest are installed via a
  subprocess pip call into the current environment (no per-module venv
  isolation yet).
- Signature/publisher verification is not implemented; only structural and
  path-traversal safety checks are performed.
"""
import importlib
import importlib.util
import json
import logging
import os
import shutil
import subprocess
import sys
import zipfile

import yaml

from flask import current_app
from app.extensions import db
from app.core.modules.models import ModuleRecord, ModuleVersion, ModuleLogEntry
from app.core.database.models import NavItem
from app.core.events.bus import emit

logger = logging.getLogger(__name__)

REQUIRED_MANIFEST_FIELDS = ["id", "name", "version", "core_compatibility"]
CORE_VERSION = "0.5.0"


class ModuleInstallError(Exception):
    pass


def _log(module_id, message, level="info"):
    db.session.add(ModuleLogEntry(module_id=module_id, message=message, level=level))
    db.session.commit()
    getattr(logger, level, logger.info)(f"[module:{module_id}] {message}")


def _packages_dir():
    return current_app.config.get("MODULE_PACKAGE_FOLDER") or os.path.join(
        current_app.root_path, "..", "module_packages"
    )


def _safe_extract(zf: zipfile.ZipFile, dest_dir: str):
    dest_dir = os.path.realpath(dest_dir)
    for member in zf.infolist():
        member_path = os.path.realpath(os.path.join(dest_dir, member.filename))
        if not member_path.startswith(dest_dir + os.sep) and member_path != dest_dir:
            raise ModuleInstallError(f"Unsafe path in module ZIP: {member.filename}")
    zf.extractall(dest_dir)


def _load_manifest(module_dir):
    manifest_path = os.path.join(module_dir, "manifest.yaml")
    if not os.path.isfile(manifest_path):
        raise ModuleInstallError("manifest.yaml not found in module ZIP")
    with open(manifest_path) as f:
        manifest = yaml.safe_load(f) or {}
    for field in REQUIRED_MANIFEST_FIELDS:
        if field not in manifest:
            raise ModuleInstallError(f"manifest.yaml missing required field: {field}")
    return manifest


def _check_compatibility(manifest):
    required = manifest.get("core_compatibility", "")
    # Simple prefix-compatible check (e.g. "0.x" or exact major.minor match).
    if required and not (required.startswith(CORE_VERSION.split(".")[0]) or required == "*"):
        raise ModuleInstallError(
            f"Module requires core {required}, running {CORE_VERSION}"
        )


def install_from_zip(file_path, replace_existing=False):
    packages_root = _packages_dir()
    os.makedirs(packages_root, exist_ok=True)

    with zipfile.ZipFile(file_path) as zf:
        names = zf.namelist()
        if not any(n.endswith("manifest.yaml") for n in names):
            raise ModuleInstallError("ZIP does not contain a manifest.yaml")

        tmp_extract = os.path.join(packages_root, "_tmp_install")
        if os.path.isdir(tmp_extract):
            shutil.rmtree(tmp_extract)
        _safe_extract(zf, tmp_extract)

    # manifest.yaml may be at the root or one level down inside a folder.
    manifest_dir = tmp_extract
    if not os.path.isfile(os.path.join(tmp_extract, "manifest.yaml")):
        subdirs = [d for d in os.listdir(tmp_extract) if os.path.isdir(os.path.join(tmp_extract, d))]
        for d in subdirs:
            if os.path.isfile(os.path.join(tmp_extract, d, "manifest.yaml")):
                manifest_dir = os.path.join(tmp_extract, d)
                break

    manifest = _load_manifest(manifest_dir)
    _check_compatibility(manifest)

    module_id = manifest["id"]
    final_dir = os.path.join(packages_root, module_id)

    existing = db.session.get(ModuleRecord, module_id)
    if existing and not replace_existing:
        shutil.rmtree(tmp_extract)
        raise ModuleInstallError(f"Module '{module_id}' is already installed")

    if os.path.isdir(final_dir):
        shutil.rmtree(final_dir)
    shutil.move(manifest_dir, final_dir)
    if os.path.isdir(tmp_extract):
        shutil.rmtree(tmp_extract, ignore_errors=True)

    deps = manifest.get("dependencies", []) or []
    for dep in deps:
        try:
            subprocess.run([sys.executable, "-m", "pip", "install", "--break-system-packages", dep],
                            check=True, capture_output=True, timeout=180)
        except Exception as e:
            _log(module_id, f"Dependency install failed for {dep}: {e}", level="error")

    if existing:
        existing.name = manifest["name"]
        existing.description = manifest.get("description", "")
        existing.version = manifest["version"]
        existing.author = manifest.get("author", "")
        existing.core_compatibility = manifest["core_compatibility"]
        existing.status = "installed"
        existing.manifest_json = json.dumps(manifest)
        record = existing
    else:
        record = ModuleRecord(
            id=module_id, name=manifest["name"], description=manifest.get("description", ""),
            version=manifest["version"], author=manifest.get("author", ""),
            core_compatibility=manifest["core_compatibility"], status="installed",
            manifest_json=json.dumps(manifest),
        )
        db.session.add(record)

    db.session.add(ModuleVersion(module_id=module_id, version=manifest["version"]))
    db.session.commit()

    run_migrations(module_id)
    _log(module_id, f"Installed version {manifest['version']}")
    emit("module.installed", module_id=module_id, version=manifest["version"])
    return record


def _ensure_on_path():
    packages_root = os.path.realpath(_packages_dir())
    if packages_root not in sys.path:
        sys.path.insert(0, packages_root)
    importlib.invalidate_caches()


def run_migrations(module_id):
    module_dir = os.path.join(_packages_dir(), module_id)
    models_path = os.path.join(module_dir, "models.py")
    if not os.path.isfile(models_path):
        return
    try:
        _ensure_on_path()
        importlib.import_module(f"{module_id}.models")
        db.create_all()
        record = db.session.get(ModuleRecord, module_id)
        if record:
            record.migration_status = "complete"
            db.session.commit()
    except Exception as e:
        _log(module_id, f"Migration failed: {e}", level="error")
        record = db.session.get(ModuleRecord, module_id)
        if record:
            record.migration_status = "failed"
            db.session.commit()


def enable(app, module_id):
    record = db.session.get(ModuleRecord, module_id)
    if not record:
        raise ModuleInstallError("Module not installed")

    module_dir = os.path.join(_packages_dir(), module_id)
    routes_path = os.path.join(module_dir, "routes.py")

    if os.path.isfile(routes_path):
        _ensure_on_path()
        mod = importlib.import_module(f"{module_id}.routes")
        bp = getattr(mod, "bp", None)
        # Convention: module routes.py declares `bp = Blueprint(<module_id>, __name__, ...)`
        # so url_for('<module_id>.<endpoint>') works unmodified inside the module's own
        # templates/routes. We register as-is and only skip if already registered.
        if bp is not None and bp.name not in app.blueprints:
            app.register_blueprint(bp)

    manifest = json.loads(record.manifest_json or "{}")
    for nav in manifest.get("navigation", []):
        existing_nav = NavItem.query.filter_by(module_id=module_id, label=nav["label"]).first()
        if not existing_nav:
            db.session.add(NavItem(
                module_id=module_id, label=nav["label"], icon=nav.get("icon", ""),
                url=nav["url"], position=nav.get("position", 50),
            ))

    record.status = "enabled"
    db.session.commit()
    _log(module_id, "Enabled")
    return record


def disable(module_id):
    record = db.session.get(ModuleRecord, module_id)
    if not record:
        raise ModuleInstallError("Module not installed")
    record.status = "disabled"
    NavItem.query.filter_by(module_id=module_id).update({"enabled": False})
    db.session.commit()
    _log(module_id, "Disabled (routes remain loaded until restart)")
    emit("module.disabled", module_id=module_id)
    return record


def uninstall(module_id, delete_data=False):
    record = db.session.get(ModuleRecord, module_id)
    if not record:
        raise ModuleInstallError("Module not installed")

    NavItem.query.filter_by(module_id=module_id).delete()
    ModuleVersion.query.filter_by(module_id=module_id).delete()
    db.session.delete(record)
    db.session.commit()

    module_dir = os.path.join(_packages_dir(), module_id)
    if delete_data and os.path.isdir(module_dir):
        shutil.rmtree(module_dir)
    _log(module_id, f"Uninstalled (data {'deleted' if delete_data else 'retained'})")


def load_enabled_modules(app):
    """Called at app startup to re-register blueprints for already-enabled modules."""
    with app.app_context():
        try:
            enabled = ModuleRecord.query.filter_by(status="enabled").all()
        except Exception:
            return
        for record in enabled:
            try:
                enable(app, record.id)
            except Exception:
                logger.exception("Failed to load module %s on startup", record.id)
