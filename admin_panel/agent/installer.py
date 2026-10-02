"""
Installs a validated update package. Everything in the ZIP except the
update.json manifest and the rescue/ component becomes the application's
files — the rescue component deliberately does NOT get installed into
app_install_dir (spec Section 17: it must remain available independently of
the main application, so it's kept only inside the recovery/package trees,
never mixed into the files a bad update could corrupt).
"""
import logging
import os
import shutil
import zipfile

from agent.package_validation import REQUIRED_MANIFEST, RESCUE_PREFIX

log = logging.getLogger("agent.installer")

# Real incident (2026-09-08): the Kiosk App's own sqlite database
# (kiosk_local.db) lives at the root of app_install_dir by default (see
# kiosk_app/app/config.py — it's a sibling of run.py, not in a separate
# data directory), because nothing in this app's on-disk layout was ever
# designed with "this directory gets wiped on every update" in mind. Every
# push before this fix deleted it outright: a plain kiosk restart with the
# SAME code came back fine, but any real update — including this one —
# silently destroyed every real Item/Tool/LocalUser/stock-audit row and
# left a completely fresh, re-seeded database in its place, with no
# warning and no error (create_all() + the first-run admin seed both
# succeed perfectly well against an empty database, so nothing about the
# process looked wrong). spec Section 46 ("an update should replace the
# application without accidentally deleting customer data") already
# covers exactly this for the Agent's OWN data (app_install_dir is kept
# separate from download/recovery dirs for precisely this reason) — this
# extends the same protection to whatever data file the application being
# updated keeps sitting in its own install directory, since that's a
# choice this Agent doesn't get to make for it.
PRESERVED_DATA_EXTENSIONS = (".db", ".sqlite", ".sqlite3")


class InstallError(Exception):
    pass


def install_package(zip_path: str, app_install_dir: str) -> None:
    """Replaces app_install_dir's contents with the package's application
    files. Caller is responsible for having taken a recovery point first —
    this function does not back anything up, it only installs.

    Never deletes a top-level *.db/*.sqlite/*.sqlite3 file while clearing
    the old install — see PRESERVED_DATA_EXTENSIONS above. A release
    package never ships one of its own (tools/build_kiosk_release.py only
    ever includes source, never data), so there's nothing for the new
    version's files to conflict with."""
    os.makedirs(app_install_dir, exist_ok=True)

    try:
        with zipfile.ZipFile(zip_path) as zf:
            members = [
                n for n in zf.namelist()
                if n != REQUIRED_MANIFEST and not n.startswith(RESCUE_PREFIX)
            ]
            # Clear the install dir only after the zip has been confirmed
            # openable — never leave app_install_dir empty because a
            # corrupt/unreadable zip failed partway through.
            preserved = []
            for entry in os.listdir(app_install_dir):
                entry_path = os.path.join(app_install_dir, entry)
                if os.path.isdir(entry_path):
                    shutil.rmtree(entry_path)
                elif entry.lower().endswith(PRESERVED_DATA_EXTENSIONS):
                    preserved.append(entry)
                    continue
                else:
                    os.remove(entry_path)

            zf.extractall(app_install_dir, members=members)
    except (zipfile.BadZipFile, OSError) as e:
        raise InstallError(f"failed to install package: {e}") from e

    if preserved:
        log.info("Preserved existing data file(s) across install: %s", ", ".join(preserved))
    log.info("Installed %d file(s)/dir(s) from %s into %s", len(members), zip_path, app_install_dir)
