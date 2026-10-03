"""
Export engine for SnailyCAD installs.

Given a path to a SnailyCAD install — local to this app, or on a remote
host reached over SSH (password auth only, no key-based auth; see
app/transport.py) — this collects everything needed to restore the
instance elsewhere:
  - database dump (Postgres via pg_dump, or SQLite file copy)
  - .env file
  - configuration files
  - uploaded assets
  - CAD configuration (steps/permissions/roles config, best-effort)
  - custom/extra files the user points at
  - a manifest.json describing what's inside
  - a sha256 hash per file, plus a hash of the final archive

Everything lands in a single .zip under EXPORTS_DIR. Staging always happens
on the local disk of the machine running this app, regardless of whether
the source is local or remote — files are pulled down first, then zipped.
"""

import hashlib
import json
import os
import platform
import re
import shutil
import zipfile
from dataclasses import dataclass
from datetime import datetime
from typing import Optional

from app.transport import LocalTransport, TransportError

APP_VERSION = "1.0.0"

# Files/dirs we look for inside a SnailyCAD install, relative to its root.
# SnailyCAD's real layout (apps/api, apps/client, .env, prisma/) is matched
# first; anything missing is simply skipped rather than failing the export.
KNOWN_CONFIG_PATHS = [
    ".env",
    "apps/api/.env",
    "apps/client/.env",
    "apps/api/prisma/schema.prisma",
    "docker-compose.yml",
    "package.json",
]

KNOWN_UPLOAD_DIRS = [
    "apps/api/uploads",
    "uploads",
    "public/uploads",
]

KNOWN_CAD_CONFIG_PATHS = [
    "apps/api/src/config",
    "cad-config.json",
]


class ExportError(Exception):
    pass


@dataclass
class CollectedItem:
    category: str          # database, config, uploads, cad_config, custom, misc
    source_path: str
    archive_path: str      # forward-slash relative path within the archive
    size_bytes: int
    sha256: str


@dataclass
class ExportResult:
    manifest: dict
    archive_path: str
    archive_sha256: str
    archive_size_bytes: int


def sha256_of_file(path: str, chunk_size: int = 1024 * 1024) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(chunk_size), b""):
            h.update(chunk)
    return h.hexdigest()


def detect_host_os() -> str:
    system = platform.system().lower()
    if system.startswith("win"):
        return "windows"
    if system.startswith("linux"):
        return "linux"
    return system or "unknown"


