import re
import subprocess

SERVICE_NAME_RE = re.compile(r"^[a-zA-Z0-9_.@-]+$")
ALLOWED_ACTIONS = {"start", "stop", "restart", "reload", "enable", "disable"}

# Actions that kill/replace this very process when targeted at the panel's
# own unit. "start"/"enable"/"disable" don't touch the running process;
# "reload" usually just SIGHUPs it. Those two are the ones that actually
# tear the worker down mid-response.
SELF_DEFERRED_ACTIONS = {"restart", "stop"}


class ServiceCommandError(Exception):
    pass


def _validate_service_name(name):
    # unit names may or may not include .service - normalize + validate strictly
    base = name[:-8] if name.endswith(".service") else name
    if not base or not SERVICE_NAME_RE.match(base):
        raise ServiceCommandError(f"'{name}' is not a valid service name.")
    return base + ".service"


def _run(args, timeout=15):
    try:
        result = subprocess.run(
            args, capture_output=True, text=True, timeout=timeout, check=False
        )
        return result
    except FileNotFoundError as exc:
        raise ServiceCommandError(
            "systemctl isn't available on this host. This panel needs a systemd-based Linux server."
        ) from exc
    except subprocess.TimeoutExpired as exc:
        raise ServiceCommandError(f"Command timed out: {' '.join(args)}") from exc


def list_services():
    """Return every service unit systemd knows about, running or not."""
    result = _run([
        "systemctl", "list-units", "--type=service", "--all",
        "--no-legend", "--no-pager", "--plain",
    ])
    if result.returncode != 0 and not result.stdout:
        raise ServiceCommandError(result.stderr.strip() or "Failed to list services.")

    services = []
    for line in result.stdout.splitlines():
        parts = line.split(None, 4)
        if len(parts) < 4:
            continue
        unit, load, active, sub = parts[0], parts[1], parts[2], parts[3]
        description = parts[4] if len(parts) > 4 else ""
        services.append({
            "unit": unit,
            "load": load,
            "active": active,
            "sub": sub,
            "running": active == "active" and sub == "running",
            "description": description,
        })

    # enabled/disabled state, fetched separately since list-units doesn't include it
    enabled_map = get_enabled_map()
    for svc in services:
        svc["enabled"] = enabled_map.get(svc["unit"], "unknown")

    return sorted(services, key=lambda s: s["unit"])


def get_enabled_map():
    result = _run([
        "systemctl", "list-unit-files", "--type=service",
        "--no-legend", "--no-pager", "--plain",
    ])
    mapping = {}
    for line in result.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 2:
            mapping[parts[0]] = parts[1]
    return mapping


def get_service_status(name):
    unit = _validate_service_name(name)
    result = _run(["systemctl", "show", unit, "--no-page",
                    "--property=ActiveState,SubState,LoadState,UnitFileState,Description,MainPID"])
    if result.returncode != 0:
        raise ServiceCommandError(result.stderr.strip() or f"No such service: {unit}")

    props = {}
    for line in result.stdout.splitlines():
        if "=" in line:
            k, _, v = line.partition("=")
            props[k] = v
    return props


def control_service(name, action):
    if action not in ALLOWED_ACTIONS:
        raise ServiceCommandError(f"'{action}' is not an allowed action.")
    unit = _validate_service_name(name)

    result = _run(["systemctl", action, unit])
    if result.returncode != 0:
        raise ServiceCommandError(result.stderr.strip() or f"Failed to {action} {unit}.")
    return True


def get_own_unit_name():
    """Best-effort detection of the systemd unit currently running this
    process, via its cgroup path. Used so restarting/stopping the panel's
    own service defers instead of killing the worker mid-response."""
    import os

    try:
        with open("/proc/self/cgroup", "r", encoding="utf-8") as f:
            content = f.read()
    except OSError:
        return None
    m = re.search(r"/([\w@.-]+\.service)\b", content)
    return m.group(1) if m else None


def schedule_self_action(name, action, delay=2):
    """Run `action` on `unit` a couple seconds from now, detached from this
    process (new session, so it survives this worker being killed). Use
    this instead of control_service() whenever the target is the panel's
    own unit and the action is restart/stop — that gives the HTTP response
    for the request a chance to actually reach the browser first, instead
    of the connection dying with NS_ERROR_NET_EMPTY_RESPONSE."""
    if action not in ALLOWED_ACTIONS:
        raise ServiceCommandError(f"'{action}' is not an allowed action.")
    unit = _validate_service_name(name)
    subprocess.Popen(
        ["/bin/sh", "-c", f"sleep {int(delay)} && systemctl {action} {unit}"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    return unit


def daemon_reload():
    result = _run(["systemctl", "daemon-reload"])
    if result.returncode != 0:
        raise ServiceCommandError(result.stderr.strip() or "daemon-reload failed.")
    return True


def get_recent_logs(name, lines=200):
    unit = _validate_service_name(name)
    result = _run(["journalctl", "-u", unit, "-n", str(lines), "--no-pager", "-o", "short-iso"])
    if result.returncode != 0:
        raise ServiceCommandError(result.stderr.strip() or f"Failed to read logs for {unit}.")
    return result.stdout


def generate_unit_file(app_name, working_dir, exec_start, run_user="root", description=""):
    """Build systemd unit text from the wizard fields. Does not write to disk."""
    base = app_name.strip()
    if not SERVICE_NAME_RE.match(base):
        raise ServiceCommandError(
            "Service name can only contain letters, numbers, dots, dashes, and underscores."
        )

    desc = description.strip() or f"{base} Application Service"
    unit_text = (
        "[Unit]\n"
        f"Description={desc}\n"
        "After=network.target\n\n"
        "[Service]\n"
        f"WorkingDirectory={working_dir}\n"
        f"ExecStart={exec_start}\n"
        "Restart=always\n"
        f"User={run_user}\n\n"
        "[Install]\n"
        "WantedBy=multi-user.target\n"
    )
    return base + ".service", unit_text


def install_unit_file(unit_filename, unit_text, systemd_dir="/etc/systemd/system"):
    import os

    path = os.path.join(systemd_dir, unit_filename)

    if os.path.isfile(path):
        from services import backup_service
        backup_service.backup_file(path)

    try:
        with open(path, "w", encoding="utf-8") as f:
            f.write(unit_text)
    except PermissionError as exc:
        raise ServiceCommandError(
            f"No permission to write {path}. The panel needs to run as root to manage systemd units."
        ) from exc
    return path


def verify_unit_file(name, systemd_dir="/etc/systemd/system"):
    """'Check file': confirm the unit exists and systemd can parse it."""
    import os

    unit = _validate_service_name(name)
    path = os.path.join(systemd_dir, unit)
    if not os.path.isfile(path):
        raise ServiceCommandError(f"{path} doesn't exist.")

    result = _run(["systemd-analyze", "verify", path])
    # systemd-analyze verify often returns non-zero even for harmless warnings,
    # so only treat it as fatal if there's no output at all alongside failure.
    output = (result.stdout or "") + (result.stderr or "")
    return {"path": path, "ok": result.returncode == 0, "output": output.strip()}
