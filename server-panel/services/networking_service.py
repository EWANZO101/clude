import glob
import os
import re
import socket
import subprocess

import psutil
import yaml

NETPLAN_DIR = "/etc/netplan"
IP_RE = re.compile(r"^(\d{1,3}\.){3}\d{1,3}$")
CIDR_RE = re.compile(r"^(\d{1,3}\.){3}\d{1,3}/\d{1,2}$")


class NetworkingError(Exception):
    pass


def _run(args, timeout=20):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=timeout, check=False)
    except FileNotFoundError as exc:
        raise NetworkingError(f"'{args[0]}' isn't available on this host.") from exc
    except subprocess.TimeoutExpired as exc:
        raise NetworkingError(f"Command timed out: {' '.join(args)}") from exc


def list_interfaces():
    """Interface name, IPs, MAC, and up/down state, from psutil (no root needed)."""
    addrs = psutil.net_if_addrs()
    stats = psutil.net_if_stats()

    interfaces = []
    for name, addr_list in addrs.items():
        entry = {"name": name, "ipv4": [], "ipv6": [], "mac": None,
                 "is_up": stats[name].isup if name in stats else None,
                 "speed_mbps": stats[name].speed if name in stats else None}
        for addr in addr_list:
            if addr.family == socket.AF_INET:
                entry["ipv4"].append({"address": addr.address, "netmask": addr.netmask})
            elif addr.family == socket.AF_INET6:
                entry["ipv6"].append({"address": addr.address.split("%")[0]})
            elif addr.family == psutil.AF_LINK:
                entry["mac"] = addr.address
        interfaces.append(entry)
    return sorted(interfaces, key=lambda i: i["name"])


def get_default_gateway():
    try:
        result = _run(["ip", "route", "show", "default"])
    except NetworkingError:
        return None
    if result.returncode != 0 or not result.stdout.strip():
        return None
    m = re.search(r"default via (\S+)", result.stdout)
    return m.group(1) if m else None


def get_dns_servers():
    servers = []
    try:
        with open("/etc/resolv.conf", "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line.startswith("nameserver"):
                    parts = line.split()
                    if len(parts) >= 2:
                        servers.append(parts[1])
    except OSError:
        pass
    return servers


def get_hostname():
    return socket.gethostname()


def set_hostname(new_hostname):
    new_hostname = new_hostname.strip()
    if not re.match(r"^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$", new_hostname):
        raise NetworkingError(f"'{new_hostname}' isn't a valid hostname.")
    result = _run(["hostnamectl", "set-hostname", new_hostname])
    if result.returncode != 0:
        raise NetworkingError(result.stderr.strip() or "Failed to set hostname.")
    return True


# ---- netplan ----

def _netplan_files():
    if not os.path.isdir(NETPLAN_DIR):
        return []
    return sorted(glob.glob(os.path.join(NETPLAN_DIR, "*.yaml")))


def read_netplan_config():
    """Merged view of every netplan yaml file found. Returns None if netplan isn't in use."""
    files = _netplan_files()
    if not files:
        return None

    merged = {}
    for path in files:
        try:
            with open(path, "r", encoding="utf-8") as f:
                data = yaml.safe_load(f) or {}
        except (OSError, yaml.YAMLError):
            continue
        merged[os.path.basename(path)] = data
    return merged


def write_static_ip(interface, address_cidr, gateway, dns_servers, filename="99-opslab-panel.yaml"):
    if not CIDR_RE.match(address_cidr):
        raise NetworkingError(f"'{address_cidr}' must be in CIDR form, e.g. 192.168.1.50/24.")
    if not IP_RE.match(gateway):
        raise NetworkingError(f"'{gateway}' isn't a valid gateway IP.")
    for dns in dns_servers:
        if not IP_RE.match(dns):
            raise NetworkingError(f"'{dns}' isn't a valid DNS server IP.")

    if not os.path.isdir(NETPLAN_DIR):
        raise NetworkingError(f"{NETPLAN_DIR} doesn't exist — this host may not use netplan.")

    config = {
        "network": {
            "version": 2,
            "ethernets": {
                interface: {
                    "addresses": [address_cidr],
                    "routes": [{"to": "default", "via": gateway}],
                    "nameservers": {"addresses": dns_servers},
                }
            },
        }
    }

    path = os.path.join(NETPLAN_DIR, filename)
    try:
        with open(path, "w", encoding="utf-8") as f:
            yaml.safe_dump(config, f, default_flow_style=False, sort_keys=False)
        os.chmod(path, 0o600)
    except PermissionError as exc:
        raise NetworkingError(f"No permission to write {path}. The panel needs to run as root.") from exc

    return path


def apply_netplan():
    result = _run(["netplan", "apply"], timeout=30)
    if result.returncode != 0:
        raise NetworkingError(result.stderr.strip() or "netplan apply failed.")
    return True


def netplan_available():
    try:
        result = _run(["netplan", "--help"])
    except NetworkingError:
        return False
    return result.returncode == 0
