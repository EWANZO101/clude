"""
Local system detection. Kept deliberately conservative — if something can't
be determined (e.g. no default route yet at boot), every function here
returns None rather than raising, so a detection hiccup never blocks
registration or a heartbeat.
"""
import platform
import socket
from pathlib import Path

from agent import __version__ as AGENT_VERSION


def detect_os() -> str:
    """Returns one of the Admin Panel's SUPPORTED_OS values: 'ubuntu',
    'debian', or 'windows'."""
    system = platform.system()
    if system == "Windows":
        return "windows"
    if system == "Linux":
        os_release = Path("/etc/os-release")
        if os_release.exists():
            values = {}
            for line in os_release.read_text().splitlines():
                if "=" in line:
                    k, _, v = line.partition("=")
                    values[k] = v.strip('"')
            os_id = values.get("ID", "").lower()
            id_like = values.get("ID_LIKE", "").lower()
            if "ubuntu" in os_id:
                return "ubuntu"
            if "debian" in os_id or "debian" in id_like:
                return "debian"
        # Unknown Linux distro — closest supported match per the install spec's
        # Ubuntu/Debian target, rather than failing registration outright.
        return "debian"
    raise RuntimeError(f"Unsupported platform: {system!r} (Admin Panel supports ubuntu/debian/windows)")


def detect_os_version() -> str:
    system = platform.system()
    if system == "Windows":
        return platform.version()
    os_release = Path("/etc/os-release")
    if os_release.exists():
        for line in os_release.read_text().splitlines():
            if line.startswith("VERSION_ID="):
                return line.split("=", 1)[1].strip('"')
    return platform.release()


def detect_hostname() -> str:
    return socket.gethostname()


def detect_local_ip() -> str:
    """Best-effort outbound-facing local IP. Uses a UDP 'connect' (no packet
    actually sent) purely to ask the OS which interface it would route
    through — works even with no internet reachability."""
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("8.8.8.8", 80))
            return s.getsockname()[0]
    except OSError:
        return None


def agent_version() -> str:
    return AGENT_VERSION
