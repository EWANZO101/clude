"""Build one self-contained archive per project on the source host.

Archive layout (inside project.tar.zst):
    app/            project source tree (incl. .env, uploads, static, templates)
    db/             database dumps
    system/systemd/     unit files
    system/supervisor/  supervisor configs
    system/nginx/       nginx site configs
    system/apache/      apache site configs
    manifest.json   project metadata + permissions + checksums
"""

from __future__ import annotations

import json
import shlex
import time

from .database import DatabaseHandler
from .discovery import ProjectInfo
from .logging_setup import get_logger
from .ssh import SSHConnection

log = get_logger("backup")

COMPRESS_FLAGS = {
    "zstd": ("--zstd", ".tar.zst", "zstd"),
    "gzip": ("-z", ".tar.gz", "gzip"),
    "xz": ("-J", ".tar.xz", "xz"),
}


class BackupBuilder:
    def __init__(self, ssh: SSHConnection, staging_dir: str,
                 compression: str = "zstd", include_venv: bool = False):
        self.ssh = ssh
        self.staging = staging_dir.rstrip("/")
        self.compression = compression
        self.include_venv = include_venv
        self.db = DatabaseHandler(ssh)

    def ensure_tools(self) -> None:
        """Make sure the compressor exists on the source host."""
        _, _, binary = COMPRESS_FLAGS[self.compression]
        if not self.ssh.which(binary):
            log.info("Installing %s on source host", binary)
            pkg = {"zstd": "zstd", "gzip": "gzip", "xz": "xz-utils"}[self.compression]
            self.ssh.run(
                f"DEBIAN_FRONTEND=noninteractive apt-get install -y {pkg}",
                sudo=True, timeout=600)

    def build(self, proj: ProjectInfo) -> dict:
        """Create the archive. Returns {'archive': path, 'sha256': ...,
        'size': bytes, 'db_dumps': [...]}."""
        t0 = time.time()
        flag, ext, _ = COMPRESS_FLAGS[self.compression]
        work = f"{self.staging}/{proj.name}"
        archive = f"{self.staging}/{proj.name}{ext}"
        q = shlex.quote

        self.ssh.run(f"rm -rf {q(work)} && mkdir -p {q(work)}/db "
                     f"{q(work)}/system/systemd {q(work)}/system/supervisor "
                     f"{q(work)}/system/nginx {q(work)}/system/apache",
                     sudo=True, check=True)

        # 1. Database dumps
        dumps: list[dict] = []
        for db in proj.databases:
            dump = self.db.backup(db, f"{work}/db")
            dumps.append({"db": {k: v for k, v in db.items()
                                 if k != "password"},
                          "dump": dump, "ok": dump is not None})

        # 2. System configs
        for unit in proj.systemd_units:
            self.ssh.run(f"cp -a {q(unit)} {q(work)}/system/systemd/",
                         sudo=True)
        for sup in proj.supervisor_configs:
            self.ssh.run(f"cp -a {q(sup)} {q(work)}/system/supervisor/",
                         sudo=True)
        for ngx in proj.nginx_configs:
            self.ssh.run(f"cp -a {q(ngx)} {q(work)}/system/nginx/", sudo=True)
        for apa in proj.apache_configs:
            self.ssh.run(f"cp -a {q(apa)} {q(work)}/system/apache/", sudo=True)

        # 3. Permission manifest for the app tree (path, mode, owner, group)
        perms = self.ssh.run(
            f"cd {q(proj.path)} && find . -printf '%p|%m|%u|%g\\n' "
            f"2>/dev/null | head -100000", sudo=True).stdout

        # 4. Manifest
        manifest = {
            "created": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "project": proj.to_dict(),
            "db_dumps": [{**d, "db": {k: v for k, v in d["db"].items()}}
                         for d in dumps],
            "permissions": perms,
            "compression": self.compression,
        }
        # Strip any password fields from manifest
        for d in manifest["project"].get("databases", []):
            d.pop("password", None)
        self.ssh.write_file(
            f"{work}/manifest.json",
            json.dumps(manifest, indent=2, default=str), sudo=True)

        # 5. Tar it all up: app tree + staging content
        venv_exclude = ""
        if not self.include_venv and proj.venv_path:
            rel = proj.venv_path[len(proj.path):].lstrip("/")
            venv_exclude = f"--exclude=app/{shlex.quote(rel)}"
        excludes = (f"{venv_exclude} --exclude='app/__pycache__' "
                    f"--exclude='app/**/__pycache__' "
                    f"--exclude='app/.git/objects'")
        r = self.ssh.run(
            f"tar {flag} -cf {q(archive)} {excludes} "
            f"-C {q(work)} db system manifest.json "
            f"--transform 's,^,,' "
            f"-C {q(proj.path)}/.. "
            f"--transform 's,^{shlex.quote(proj.name)},app,' "
            f"{q(proj.name)}",
            sudo=True, timeout=7200)
        if not r.ok:
            # tar exit 1 = files changed while reading — acceptable for live apps
            if r.exit_code > 1:
                raise RuntimeError(
                    f"tar failed for {proj.name}: {r.stderr[:400]}")
            log.warning("tar reported changed files during read for %s",
                        proj.name)

        sha = self.ssh.sha256(archive)
        size = int(self.ssh.run(
            f"stat -c %s {q(archive)}", sudo=True).stdout.strip() or 0)
        self.ssh.run(f"rm -rf {q(work)}", sudo=True)
        log.info("Archive %s built in %.1fs (%d bytes, sha256=%s)",
                 archive, time.time() - t0, size, sha[:12])
        return {"archive": archive, "sha256": sha, "size": size,
                "db_dumps": dumps, "duration": time.time() - t0}

    def prune_old(self, keep_days: int) -> None:
        self.ssh.run(
            f"find {shlex.quote(self.staging)} -maxdepth 1 -name '*.tar.*' "
            f"-mtime +{keep_days} -delete", sudo=True)
