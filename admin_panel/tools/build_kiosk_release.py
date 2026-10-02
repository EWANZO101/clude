"""
Builds a Kiosk App release .zip deterministically from kiosk_app/ — the one
and only real Kiosk App source tree (see OWNERSHIP.md) — instead of relying
on a human to hand-pick and upload some .zip file from wherever.

This is the fix for how the v1.0.2 incident (2026-09-08) was even possible:
that release was a manually-uploaded zip that happened to be a snapshot of
the Admin Panel's own source tree instead of the Kiosk App. A build script
that always zips the same known directory, in the same shape the Agent
expects (run.py + app/ + requirements.txt at the zip root, plus update.json
and rescue/ added here), cannot produce that class of mistake — the
worst case is "the current kiosk_app/ has a bug in it", not "this is a
completely different application".

The output still goes through app/update_validation.py::validate_update_zip
(including its content-firewall checks) before being offered as a release —
this script does not bypass that, it just makes "build from the real
source" the normal, low-effort path so nobody reaches for a stray zip.
"""
import json
import os
import shutil
import zipfile
from datetime import datetime, timezone

KIOSK_APP_DIRNAME = "kiosk_app"
KIOSK_SHIP_ENTRIES = ["run.py", "app", "requirements.txt"]

EXCLUDED_DIR_NAMES = {"__pycache__", ".git", ".pytest_cache"}
EXCLUDED_SUFFIXES = (".pyc", ".pyo", ".bak")

# app/version.py is what kiosk_app/app/__init__.py actually reads for the
# footer's "app_version"/"app_released" and the /health endpoint's
# "version" field — NOT update.json below (that's only ever read by the
# Admin Panel/Agent's own update pipeline, never by the running Kiosk App
# itself). Left as a plain on-disk file, it was a frozen snapshot from
# whenever someone last hand-edited it (VERSION="1.0.1", RELEASED=
# "unreleased (rewrite in progress)" — stale since before this build
# script existed) that every release since has shipped completely
# unchanged, because the generic file walk below just copies whatever's
# on disk. Regenerated here instead, from the same `version` this build
# is actually being built as, so the two can never drift apart again.
VERSION_FILE_ARCNAME = os.path.join("app", "version.py")


def _repo_root() -> str:
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _kiosk_app_dir() -> str:
    return os.path.join(_repo_root(), KIOSK_APP_DIRNAME)


def _iter_source_files(kiosk_app_dir: str):
    for entry in KIOSK_SHIP_ENTRIES:
        abs_entry = os.path.join(kiosk_app_dir, entry)
        if os.path.isfile(abs_entry):
            yield abs_entry, entry
            continue
        if not os.path.isdir(abs_entry):
            raise FileNotFoundError(f"kiosk_app/ is missing expected entry: {entry}")
        for dirpath, dirnames, filenames in os.walk(abs_entry):
            dirnames[:] = [d for d in dirnames if d not in EXCLUDED_DIR_NAMES]
            for filename in filenames:
                if filename.endswith(EXCLUDED_SUFFIXES):
                    continue
                abs_path = os.path.join(dirpath, filename)
                arcname = os.path.relpath(abs_path, kiosk_app_dir)
                if arcname == VERSION_FILE_ARCNAME:
                    continue  # regenerated fresh in build_kiosk_release_zip below, not copied as-is
                yield abs_path, arcname


def build_kiosk_release_zip(version: str, dest_path: str, supported_os=None, rescue_dir: str = None) -> str:
    """Builds a release zip at dest_path from kiosk_app/. Returns dest_path.

    supported_os defaults to ["windows"] (the only OS the Kiosk App ships
    for today). rescue_dir defaults to kiosk_app/rescue/ — pass a different
    directory only to test against a donor rescue component."""
    supported_os = supported_os or ["windows"]
    kiosk_app_dir = _kiosk_app_dir()
    rescue_dir = rescue_dir or os.path.join(kiosk_app_dir, "rescue")

    if not os.path.isdir(rescue_dir):
        raise FileNotFoundError(f"Rescue component directory not found: {rescue_dir}")

    os.makedirs(os.path.dirname(dest_path), exist_ok=True)
    tmp_path = dest_path + ".building.tmp"
    try:
        with zipfile.ZipFile(tmp_path, "w", zipfile.ZIP_DEFLATED) as zf:
            for abs_path, arcname in _iter_source_files(kiosk_app_dir):
                zf.write(abs_path, arcname)

            released = datetime.now(timezone.utc).strftime("%d %b %Y")
            zf.writestr(
                VERSION_FILE_ARCNAME,
                f'VERSION = "{version}"\nRELEASED = "{released}"\n',
            )

            for dirpath, dirnames, filenames in os.walk(rescue_dir):
                dirnames[:] = [d for d in dirnames if d not in EXCLUDED_DIR_NAMES]
                for filename in filenames:
                    if filename.endswith(EXCLUDED_SUFFIXES):
                        continue
                    abs_path = os.path.join(dirpath, filename)
                    arcname = "rescue/" + os.path.relpath(abs_path, rescue_dir)
                    zf.write(abs_path, arcname)

            manifest = json.dumps({"version": version, "supported_os": supported_os}, indent=2)
            zf.writestr("update.json", manifest)

        os.replace(tmp_path, dest_path)
    finally:
        if os.path.exists(tmp_path):
            os.remove(tmp_path)

    return dest_path


if __name__ == "__main__":
    import sys

    if len(sys.argv) != 3:
        print("Usage: python3 tools/build_kiosk_release.py <version> <dest_path.zip>", file=sys.stderr)
        raise SystemExit(2)
    build_kiosk_release_zip(sys.argv[1], sys.argv[2])
    print(f"Built {sys.argv[2]}")
