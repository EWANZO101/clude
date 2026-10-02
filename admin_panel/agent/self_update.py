"""
Handles the 'agent_update' InstanceCommand — see the Admin Panel's
app/blueprints/instances.py::agent_self_update, which queues it, and that
route's own docstring for the full picture.

HONEST LIMITATION: like service_files/windows/opslab_agent_service.py and
install.ps1, this has NOT been run on a real Windows machine — this build
environment is Linux-only. The download/checksum/extract steps below are
plain, portable Python (requests/hashlib/tarfile) and have been exercised
directly against a throwaway server; the detached-process launch and the
PowerShell script it hands off to could only be reviewed for correctness
against documented Windows behavior, not executed end to end.

THE ACTUAL PROBLEM THIS SOLVES: agent/commands.py's check_and_execute runs
every command handler, including this one's caller, on a thread that
service_files/windows/opslab_agent_service.py's SvcStop() has to join
before it can report the service stopped. If this module tried to stop
the OpsLabAgent service itself — the obvious, naive way to apply an
update — it would be asking the service to wait for its own shutdown to
finish before IT can finish shutting down: a self-referential deadlock.
That's exactly what happened on 2026-09-09 with an ad hoc run_command
script that did this (see project memory
project-ewan-instance-agent-no-autoupdate). The fix here is the standard
one for self-updating Windows services: do the actual stop + swap + start
from a SEPARATE, fully detached process that is not part of the service's
own thread/process tree at all, so the service dying mid-update can't
block anything.

Deliberately narrow: swaps ONLY the agent/ folder inside the install
root, nothing else (not service_files/, not requirements.txt, not the
bundled Python runtime) — see instances.py::agent_self_update's docstring
for why. settings.json lives entirely outside the install root (see
agent/config.py::default_data_dir — %ProgramData%\\OpsLabAgent on
Windows, /etc/opslab-agent on Linux), so it is never at risk from this
swap regardless of where the install root itself is.
"""
import hashlib
import logging
import os
import platform
import subprocess
import tarfile
import tempfile

import requests

from agent.config import AgentSettings

log = logging.getLogger("agent.self_update")

DOWNLOAD_TIMEOUT_SECONDS = 120
SERVICE_NAME = "OpsLabAgent"          # Windows service name (opslab_agent_service.py)
SYSTEMD_UNIT_NAME = "opslab-agent"    # Linux unit name (service_files/systemd)


def _install_root(settings: AgentSettings) -> str:
    """agent/config.py has no explicit "install root" setting (only
    app_install_dir, download_dir, etc, each resolved independently) — but
    every one of those is a sibling of agent/ under the same parent
    (install.ps1's $InstallDir / the systemd unit's WorkingDirectory), so
    its parent is a safe way to find that shared root without adding a
    new setting."""
    return os.path.dirname(os.path.normpath(settings.resolve_app_install_dir()))


def _sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def _download(url: str, dest_path: str) -> None:
    with requests.get(url, stream=True, timeout=DOWNLOAD_TIMEOUT_SECONDS) as resp:
        resp.raise_for_status()
        with open(dest_path, "wb") as f:
            for chunk in resp.iter_content(chunk_size=1024 * 1024):
                if chunk:
                    f.write(chunk)


def _safe_extract(tarball_path: str, dest_dir: str) -> None:
    """Guards against a path-traversal ("tarbomb") member escaping
    dest_dir — belt-and-suspenders given the checksum above already
    verifies this came from the Admin Panel unmodified, but cheap enough
    to always do."""
    os.makedirs(dest_dir, exist_ok=True)
    with tarfile.open(tarball_path, "r:gz") as tar:
        for member in tar.getmembers():
            member_path = os.path.realpath(os.path.join(dest_dir, member.name))
            if not member_path.startswith(os.path.realpath(dest_dir) + os.sep):
                raise tarfile.TarError(f"Refusing to extract member outside target dir: {member.name!r}")
        tar.extractall(dest_dir)


