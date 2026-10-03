"""
Import engine — restores a package produced by ExportService onto a
target SnailyCAD install, either on this machine or on a remote host
reached over SSH (password auth only — see app/transport.py). RDP is not
used for the actual data push: it's a graphical protocol with no
practical way to script file transfer, so remote targets need SSH
reachable instead (OpenSSH Server ships with, or is easily enabled on,
both Windows and Linux).

Steps: detect target OS -> validate package integrity against its own
manifest (always done locally against the uploaded package) -> extract
locally -> restore database -> restore files to the target (local copy or
remote push) -> best-effort restore permissions -> verify compatibility ->
report progress throughout.
"""

import json
import os
import shutil
import zipfile
from dataclasses import dataclass
from typing import Optional

from app.exports.service import sha256_of_file, detect_host_os, APP_VERSION
from app.transport import LocalTransport, TransportError


class ImportError_(Exception):
    """Named to avoid shadowing the builtin ImportError."""


@dataclass
class RestoreResult:
    manifest: dict
    restored_files: int
    warnings: list
    target_os: str


class ImportService:
    def __init__(self, package_path: str, target_path: str, work_dir: str,
                 db_target: Optional[dict] = None, progress_cb=None, transport=None):
        self.package_path = package_path
        self.target_path = target_path
        self.work_dir = work_dir
        self.db_target = db_target or {}
        self.progress_cb = progress_cb or (lambda msg: None)
        self.transport = transport or LocalTransport()

        self.extract_dir = os.path.join(self.work_dir, "extracted")
        self.manifest: Optional[dict] = None
        self.warnings: list = []
        self.restored_files = 0

    def _report(self, msg):
        self.progress_cb(msg)

    def connect(self):
        self._report(f"Connecting to target ({self.transport.label})...")
        try:
            self.transport.connect()
        except TransportError as e:
            raise ImportError_(str(e)) from e
        self._report("Connected.")

    # ---- integrity (always local — the package is uploaded to this app) ----

    def validate_package_integrity(self):
        if not os.path.isfile(self.package_path):
            raise ImportError_(f"Package not found: {self.package_path}")

        if not zipfile.is_zipfile(self.package_path):
            raise ImportError_("Package is not a valid zip archive.")

        os.makedirs(self.extract_dir, exist_ok=True)
        self._report("Extracting package...")
        with zipfile.ZipFile(self.package_path) as zf:
            for member in zf.namelist():
                dest = os.path.abspath(os.path.join(self.extract_dir, member))
                if not dest.startswith(os.path.abspath(self.extract_dir) + os.sep):
                    raise ImportError_(f"Unsafe path in package, aborting: {member}")
            zf.extractall(self.extract_dir)

        manifest_path = os.path.join(self.extract_dir, "manifest.json")
        if not os.path.isfile(manifest_path):
            raise ImportError_("Package is missing manifest.json — not a valid export.")

        with open(manifest_path) as f:
            self.manifest = json.load(f)

        self._report("Verifying file integrity against manifest...")
        problems = []
        for item in self.manifest.get("items", []):
            full_path = os.path.join(self.extract_dir, *item["archive_path"].split("/"))
            if not os.path.isfile(full_path):
                problems.append(f"Missing from package: {item['archive_path']}")
                continue
            actual = sha256_of_file(full_path)
            if actual != item["sha256"]:
                problems.append(f"Hash mismatch (corrupted?): {item['archive_path']}")

        if problems:
            raise ImportError_("Package integrity check failed: " + "; ".join(problems))

        self._report(f"Integrity verified — {len(self.manifest.get('items', []))} items OK.")

    # ---- compatibility --------------------------------------------------

    def verify_compatibility(self, target_os: str):
        source_os = (self.manifest or {}).get("source_os", "unknown")
        if source_os != target_os:
            self.warnings.append(
                f"Cross-platform migration: exported on {source_os}, restoring to {target_os}. "
                "File paths and permissions will be adapted automatically."
            )

        source_version = (self.manifest or {}).get("export_tool_version", "unknown")
        if source_version != APP_VERSION:
            self.warnings.append(
                f"Package was created by export tool v{source_version}, "
                f"this importer is v{APP_VERSION}. Proceeding, but review the manifest."
            )
        self._report(f"Compatibility check complete ({len(self.warnings)} warning(s)).")

    # ---- restore: files ---------------------------------------------------

    def restore_files(self):
        if not self.manifest:
            raise ImportError_("No manifest loaded — call validate_package_integrity() first.")

        if self.transport.label == "local":
            os.makedirs(self.target_path, exist_ok=True)

        for item in self.manifest.get("items", []):
            category = item["category"]
            archive_path = item["archive_path"]

            if category == "database":
                continue  # handled separately in restore_database()

            # archive_path looks like "config/.env" or "uploads/apps/api/uploads/logo.png";
            # strip the leading category segment to get the path relative to install root.
            parts = archive_path.split("/", 1)
            rel_to_install = parts[1] if len(parts) > 1 else parts[0]
            rel_parts = rel_to_install.split("/")

            src = os.path.join(self.extract_dir, *archive_path.split("/"))
            dest = self.transport.join(self.target_path, *rel_parts)

            self.transport.push(src, dest)
            self.restored_files += 1

        self._report(f"Restored {self.restored_files} file(s) to {self.target_path}.")

    # ---- restore: permissions (best-effort, Linux targets only) ------------

    def restore_permissions(self, target_os: str):
        if target_os != "linux":
            self._report("Skipping POSIX permission restore (target is not Linux).")
            return

        if self.transport.label == "local":
            try:
                for root, dirs, files in os.walk(self.target_path):
                    for d in dirs:
                        os.chmod(os.path.join(root, d), 0o755)
                    for fname in files:
                        os.chmod(os.path.join(root, fname), 0o644)
                self._report("Applied default permissions (755 dirs / 644 files).")
            except OSError as e:
                self.warnings.append(f"Could not fully restore permissions: {e}")
        else:
            try:
                rc, _out, err = self.transport.run_command(
                    ["find", self.target_path, "-type", "d", "-exec", "chmod", "755", "{}", "+"]
                )
                rc2, _out2, err2 = self.transport.run_command(
                    ["find", self.target_path, "-type", "f", "-exec", "chmod", "644", "{}", "+"]
                )
                if rc != 0 or rc2 != 0:
                    self.warnings.append(f"Remote permission restore reported errors: {err or err2}")
                else:
                    self._report("Applied default permissions on remote host (755 dirs / 644 files).")
            except TransportError as e:
                self.warnings.append(f"Could not restore remote permissions: {e}")

    # ---- restore: database --------------------------------------------------

    def restore_database(self):
        db_type = (self.manifest or {}).get("database_type")
        if not db_type:
            self._report("Package contains no database dump — skipping.")
            return

        if not self.db_target:
            self.warnings.append(
                "Package includes a database dump but no restore target was configured — "
                "database was NOT restored. Restore it manually."
            )
            return

        dump_dir = os.path.join(self.extract_dir, "database")
        if not os.path.isdir(dump_dir):
            raise ImportError_("Manifest declares a database but no dump directory was found.")

        dump_files = os.listdir(dump_dir)
        if not dump_files:
            raise ImportError_("Database dump directory is empty.")
        dump_file = os.path.join(dump_dir, dump_files[0])

        if db_type == "postgres":
            self._restore_postgres(dump_file)
        elif db_type == "sqlite":
            self._restore_sqlite(dump_file)
        else:
            raise ImportError_(f"Unsupported database type in package: {db_type}")

    def _restore_postgres(self, dump_file: str):
        host = self.db_target.get("host", "localhost")
        port = str(self.db_target.get("port", 5432))
        name = self.db_target["name"]
        user = self.db_target.get("user", "postgres")
        password = self.db_target.get("password", "")
        env = {"PGPASSWORD": password} if password else None

        self._report(f"Restoring Postgres database '{name}'...")

        if self.transport.label == "local":
            cmd = ["psql", "-h", host, "-p", port, "-U", user, "-d", name, "-f", dump_file]
            try:
                rc, _out, err = self.transport.run_command(cmd, env=env)
            except TransportError as e:
                raise ImportError_(str(e)) from e
            if rc != 0:
                raise ImportError_(f"psql restore failed: {err.strip()[:2000]}")
        else:
            remote_os = getattr(self.transport, "remote_os", "linux")
            remote_tmp = (f"C:\\Windows\\Temp\\restore_{name}.sql" if remote_os == "windows"
                          else f"/tmp/restore_{name}.sql")
            self._report("Uploading database dump to target host...")
            self.transport.push(dump_file, remote_tmp)
            cmd = ["psql", "-h", host, "-p", port, "-U", user, "-d", name, "-f", remote_tmp]
            try:
                rc, _out, err = self.transport.run_command(cmd, env=env)
            except TransportError as e:
                raise ImportError_(str(e)) from e
            self.transport.remove(remote_tmp)
            if rc != 0:
                raise ImportError_(f"psql restore failed on remote host: {err.strip()[:2000]}")

        self._report("Postgres restore complete.")

    def _restore_sqlite(self, dump_file: str):
        dest = self.db_target.get("path")
        if not dest:
            raise ImportError_("No target SQLite path configured.")

        if self.transport.exists(dest):
            backup_path = dest + ".bak"
            try:
                if self.transport.label == "local":
                    os.makedirs(os.path.dirname(dest), exist_ok=True)
                    shutil.copy2(dest, backup_path)
                else:
                    remote_os = getattr(self.transport, "remote_os", "linux")
                    if remote_os == "windows":
                        self.transport.run_command(["cmd", "/c", "copy", "/Y", dest, backup_path])
                    else:
                        self.transport.run_command(["cp", dest, backup_path])
                self.warnings.append(f"Existing SQLite DB backed up to {backup_path} before overwrite.")
            except (TransportError, OSError) as e:
                self.warnings.append(f"Could not back up existing SQLite DB before overwrite: {e}")

        self.transport.push(dump_file, dest)
        self._report(f"SQLite database restored to {dest}.")

    # ---- orchestration --------------------------------------------------

    def run(self) -> RestoreResult:
        target_os = getattr(self.transport, "remote_os", None) or detect_host_os()
        self._report(f"Target OS: {target_os}")

        self.validate_package_integrity()
        self.verify_compatibility(target_os)
        self.restore_database()
        self.restore_files()
        self.restore_permissions(target_os)

        shutil.rmtree(self.extract_dir, ignore_errors=True)

        return RestoreResult(
            manifest=self.manifest,
            restored_files=self.restored_files,
            warnings=self.warnings,
            target_os=target_os,
        )
