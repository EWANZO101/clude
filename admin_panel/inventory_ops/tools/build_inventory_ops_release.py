"""Builds an inventory-ops release .zip deterministically from
inventory_ops/ itself — same idea as admin_panel/tools/build_kiosk_release.py
(always zip the real, known source tree rather than a hand-picked file), but
standalone: this script and its output never touch admin_panel's own
data/update_packages/ or its Release/Rollout/Instance/Agent pipeline.
Deploying/updating this app happens entirely at the OS level on this
machine, via update.sh and its own systemd unit — see
service_files/systemd/opslab-inventory-ops.service.
"""
import os
import zipfile
from datetime import datetime, timezone

SHIP_ENTRIES = ["run.py", "app", "requirements.txt"]
EXCLUDED_DIR_NAMES = {"__pycache__", ".git", ".pytest_cache", "venv"}
EXCLUDED_SUFFIXES = (".pyc", ".pyo", ".bak")

VERSION_FILE_ARCNAME = os.path.join("app", "version.py")


def _app_dir() -> str:
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _iter_source_files(app_dir: str):
    for entry in SHIP_ENTRIES:
        abs_entry = os.path.join(app_dir, entry)
        if os.path.isfile(abs_entry):
            yield abs_entry, entry
            continue
        if not os.path.isdir(abs_entry):
            raise FileNotFoundError(f"inventory_ops/ is missing expected entry: {entry}")
        for dirpath, dirnames, filenames in os.walk(abs_entry):
            dirnames[:] = [d for d in dirnames if d not in EXCLUDED_DIR_NAMES]
            for filename in filenames:
                if filename.endswith(EXCLUDED_SUFFIXES):
                    continue
                abs_path = os.path.join(dirpath, filename)
                arcname = os.path.relpath(abs_path, app_dir)
                if arcname == VERSION_FILE_ARCNAME:
                    continue  # regenerated fresh below, not copied as-is
                yield abs_path, arcname


def build_inventory_ops_release_zip(version: str, dest_path: str) -> str:
    """Builds a release zip at dest_path from inventory_ops/. Returns dest_path."""
    app_dir = _app_dir()

    os.makedirs(os.path.dirname(dest_path), exist_ok=True)
    tmp_path = dest_path + ".building.tmp"
    try:
        with zipfile.ZipFile(tmp_path, "w", zipfile.ZIP_DEFLATED) as zf:
            for abs_path, arcname in _iter_source_files(app_dir):
                zf.write(abs_path, arcname)

            released = datetime.now(timezone.utc).strftime("%d %b %Y")
            zf.writestr(VERSION_FILE_ARCNAME, f'VERSION = "{version}"\nRELEASED = "{released}"\n')

        os.replace(tmp_path, dest_path)
    finally:
        if os.path.exists(tmp_path):
            os.remove(tmp_path)

    return dest_path


if __name__ == "__main__":
    import sys

    if len(sys.argv) != 3:
        print("Usage: python3 tools/build_inventory_ops_release.py <version> <dest_path.zip>", file=sys.stderr)
        raise SystemExit(2)
    build_inventory_ops_release_zip(sys.argv[1], sys.argv[2])
    print(f"Built {sys.argv[2]}")
