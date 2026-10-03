"""SSH connection layer built on Paramiko, with retries and host verification."""

from __future__ import annotations

import os
import shlex
import socket
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

import paramiko

from .config import HostConfig
from .logging_setup import get_logger

log = get_logger("ssh")


class SSHError(Exception):
    pass


@dataclass
class CommandResult:
    exit_code: int
    stdout: str
    stderr: str

    @property
    def ok(self) -> bool:
        return self.exit_code == 0


class SSHConnection:
    """Reusable SSH connection to one host, with automatic reconnect."""

    def __init__(self, host_cfg: HostConfig, strict_host_key: bool = True):
        self.cfg = host_cfg
        self.strict = strict_host_key
        self._client: Optional[paramiko.SSHClient] = None

    # -- lifecycle ---------------------------------------------------------

    def connect(self, retries: int = 3, delay: float = 3.0) -> None:
        last_err: Optional[Exception] = None
        for attempt in range(1, retries + 1):
            try:
                client = paramiko.SSHClient()
                client.load_system_host_keys()
                if self.strict:
                    client.set_missing_host_key_policy(paramiko.RejectPolicy())
                else:
                    # First-run convenience; recorded in known_hosts thereafter
                    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
                kwargs: dict = dict(
                    hostname=self.cfg.host,
                    port=self.cfg.port,
                    username=self.cfg.username,
                    timeout=20,
                    banner_timeout=30,
                    look_for_keys=False,
                )
                if self.cfg.uses_password:
                    kwargs.update(password=self.cfg.password,
                                  allow_agent=False)
                else:
                    kwargs.update(
                        key_filename=os.path.expanduser(self.cfg.ssh_key),
                        allow_agent=True)
                client.connect(**kwargs)
                transport = client.get_transport()
                if transport:
                    transport.set_keepalive(30)
                self._client = client
                log.info("Connected to %s@%s:%s", self.cfg.username,
                         self.cfg.host, self.cfg.port)
                return
            except (paramiko.SSHException, socket.error, OSError) as e:
                last_err = e
                log.warning("SSH connect attempt %d/%d to %s failed: %s",
                            attempt, retries, self.cfg.host, e)
                time.sleep(delay * attempt)
        raise SSHError(f"Cannot connect to {self.cfg.host}: {last_err}")

    def close(self) -> None:
        if self._client:
            self._client.close()
            self._client = None

    def __enter__(self) -> "SSHConnection":
        self.connect()
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    @property
    def client(self) -> paramiko.SSHClient:
        if self._client is None:
            self.connect()
        assert self._client is not None
        transport = self._client.get_transport()
        if transport is None or not transport.is_active():
            log.info("Transport dropped — reconnecting to %s", self.cfg.host)
            self.connect()
        return self._client  # type: ignore[return-value]

    # -- execution ---------------------------------------------------------

    def run(self, command: str, timeout: int = 600, sudo: bool = False,
            check: bool = False) -> CommandResult:
        if sudo and self.cfg.username != "root":
            command = f"sudo -n {command}"
        log.debug("[%s] $ %s", self.cfg.host, command)
        try:
            _, stdout, stderr = self.client.exec_command(command, timeout=timeout)
            out = stdout.read().decode("utf-8", errors="replace")
            err = stderr.read().decode("utf-8", errors="replace")
            code = stdout.channel.recv_exit_status()
        except (paramiko.SSHException, socket.error) as e:
            raise SSHError(f"Command failed on {self.cfg.host}: {e}") from e
        result = CommandResult(code, out, err)
        if check and not result.ok:
            raise SSHError(
                f"Command exited {code} on {self.cfg.host}: {command}\n{err[:500]}"
            )
        return result

    def run_retry(self, command: str, retries: int = 3, **kw) -> CommandResult:
        last: Optional[CommandResult] = None
        for attempt in range(1, retries + 1):
            last = self.run(command, **kw)
            if last.ok:
                return last
            log.warning("Retry %d/%d for command on %s (exit %d)",
                        attempt, retries, self.cfg.host, last.exit_code)
            time.sleep(2 * attempt)
        assert last is not None
        return last

    # -- convenience -------------------------------------------------------

    def exists(self, path: str) -> bool:
        return self.run(f"test -e {shlex.quote(path)}").ok

    def which(self, binary: str) -> Optional[str]:
        r = self.run(f"command -v {shlex.quote(binary)}")
        return r.stdout.strip() or None

    def read_file(self, path: str, sudo: bool = False) -> str:
        r = self.run(f"cat {shlex.quote(path)}", sudo=sudo)
        if not r.ok:
            raise SSHError(f"Cannot read {path} on {self.cfg.host}: {r.stderr}")
        return r.stdout

    def write_file(self, path: str, content: str, sudo: bool = False,
                   mode: str = "644") -> None:
        tmp = f"/tmp/.mk_{int(time.time()*1000)}"
        sftp = self.client.open_sftp()
        try:
            with sftp.open(tmp, "w") as fh:
                fh.write(content)
        finally:
            sftp.close()
        self.run(f"mv {tmp} {shlex.quote(path)} && chmod {mode} "
                 f"{shlex.quote(path)}", sudo=sudo, check=True)

    def sftp_get(self, remote: str, local: str | Path) -> None:
        sftp = self.client.open_sftp()
        try:
            sftp.get(remote, str(local))
        finally:
            sftp.close()

    def sftp_put(self, local: str | Path, remote: str) -> None:
        sftp = self.client.open_sftp()
        try:
            sftp.put(str(local), remote)
        finally:
            sftp.close()

    def sha256(self, path: str) -> str:
        r = self.run(f"sha256sum {shlex.quote(path)}", check=True)
        return r.stdout.split()[0]

    def disk_free_mb(self, path: str = "/") -> int:
        r = self.run(f"df -Pm {shlex.quote(path)} | tail -1")
        try:
            return int(r.stdout.split()[3])
        except (IndexError, ValueError):
            return 0

    def memory_free_mb(self) -> int:
        r = self.run("free -m | awk '/^Mem:/{print $7}'")
        try:
            return int(r.stdout.strip())
        except ValueError:
            return 0