def _launch_detached_windows_updater(install_root: str, new_agent_dir: str, staging_root: str) -> None:
    downloads_dir = os.path.join(install_root, "downloads")
    os.makedirs(downloads_dir, exist_ok=True)
    log_path = os.path.join(downloads_dir, "agent_update_log.txt")
    script_path = os.path.join(downloads_dir, "apply_agent_update.ps1")
    target_agent_dir = os.path.join(install_root, "agent")

    script = f"""$ErrorActionPreference = "Continue"
$ServiceName = "{SERVICE_NAME}"
$TargetAgentDir = "{target_agent_dir}"
$NewAgentDir = "{new_agent_dir}"
$StagingRoot = "{staging_root}"
$LogFile = "{log_path}"

function Log($msg) {{
    "$([DateTime]::UtcNow.ToString('o'))  $msg" | Out-File -FilePath $LogFile -Append -Encoding utf8
}}

# Give the Agent's own ack_command HTTP call (reporting this update as
# staged) a moment to actually land before the service that's sending it
# potentially goes away.
Start-Sleep -Seconds 2
Log "agent_update: starting (new agent/ staged at $NewAgentDir)"

try {{
    Log "Stopping service $ServiceName..."
    Stop-Service -Name $ServiceName -Force -ErrorAction Stop

    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Service -Name $ServiceName).Status -ne 'Stopped' -and (Get-Date) -lt $deadline) {{
        Start-Sleep -Milliseconds 500
    }}
    if ((Get-Service -Name $ServiceName).Status -ne 'Stopped') {{
        throw "Service did not report Stopped within 30s."
    }}

    Log "Removing $TargetAgentDir..."
    Remove-Item -Recurse -Force $TargetAgentDir -ErrorAction Stop
    Log "Copying new agent code into place..."
    Copy-Item -Recurse -Force $NewAgentDir $TargetAgentDir -ErrorAction Stop

    Log "Starting service $ServiceName..."
    Start-Service -Name $ServiceName -ErrorAction Stop
    Log "agent_update: completed successfully."
}} catch {{
    Log "agent_update: FAILED - $_"
    Log "Attempting to restart $ServiceName on whatever agent/ is currently on disk..."
    try {{ Start-Service -Name $ServiceName -ErrorAction SilentlyContinue }} catch {{}}
}} finally {{
    Start-Sleep -Seconds 2
    Remove-Item -Recurse -Force $StagingRoot -ErrorAction SilentlyContinue
}}
"""
    with open(script_path, "w", encoding="utf-8") as f:
        f.write(script)

    # DETACHED_PROCESS + CREATE_NEW_PROCESS_GROUP take this fully out of
    # the current process's console/process group; CREATE_BREAKAWAY_FROM_JOB
    # additionally takes it out of any Job Object the service host might be
    # part of (harmless no-op if it isn't). Together, this survives the
    # parent Agent process being killed moments from now by the
    # Stop-Service call above — the whole point of running it here instead
    # of in-process.
    creationflags = (
        getattr(subprocess, "DETACHED_PROCESS", 0)
        | getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)
        | getattr(subprocess, "CREATE_BREAKAWAY_FROM_JOB", 0)
    )
    # Real incident (2026-09-12/13): powershell.exe launched fine (Popen
    # never raised) but the script never ran even its first statement — no
    # agent_update_log.txt, service never touched. With stdout/stderr sent
    # to DEVNULL there was no way to tell whether that was an execution-
    # policy/AppLocker/AV rejection or something else, because the one
    # place that error message would have gone was discarded. Capturing it
    # to a file next to the script itself means the NEXT failure is
    # diagnosable instead of another silent no-op.
    launcher_log_path = os.path.join(downloads_dir, "apply_agent_update.launcher_log.txt")
    with open(launcher_log_path, "wb") as launcher_log:
        subprocess.Popen(
            ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script_path],
            creationflags=creationflags, close_fds=True,
            stdin=subprocess.DEVNULL, stdout=launcher_log, stderr=subprocess.STDOUT,
        )


