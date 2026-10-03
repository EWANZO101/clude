"""Transfer archives from source to destination.

Strategy: run rsync *on the source host* pushing directly to the
destination, so archives never route through the operator's machine.
Falls back to a two-hop SFTP relay if direct connectivity is unavailable.
"""

from __future__ import annotations

import os
import re
import shlex
import tempfile
import time
from pathlib import Path
from typing import Callable, Optional

from .config import Config
from .logging_setup import get_logger
from .ssh import SSHConnection, SSHError

log = get_logger("transfer")

ProgressCB = Callable[[int, int], None]  # (bytes_done, bytes_total)


class Transfer:
    def __init__(self, cfg: Config, src: SSHConnection, dst: SSHConnection):
        self.cfg = cfg
        self.src = src
        self.dst = dst
        self._direct: Optional[bool] = None
        self._key_on_source: str = ""

    # ------------------------------------------------------------- plumbing

    def _ensure_rsync(self) -> None:
        for conn, label in ((self.src, "source"), (self.dst, "destination")):
            if not conn.which("rsync"):
                log.info("Installing rsync on %s", label)
                conn.run("DEBIAN_FRONTEND=noninteractive apt-get update -qq "
                         "&& apt-get install -y rsync",
                         sudo=True, timeout=900)

    def _stage_key_on_source(self) -> str:
        """Copy the destination SSH key onto the source host (0600, /root)
        so source can push directly. Removed in cleanup()."""
        if self._key_on_source:
            return self._key_on_source
        local_key = os.path.expanduser(self.cfg.destination.ssh_key)
        remote_key = "/root/.opslab_migrate_dest_key"
        with open(local_key, "r", encoding="utf-8") as fh:
            self.src.write_file(remote_key, fh.read(), sudo=True, mode="600")
        self._key_on_source = remote_key
        return remote_key

    def _auth_prefix_and_opts(self) -> tuple[str, str]:
        """Return (command_prefix, ssh_extra_opts) for source→destination
        auth. Password auth uses sshpass with the password passed via the
        SSHPASS environment variable so it never appears in process args."""
        d = self.cfg.destination
        if d.uses_password:
            if not self.src.which("sshpass"):
                log.info("Installing sshpass on source host")
                self.src.run(
                    "DEBIAN_FRONTEND=noninteractive apt-get install -y "
                    "sshpass || (apt-get update -qq && "
                    "DEBIAN_FRONTEND=noninteractive apt-get install -y "
                    "sshpass)", sudo=True, timeout=900)
            if not self.src.which("sshpass"):
                return "", ""  # signals: fall back to relay
            prefix = f"SSHPASS={shlex.quote(d.password)} sshpass -e "
            return prefix, ""
        key = self._stage_key_on_source()
        return "", f"-i {key} -o BatchMode=yes "

    def _can_push_direct(self) -> bool:
        if self._direct is not None:
            return self._direct
        d = self.cfg.destination
        prefix, opts = self._auth_prefix_and_opts()
        if d.uses_password and not prefix:
            self._direct = False
            log.warning("sshpass unavailable on source — relaying via "
                        "operator machine instead")
            return False
        r = self.src.run(
            f"{prefix}ssh {opts}-p {d.port} "
            f"-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "
            f"{shlex.quote(d.username)}@{shlex.quote(d.host)} true",
            sudo=True, timeout=30)
        self._direct = r.ok
        log.info("Direct source→destination connectivity: %s",
                 "yes" if r.ok else "no — will relay via operator")
        return self._direct

    # ------------------------------------------------------------- transfer

    def send(self, archive: str, dest_dir: str, expected_sha: str,
             progress: Optional[ProgressCB] = None) -> str:
        """Move one archive to dest_dir on the destination. Verifies the
        checksum, retries, and resumes partial transfers. Returns the
        destination path."""
        self._ensure_rsync()
        self.dst.run(f"mkdir -p {shlex.quote(dest_dir)}", sudo=True,
                     check=True)
        dest_path = f"{dest_dir}/{archive.rsplit('/', 1)[-1]}"

        last_err = ""
        for attempt in range(1, self.cfg.transfer.retries + 1):
            try:
                if self._can_push_direct():
                    self._rsync_direct(archive, dest_path, progress)
                else:
                    self._relay(archive, dest_path, progress)
                got = self.dst.sha256(dest_path)
                if got == expected_sha:
                    log.info("Transfer verified: %s (sha256 match)",
                             dest_path)
                    return dest_path
                last_err = f"checksum mismatch ({got[:12]} != {expected_sha[:12]})"
                log.warning("Attempt %d: %s — retrying", attempt, last_err)
            except SSHError as e:
                last_err = str(e)
                log.warning("Attempt %d transfer error: %s", attempt, e)
            time.sleep(3 * attempt)
        raise RuntimeError(f"Transfer of {archive} failed after "
                           f"{self.cfg.transfer.retries} attempts: {last_err}")

    def _rsync_direct(self, archive: str, dest_path: str,
                      progress: Optional[ProgressCB]) -> None:
        d = self.cfg.destination
        prefix, opts = self._auth_prefix_and_opts()
        bw = (f"--bwlimit={self.cfg.transfer.bandwidth_limit_kbps} "
              if self.cfg.transfer.bandwidth_limit_kbps else "")
        ck = "--checksum " if self.cfg.transfer.checksum else ""
        rsh = (f"ssh {opts}-p {d.port} "
               f"-o StrictHostKeyChecking=accept-new")
        # --partial + --inplace off: use --partial-dir for safe resume
        cmd = (f"{prefix}rsync -av --partial --partial-dir=.rsync-partial "
               f"--compress {bw}{ck}--timeout=60 "
               f"-e {shlex.quote(rsh)} {shlex.quote(archive)} "
               f"{shlex.quote(d.username)}@{shlex.quote(d.host)}:"
               f"{shlex.quote(dest_path)}")
        total = int(self.src.run(
            f"stat -c %s {shlex.quote(archive)}", sudo=True).stdout.strip()
            or 0)
        if progress:
            progress(0, total)
        r = self.src.run(cmd, sudo=True, timeout=14400)
        if not r.ok:
            raise SSHError(f"rsync exit {r.exit_code}: {r.stderr[:400]}")
        if progress:
            progress(total, total)

    def _relay(self, archive: str, dest_path: str,
               progress: Optional[ProgressCB]) -> None:
        """Two-hop fallback: source → operator temp file → destination."""
        with tempfile.NamedTemporaryFile(delete=False) as tmp:
            local = tmp.name
        try:
            log.info("Relaying %s via operator machine", archive)
            # Copy source archive somewhere the SFTP user can read it
            readable = f"/tmp/{Path(archive).name}"
            self.src.run(f"cp {shlex.quote(archive)} {shlex.quote(readable)} "
                         f"&& chmod 644 {shlex.quote(readable)}", sudo=True,
                         check=True)
            self.src.sftp_get(readable, local)
            self.src.run(f"rm -f {shlex.quote(readable)}", sudo=True)
            staged = f"/tmp/{Path(archive).name}"
            self.dst.sftp_put(local, staged)
            self.dst.run(f"mv {shlex.quote(staged)} {shlex.quote(dest_path)}",
                         sudo=True, check=True)
            if progress:
                size = Path(local).stat().st_size
                progress(size, size)
        finally:
            Path(local).unlink(missing_ok=True)

    def cleanup(self) -> None:
        if self._key_on_source:
            self.src.run(f"rm -f {self._key_on_source}", sudo=True)
            self._key_on_source = ""