class ExportService:
    """
    Usage:
        svc = ExportService(install_path, work_dir, db_config, transport=SSHTransport(...))
        svc.connect()
        try:
            svc.validate_install_path()
            svc.collect()
            svc.dump_database()
            result = svc.finalize(output_path)
        finally:
            svc.transport.close()
    """

    def __init__(self, install_path: str, work_dir: str, db_config: dict,
                 include_uploads: bool = True, extra_paths: Optional[list] = None,
                 progress_cb=None, transport=None):
        self.transport = transport or LocalTransport()
        self.install_path = install_path
        self.work_dir = work_dir  # staging directory, deleted after packaging
        self.db_config = db_config or {}
        self.include_uploads = include_uploads
        self.extra_paths = extra_paths or []
        self.progress_cb = progress_cb or (lambda msg: None)

        self.items: list[CollectedItem] = []
        self.errors: list[str] = []
        self.staging_dir = os.path.join(self.work_dir, "staging")

    def _report(self, msg):
        self.progress_cb(msg)

    def connect(self):
        self._report(f"Connecting ({self.transport.label})...")
        try:
            self.transport.connect()
        except TransportError as e:
            raise ExportError(str(e)) from e
        self._report("Connected.")

    # ---- validation -----------------------------------------------------

    def _remote_path(self, rel: str) -> str:
        parts = [p for p in re.split(r"[\\/]+", rel) if p]
        return self.transport.join(self.install_path, *parts)

    def validate_install_path(self):
        if not self.transport.isdir(self.install_path):
            raise ExportError(f"Install path does not exist: {self.install_path}")

        markers = ["package.json", ".env", "apps"]
        if not any(self.transport.exists(self._remote_path(m)) for m in markers):
            raise ExportError(
                "This doesn't look like a SnailyCAD install "
                "(no package.json, .env, or apps/ directory found)."
            )
        self._report("Install path validated.")

    # ---- collection -------------------------------------------------------

    def _stage_file(self, source_abs: str, category: str, archive_rel: str):
        dest = os.path.join(self.staging_dir, *archive_rel.split("/"))
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        self.transport.fetch(source_abs, dest)
        size = os.path.getsize(dest)
        digest = sha256_of_file(dest)
        self.items.append(CollectedItem(category, source_abs, archive_rel, size, digest))

    def _stage_dir(self, source_abs: str, category: str, archive_rel_root: str):
        for full in self.transport.walk_files(source_abs):
            rel = self.transport.path.relpath(full, source_abs).replace("\\", "/")
            archive_rel = f"{archive_rel_root}/{rel}"
            self._stage_file(full, category, archive_rel)

    def collect(self):
        os.makedirs(self.staging_dir, exist_ok=True)

        # Configuration files
        for rel in KNOWN_CONFIG_PATHS:
            abs_path = self._remote_path(rel)
            if self.transport.isfile(abs_path):
                self._stage_file(abs_path, "config", f"config/{rel}")
                self._report(f"Collected config: {rel}")

        # CAD configuration
        for rel in KNOWN_CAD_CONFIG_PATHS:
            abs_path = self._remote_path(rel)
            if self.transport.isfile(abs_path):
                self._stage_file(abs_path, "cad_config", f"cad_config/{rel}")
                self._report(f"Collected CAD config: {rel}")
            elif self.transport.isdir(abs_path):
                self._stage_dir(abs_path, "cad_config", f"cad_config/{rel}")
                self._report(f"Collected CAD config directory: {rel}")

        # Uploaded assets
        if self.include_uploads:
            for rel in KNOWN_UPLOAD_DIRS:
                abs_path = self._remote_path(rel)
                if self.transport.isdir(abs_path):
                    self._stage_dir(abs_path, "uploads", f"uploads/{rel}")
                    self._report(f"Collected uploads: {rel}")

        # Custom / extra user-specified paths (files or dirs), relative to install root
        for rel in self.extra_paths:
            abs_path = self._remote_path(rel)
            norm_rel = "/".join(p for p in re.split(r"[\\/]+", rel) if p)
            if self.transport.isfile(abs_path):
                self._stage_file(abs_path, "custom", f"custom/{norm_rel}")
            elif self.transport.isdir(abs_path):
                self._stage_dir(abs_path, "custom", f"custom/{norm_rel}")
            else:
                self.errors.append(f"Custom path not found, skipped: {rel}")

        if not self.items:
            self.errors.append(
                "No known SnailyCAD files were found to export. "
                "Double check the install path."
            )

    # ---- database ---------------------------------------------------------

    def _remote_temp_path(self, filename: str) -> str:
        remote_os = getattr(self.transport, "remote_os", detect_host_os())
        if remote_os == "windows":
            return f"C:\\Windows\\Temp\\{filename}"
        return f"/tmp/{filename}"

    def dump_database(self):
        db_type = (self.db_config.get("type") or "").lower()
        if not db_type:
            self._report("No database configured — skipping DB dump.")
            return

        dump_dir = os.path.join(self.staging_dir, "database")
        os.makedirs(dump_dir, exist_ok=True)

        if db_type == "postgres":
            self._dump_postgres(dump_dir)
        elif db_type == "sqlite":
            self._dump_sqlite(dump_dir)
        else:
            raise ExportError(f"Unsupported database type: {db_type}")

    def _dump_postgres(self, dump_dir: str):
        host = self.db_config.get("host", "localhost")
        port = str(self.db_config.get("port", 5432))
        name = self.db_config["name"]
        user = self.db_config.get("user", "postgres")
        password = self.db_config.get("password", "")
        env = {"PGPASSWORD": password} if password else None

        local_out = os.path.join(dump_dir, f"{name}.sql")
        self._report("Dumping Postgres database...")

        if self.transport.label == "local":
            cmd = ["pg_dump", "-h", host, "-p", port, "-U", user, "-F", "p", "-f", local_out, name]
            try:
                rc, _out, err = self.transport.run_command(cmd, env=env)
            except TransportError as e:
                raise ExportError(str(e)) from e
            if rc != 0:
                raise ExportError(f"pg_dump failed: {err.strip()[:2000]}")
        else:
            remote_tmp = self._remote_temp_path(f"{name}_{os.path.basename(dump_dir)}.sql")
            cmd = ["pg_dump", "-h", host, "-p", port, "-U", user, "-F", "p", "-f", remote_tmp, name]
            try:
                rc, _out, err = self.transport.run_command(cmd, env=env)
            except TransportError as e:
                raise ExportError(str(e)) from e
            if rc != 0:
                raise ExportError(f"pg_dump failed on remote host: {err.strip()[:2000]}")
            self._report("Downloading remote database dump...")
            self.transport.fetch(remote_tmp, local_out)
            self.transport.remove(remote_tmp)

        if not os.path.exists(local_out) or os.path.getsize(local_out) == 0:
            raise ExportError("pg_dump produced an empty file.")

        digest = sha256_of_file(local_out)
        size = os.path.getsize(local_out)
        self.items.append(CollectedItem("database", local_out, f"database/{name}.sql", size, digest))
        self._report("Postgres dump complete.")

    def _dump_sqlite(self, dump_dir: str):
        source = self.db_config.get("path")
        if not source or not self.transport.exists(source):
            raise ExportError(f"SQLite database file not found: {source}")

        dest_name = os.path.basename(source.replace("\\", "/"))
        dest = os.path.join(dump_dir, dest_name)
        self._report("Copying SQLite database...")
        self.transport.fetch(source, dest)

        digest = sha256_of_file(dest)
        size = os.path.getsize(dest)
        self.items.append(CollectedItem("database", dest, f"database/{dest_name}", size, digest))
        self._report("SQLite copy complete.")

    # ---- manifest / validation / packaging ---------------------------------

    def build_manifest(self, extra_meta: Optional[dict] = None) -> dict:
        manifest = {
            "export_tool_version": APP_VERSION,
            "created_at": datetime.utcnow().isoformat() + "Z",
            "source_os": getattr(self.transport, "remote_os", None) or detect_host_os(),
            "source_connection": self.transport.label,
            "install_path": self.install_path,
            "database_type": self.db_config.get("type"),
            "item_count": len(self.items),
            "warnings": self.errors,
            "items": [
                {
                    "category": item.category,
                    "archive_path": item.archive_path,
                    "size_bytes": item.size_bytes,
                    "sha256": item.sha256,
                }
                for item in self.items
            ],
        }
        if extra_meta:
            manifest.update(extra_meta)
        return manifest

    def validate_before_finalize(self) -> list:
        """Returns a list of blocking problems. Empty list means OK to package."""
        problems = []
        if not self.items:
            problems.append("Nothing was collected — refusing to create an empty export.")

        has_db = any(i.category == "database" for i in self.items)
        if self.db_config.get("type") and not has_db:
            problems.append("Database was configured but no dump was produced.")

        for item in self.items:
            full_path = os.path.join(self.staging_dir, *item.archive_path.split("/"))
            if not os.path.exists(full_path):
                problems.append(f"Missing staged file: {item.archive_path}")
            elif sha256_of_file(full_path) != item.sha256:
                problems.append(f"Hash mismatch after staging: {item.archive_path}")

        return problems

    def finalize(self, output_path: str, extra_meta: Optional[dict] = None) -> ExportResult:
        problems = self.validate_before_finalize()
        if problems:
            raise ExportError("Export validation failed: " + "; ".join(problems))

        manifest = self.build_manifest(extra_meta=extra_meta)
        manifest_path = os.path.join(self.staging_dir, "manifest.json")
        with open(manifest_path, "w") as f:
            json.dump(manifest, f, indent=2)

        self._report("Building archive...")
        os.makedirs(os.path.dirname(output_path), exist_ok=True)
        with zipfile.ZipFile(output_path, "w", zipfile.ZIP_DEFLATED) as zf:
            for root, _dirs, files in os.walk(self.staging_dir):
                for fname in files:
                    full = os.path.join(root, fname)
                    arcname = os.path.relpath(full, self.staging_dir)
                    zf.write(full, arcname)

        archive_sha256 = sha256_of_file(output_path)
        archive_size = os.path.getsize(output_path)

        # write a sidecar hash file for out-of-band verification
        with open(output_path + ".sha256", "w") as f:
            f.write(f"{archive_sha256}  {os.path.basename(output_path)}\n")

        self._report("Cleaning up staging directory...")
        shutil.rmtree(self.staging_dir, ignore_errors=True)

        return ExportResult(
            manifest=manifest,
            archive_path=output_path,
            archive_sha256=archive_sha256,
            archive_size_bytes=archive_size,
        )