def _launch_detached_posix_updater(install_root: str, new_agent_dir: str, staging_root: str) -> None:
    downloads_dir = os.path.join(install_root, "downloads")
    os.makedirs(downloads_dir, exist_ok=True)
    log_path = os.path.join(downloads_dir, "agent_update_log.txt")
    script_path = os.path.join(downloads_dir, "apply_agent_update.sh")
    target_agent_dir = os.path.join(install_root, "agent")

    script = f"""#!/bin/sh
set -u
log() {{ printf '%s  %s\\n' "$(date -u +%FT%TZ)" "$1" >> "{log_path}"; }}

sleep 2
log "agent_update: starting (new agent/ staged at {new_agent_dir})"

if systemctl stop {SYSTEMD_UNIT_NAME}; then
    log "Removing {target_agent_dir}..."
    rm -rf "{target_agent_dir}"
    log "Copying new agent code into place..."
    cp -a "{new_agent_dir}" "{target_agent_dir}"
    if systemctl start {SYSTEMD_UNIT_NAME}; then
        log "agent_update: completed successfully."
    else
        log "agent_update: FAILED to start {SYSTEMD_UNIT_NAME} after swap."
    fi
else
    log "agent_update: FAILED to stop {SYSTEMD_UNIT_NAME} — leaving agent/ untouched."
fi

sleep 2
rm -rf "{staging_root}"
"""
    with open(script_path, "w", encoding="utf-8") as f:
        f.write(script)
    os.chmod(script_path, 0o755)

    # start_new_session detaches this from the current process group/session
    # (equivalent purpose to the Windows flags above) so it survives
    # `systemctl stop` tearing down this Agent's own process. See the
    # Windows launcher's own note on why stdout/stderr go to a file
    # instead of DEVNULL — same diagnosability fix, same reasoning.
    launcher_log_path = os.path.join(downloads_dir, "apply_agent_update.launcher_log.txt")
    with open(launcher_log_path, "wb") as launcher_log:
        subprocess.Popen(
            ["/bin/sh", script_path],
            start_new_session=True, close_fds=True,
            stdin=subprocess.DEVNULL, stdout=launcher_log, stderr=subprocess.STDOUT,
        )


def run_agent_update(settings: AgentSettings, payload: dict) -> tuple:
    """Returns (ok, message), same shape every other command handler in
    agent/commands.py uses. ok=True only means "the swap was staged and a
    detached helper was launched to apply it" — NOT "the update is
    confirmed applied", since by definition this process (and the service
    hosting it) may not survive long enough to find out. Check the Admin
    Panel's Instance.agent_version, or agent_update_log.txt in the
    install root's downloads/ folder on the machine itself, a minute or
    two later to confirm."""
    download_url = (payload or {}).get("download_url")
    expected_checksum = (payload or {}).get("checksum_sha256")
    if not download_url or not expected_checksum:
        return False, "Missing download_url or checksum_sha256 in command payload."

    install_root = _install_root(settings)
    agent_dir = os.path.join(install_root, "agent")
    if not os.path.isdir(agent_dir):
        return False, f"Expected an existing agent/ folder at {agent_dir!r} — refusing to guess where to install into."

    staging_root = tempfile.mkdtemp(prefix="opslab_agent_update_")
    tarball_path = os.path.join(staging_root, "opslab-agent.tar.gz")

    try:
        _download(download_url, tarball_path)
    except (requests.RequestException, OSError) as e:
        return False, f"Download failed: {e}"

    actual_checksum = _sha256(tarball_path)
    if actual_checksum.lower() != expected_checksum.lower():
        return False, f"Checksum mismatch — expected {expected_checksum}, got {actual_checksum}. Refusing to apply."

    extract_dir = os.path.join(staging_root, "extracted")
    try:
        _safe_extract(tarball_path, extract_dir)
    except (tarfile.TarError, OSError) as e:
        return False, f"Extraction failed: {e}"

    new_agent_dir = os.path.join(extract_dir, "agent")
    if not os.path.isdir(new_agent_dir):
        return False, f"Downloaded package has no agent/ folder at its root ({new_agent_dir!r}) — refusing to apply."

    try:
        if platform.system() == "Windows":
            _launch_detached_windows_updater(install_root, new_agent_dir, staging_root)
        else:
            _launch_detached_posix_updater(install_root, new_agent_dir, staging_root)
    except OSError as e:
        return False, f"Could not launch the detached update helper: {e}"

    return True, (
        f"Update staged and a detached helper launched to stop {SERVICE_NAME}, swap agent/, and "
        f"restart it. This process (and the service hosting it) may end here — check "
        f"agent_update_log.txt (written by the script itself once it starts) or "
        f"apply_agent_update.launcher_log.txt (captures why it *didn't* start, if it didn't) in "
        f"the install root's downloads/ folder, or this instance's agent_version in a minute or "
        f"two, to confirm it finished."
    )
