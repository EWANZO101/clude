"""
All privileged systemd interaction goes through here, and all of it goes
through the svcmgr.sh helper via passwordless sudo - the app process itself
never needs to run as root.
"""
import subprocess
import tempfile
import os

SVCMGR = "/usr/local/bin/svcmgr.sh"

UNIT_TEMPLATE = """[Unit]
Description={description}
After=network.target

[Service]
Type=simple
User={run_user}
WorkingDirectory={working_dir}
{env_block}ExecStart={command}
Restart={restart_policy}
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
"""


class ServiceCtlError(RuntimeError):
    pass


def _run(args, timeout=15):
    try:
        result = subprocess.run(
            ["sudo", "-n", SVCMGR, *args],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except FileNotFoundError:
        raise ServiceCtlError("sudo or svcmgr.sh not found on this host")
    except subprocess.TimeoutExpired:
        raise ServiceCtlError(f"timed out running: {' '.join(args)}")

    if result.returncode != 0:
        msg = result.stderr.strip() or result.stdout.strip() or "unknown error"
        raise ServiceCtlError(msg)
    return result.stdout


def render_unit(service):
    env_block = ""
    lines = service.env_lines()
    if service.port:
        lines = [f"PORT={service.port}"] + lines
    for line in lines:
        env_block += f"Environment={line}\n"

    return UNIT_TEMPLATE.format(
        description=service.description or service.name,
        run_user=service.run_user or "www-data",
        working_dir=service.working_dir,
        env_block=env_block,
        command=service.command,
        restart_policy=service.restart_policy or "on-failure",
    )


def write_unit(service):
    content = render_unit(service)
    fd, tmp_path = tempfile.mkstemp(prefix="opslab-unit-")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(content)
        _run(["write", service.unit_name, tmp_path])
    finally:
        if os.path.exists(tmp_path):
            os.remove(tmp_path)


def start(service):
    _run(["start", service.unit_name])


def stop(service):
    _run(["stop", service.unit_name])


def restart(service):
    _run(["restart", service.unit_name])


def enable(service):
    _run(["enable", service.unit_name])


def disable(service):
    _run(["disable", service.unit_name])


def remove(service):
    _run(["remove", service.unit_name])


def status(service):
    """Returns dict: {'active': 'active'|'inactive'|'failed'|'unknown', 'enabled': 'enabled'|'disabled'|'unknown'}"""
    try:
        out = _run(["status", service.unit_name], timeout=8)
    except ServiceCtlError:
        return {"active": "unknown", "enabled": "unknown"}

    data = {"active": "unknown", "enabled": "unknown"}
    for line in out.splitlines():
        if line.startswith("active="):
            data["active"] = line.split("=", 1)[1] or "unknown"
        elif line.startswith("enabled="):
            data["enabled"] = line.split("=", 1)[1] or "unknown"
    return data


def logs(service, lines=150):
    try:
        return _run(["logs", service.unit_name, str(lines)], timeout=10)
    except ServiceCtlError as e:
        return f"(could not read logs: {e})"


def list_all_units():
    """
    Every service unit on the host (read-only, not limited to opslab-*).
    Returns a list of dicts: unit, load, active, sub, description.
    """
    try:
        out = _run(["list"], timeout=10)
    except ServiceCtlError:
        return []

    units = []
    for line in out.splitlines():
        line = line.strip()
        if not line or not line.endswith(".service") and ".service " not in line:
            continue
        parts = line.split(None, 4)
        if len(parts) < 4:
            continue
        unit, load, active, sub = parts[0], parts[1], parts[2], parts[3]
        description = parts[4] if len(parts) > 4 else ""
        if not unit.endswith(".service"):
            continue
        units.append({
            "unit": unit,
            "load": load,
            "active": active,
            "sub": sub,
            "description": description,
        })
    return units


def show_unit(unit_name):
    """Read-only introspection for any unit - used to preview what a
    not-yet-managed service looks like before importing it."""
    try:
        out = _run(["show", unit_name], timeout=8)
    except ServiceCtlError as e:
        return {"error": str(e)}

    data = {}
    for line in out.splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            data[k] = v
    return data
