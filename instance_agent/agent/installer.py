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


class InstallError(Exception):
    pass


def install_package(zip_path: str, app_install_dir: str) -> None:
    """Replaces app_install_dir's contents with the package's application
    files. Caller is responsible for having taken a recovery point first —
    this function does not back anything up, it only installs."""
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
            for entry in os.listdir(app_install_dir):
                entry_path = os.path.join(app_install_dir, entry)
                if os.path.isdir(entry_path):
                    shutil.rmtree(entry_path)
                else:
                    os.remove(entry_path)

            zf.extractall(app_install_dir, members=members)
    except (zipfile.BadZipFile, OSError) as e:
        raise InstallError(f"failed to install package: {e}") from e

    log.info("Installed %d file(s)/dir(s) from %s into %s", len(members), zip_path, app_install_dir)
