import platform
import socket
import time

import psutil

_last_net = None
_last_net_time = None


def get_cpu_stats():
    freq = psutil.cpu_freq()
    try:
        load1, load5, load15 = psutil.getloadavg()
    except (OSError, AttributeError):
        load1 = load5 = load15 = 0.0

    temp_c = None
    try:
        temps = psutil.sensors_temperatures()
        for entries in temps.values():
            if entries:
                temp_c = entries[0].current
                break
    except (AttributeError, OSError):
        pass

    return {
        "percent": psutil.cpu_percent(interval=None),
        "per_core": psutil.cpu_percent(interval=None, percpu=True),
        "cores_logical": psutil.cpu_count(logical=True),
        "cores_physical": psutil.cpu_count(logical=False),
        "freq_mhz": round(freq.current, 0) if freq else None,
        "load_avg": {"1m": load1, "5m": load5, "15m": load15},
        "temp_c": temp_c,
    }


def get_memory_stats():
    vm = psutil.virtual_memory()
    swap = psutil.swap_memory()
    return {
        "total": vm.total,
        "used": vm.used,
        "available": vm.available,
        "percent": vm.percent,
        "swap_total": swap.total,
        "swap_used": swap.used,
        "swap_percent": swap.percent,
    }


def get_disk_stats():
    """Real, writable filesystems only. psutil's all=False still includes
    snap's read-only squashfs loop mounts (/snap/<name>/<rev>, device
    /dev/loopN) — those are compressed images sized exactly to their
    content, so they always report 100% used by design. That's not a disk
    problem; surfacing it as one is noise that drowns out real alerts."""
    disks = []
    seen_mounts = set()
    for part in psutil.disk_partitions(all=False):
        if part.mountpoint in seen_mounts:
            continue
        if part.fstype == "squashfs" or part.mountpoint.startswith("/snap/") or part.device.startswith("/dev/loop"):
            continue
        try:
            usage = psutil.disk_usage(part.mountpoint)
        except (PermissionError, OSError):
            continue
        seen_mounts.add(part.mountpoint)
        disks.append({
            "mountpoint": part.mountpoint,
            "device": part.device,
            "fstype": part.fstype,
            "total": usage.total,
            "used": usage.used,
            "free": usage.free,
            "percent": usage.percent,
        })
    return disks


def get_network_stats():
    global _last_net, _last_net_time

    counters = psutil.net_io_counters()
    now = time.time()

    upload_rate = download_rate = 0.0
    if _last_net is not None and _last_net_time is not None:
        elapsed = max(now - _last_net_time, 0.001)
        upload_rate = max((counters.bytes_sent - _last_net.bytes_sent) / elapsed, 0)
        download_rate = max((counters.bytes_recv - _last_net.bytes_recv) / elapsed, 0)

    _last_net = counters
    _last_net_time = now

    try:
        connections = len(psutil.net_connections(kind="inet"))
    except (PermissionError, OSError):
        connections = None

    return {
        "bytes_sent": counters.bytes_sent,
        "bytes_recv": counters.bytes_recv,
        "packets_sent": counters.packets_sent,
        "packets_recv": counters.packets_recv,
        "upload_rate_bps": upload_rate,
        "download_rate_bps": download_rate,
        "connections": connections,
    }


def get_server_info():
    try:
        hostname = socket.gethostname()
    except OSError:
        hostname = "unknown"

    try:
        private_ip = socket.gethostbyname(hostname)
    except OSError:
        private_ip = "unknown"

    boot_time = psutil.boot_time()
    uptime_seconds = int(time.time() - boot_time)

    return {
        "hostname": hostname,
        "private_ip": private_ip,
        "os_version": f"{platform.system()} {platform.release()}",
        "kernel": platform.version(),
        "uptime_seconds": uptime_seconds,
        "python_version": platform.python_version(),
    }


def get_full_snapshot():
    """Everything the dashboard needs in a single payload, for SocketIO emits."""
    return {
        "cpu": get_cpu_stats(),
        "memory": get_memory_stats(),
        "disk": get_disk_stats(),
        "network": get_network_stats(),
        "server": get_server_info(),
        "timestamp": time.time(),
    }
