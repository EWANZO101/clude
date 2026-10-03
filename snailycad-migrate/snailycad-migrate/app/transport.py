"""
Transport layer so the export/import engines can operate against either
the local filesystem or a remote host over SSH/SFTP, using the exact same
collection/restore logic either way.

SSH auth is password-only by design (no key-based auth) — matches how
this platform's own infra is administered. RDP is not used for the actual
data pull: it's a graphical remote-desktop protocol with no practical way
to script file transfer or run remote commands, so instead we ask the
target machine to have SSH reachable (OpenSSH Server ships with, or is
easily enabled on, both Windows and Linux) and use that for everything —
listing files, pulling them, and running pg_dump/psql remotely.
"""

import ntpath
import os
import posixpath
import shutil
import stat
import subprocess


class TransportError(Exception):
    pass


class LocalTransport:
    """Operates on the filesystem of the machine running this app."""

    label = "local"

    def __init__(self):
        self.path = os.path

    def connect(self):
        pass  # nothing to do

    def close(self):
        pass

    def join(self, *parts):
        return os.path.join(*parts)

    def isdir(self, path):
        return os.path.isdir(path)

    def isfile(self, path):
        return os.path.isfile(path)

    def exists(self, path):
        return os.path.exists(path)

    def walk_files(self, root):
        """Yields absolute file paths under root, recursively."""
        for dirpath, _dirs, files in os.walk(root):
            for fname in files:
                yield os.path.join(dirpath, fname)

    def fetch(self, source_path, local_dest_path):
        """Copy a file from this transport's source into local staging."""
        os.makedirs(os.path.dirname(local_dest_path), exist_ok=True)
        shutil.copy2(source_path, local_dest_path)

    def push(self, local_source_path, dest_path):
        """Copy a local staged file out to this transport's destination."""
        os.makedirs(os.path.dirname(dest_path), exist_ok=True)
        shutil.copy2(local_source_path, dest_path)

    def remove(self, path):
        if os.path.exists(path):
            os.remove(path)

    def run_command(self, cmd, env=None, timeout=1800):
        """cmd is a list (argv-style) for local execution."""
        try:
            result = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=timeout)
        except FileNotFoundError as e:
            raise TransportError(f"Command not found: {cmd[0]}") from e
        except subprocess.TimeoutExpired as e:
            raise TransportError(f"Command timed out: {' '.join(cmd)}") from e
        return result.returncode, result.stdout, result.stderr


class SSHTransport:
    """
    Operates on a remote host over SSH/SFTP. Password auth only —
    look_for_keys/allow_agent are disabled so this never touches or
    requires an SSH keypair.
    """

    label = "ssh"

    def __init__(self, host, port, username, password, remote_os="linux", timeout=15):
        self.host = host
        self.port = port or 22
        self.username = username
        self.password = password
        self.remote_os = remote_os  # "linux" or "windows" — controls path joining + dump commands
        self.timeout = timeout
        self.client = None
        self.sftp = None
        self.path = posixpath if remote_os == "linux" else ntpath

    def connect(self):
        try:
            import paramiko
        except ImportError as e:
            raise TransportError(
                "SSH support requires the 'paramiko' package, which isn't installed. "
                "On the server, run: pip install -r requirements.txt (inside the venv), "
                "then restart the app."
            ) from e

        self.client = paramiko.SSHClient()
        self.client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        try:
            self.client.connect(
                self.host,
                port=self.port,
                username=self.username,
                password=self.password,
                look_for_keys=False,
                allow_agent=False,
                timeout=self.timeout,
            )
        except Exception as e:  # noqa: BLE001 - surface any auth/network failure uniformly
            raise TransportError(f"SSH connection to {self.host}:{self.port} failed: {e}") from e
        self.sftp = self.client.open_sftp()

    def close(self):
        if self.sftp:
            self.sftp.close()
        if self.client:
            self.client.close()

    def join(self, *parts):
        return self.path.join(*parts)

    def _stat(self, path):
        try:
            return self.sftp.stat(path)
        except FileNotFoundError:
            return None
        except IOError:
            return None

    def isdir(self, path):
        st = self._stat(path)
        return bool(st and stat.S_ISDIR(st.st_mode))

    def isfile(self, path):
        st = self._stat(path)
        return bool(st and stat.S_ISREG(st.st_mode))

    def exists(self, path):
        return self._stat(path) is not None

    def walk_files(self, root):
        if not self.isdir(root):
            return
        try:
            entries = self.sftp.listdir_attr(root)
        except IOError:
            return
        for entry in entries:
            full = self.path.join(root, entry.filename)
            if stat.S_ISDIR(entry.st_mode):
                yield from self.walk_files(full)
            elif stat.S_ISREG(entry.st_mode):
                yield full

    def fetch(self, source_path, local_dest_path):
        os.makedirs(os.path.dirname(local_dest_path), exist_ok=True)
        try:
            self.sftp.get(source_path, local_dest_path)
        except (IOError, OSError) as e:
            raise TransportError(f"Failed to fetch {source_path}: {e}") from e

    def _ensure_remote_dir(self, remote_dir):
        parts = []
        current = remote_dir
        while current and not self.exists(current):
            parts.append(current)
            parent = self.path.dirname(current.rstrip(self.path.sep))
            if parent == current:
                break
            current = parent
        for d in reversed(parts):
            try:
                self.sftp.mkdir(d)
            except IOError:
                pass  # created by a concurrent call or already exists

    def push(self, local_source_path, dest_path):
        remote_dir = self.path.dirname(dest_path)
        self._ensure_remote_dir(remote_dir)
        try:
            self.sftp.put(local_source_path, dest_path)
        except (IOError, OSError) as e:
            raise TransportError(f"Failed to push to {dest_path}: {e}") from e

    def remove(self, path):
        try:
            self.sftp.remove(path)
        except IOError:
            pass

    def run_command(self, cmd, env=None, timeout=1800):
        """cmd is an argv-style list, same interface as LocalTransport."""
        if self.remote_os == "windows":
            cmd_str = subprocess.list2cmdline(cmd)
            prefix = ""
            if env:
                prefix = " && ".join(f'set "{k}={v}"' for k, v in env.items()) + " && "
        else:
            import shlex
            cmd_str = " ".join(shlex.quote(part) for part in cmd)
            prefix = ""
            if env:
                prefix = " ".join(f"{k}={shlex.quote(str(v))}" for k, v in env.items()) + " "

        full_cmd = prefix + cmd_str
        try:
            _stdin, stdout, stderr = self.client.exec_command(full_cmd, timeout=timeout)
            out = stdout.read().decode(errors="replace")
            err = stderr.read().decode(errors="replace")
            rc = stdout.channel.recv_exit_status()
        except Exception as e:  # noqa: BLE001
            raise TransportError(f"Remote command failed: {e}") from e
        return rc, out, err


def build_transport(connection_type, form_data):
    """
    form_data: dict with keys depending on connection_type.
      local -> {}
      ssh   -> {host, port, username, password, remote_os}
    """
    if connection_type == "ssh":
        return SSHTransport(
            host=form_data["host"],
            port=form_data.get("port") or 22,
            username=form_data["username"],
            password=form_data.get("password", ""),
            remote_os=form_data.get("remote_os", "linux"),
        )
    return LocalTransport()
