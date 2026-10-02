"""
Local system detection. Kept deliberately conservative — if something can't
be determined (e.g. no default route yet at boot), every function here
returns None rather than raising, so a detection hiccup never blocks
registration or a heartbeat.
"""
import logging
import os
import platform
import socket
import sys
from pathlib import Path

from agent import __version__ as AGENT_VERSION

log = logging.getLogger("agent.system_info")


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


def resolve_python_executable() -> str:
    """The python interpreter to use for launching a plain script (like the
    Kiosk Application's run.py) as a subprocess — usually just
    sys.executable, EXCEPT when this Agent process is itself running as an
    installed Windows service. The Windows Service Manager runs pywin32
    services via pythonservice.exe (its service host), so sys.executable
    inside a running service reports pythonservice.exe rather than a real
    python.exe usable to launch an arbitrary script — using it as-is would
    make an auto-defaulted kiosk_start_command (agent/update_manager.py)
    silently fail to launch under the one way this Agent is actually
    deployed in production, while looking completely correct in every
    foreground/console test (python.exe service\\opslab_agent_service.py
    run) and on Linux (systemd always runs the venv's real python
    directly, per install.sh - no pythonservice.exe equivalent there).

    Detected by executable NAME rather than platform, since the same
    console 'run' mode also has to keep working correctly on Windows.
    """
    exe_name = os.path.basename(sys.executable).lower()
    if "pythonservice" not in exe_name:
        return sys.executable

    # agent/ and the bundled python/ runtime are installed as siblings
    # under the same install root by install.ps1 - walk up from THIS
    # package's own location (.../OpsLabAgent/agent/system_info.py) to
    # find python/python.exe next to it.
    agent_pkg_dir = os.path.dirname(os.path.abspath(__file__))
    install_root = os.path.dirname(agent_pkg_dir)
    candidate = os.path.join(install_root, "python", "python.exe")
    if os.path.isfile(candidate):
        return candidate

    log.warning(
        "Running under %s but could not find a sibling python.exe at %s — "
        "falling back to sys.executable, which will likely fail to launch a plain script.",
        exe_name, candidate,
    )
    return sys.executable
