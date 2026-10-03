"""Read-only security telemetry: who's actually connected over SSH right
now, which IPs are currently denied at the firewall, and a rolled-up
"is this host okay" health score for the dashboard.

Deliberately has no state of its own — everything here is derived fresh
from `who`/`ss`/psutil/ufw on every call, same philosophy as
firewall_service.get_numbered_rules(): nothing to drift out of sync with
reality. The stateful, learning half of this (baseline traffic modelling,
per-IP flood scoring) lives in ddos_service.py.
"""
import re
import subprocess
import time

import psutil

from services import firewall_service as fw

SSH_PORT = 22


def _run(args, timeout=8):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=timeout, check=False)
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None


# ---------------------------------------------------------------------------
# Live SSH sessions
# ---------------------------------------------------------------------------

def _who_sessions():
    """Logged-in interactive sessions via `who`, keyed by tty. Gives us
    login time + idle time, which `ss` alone can't."""
    result = _run(["who", "-u"])
    sessions = []
    if result is None or result.returncode != 0:
        return sessions

    for line in result.stdout.splitlines():
        # user  pts/1  2026-07-13 09:14  .  1234 (203.0.113.4)
        m = re.match(
            r"^(\S+)\s+(\S+)\s+([\d-]+\s+[\d:]+)\s+(\S+)\s+(\d+)?\s*(?:\((\S+)\))?\s*$",
            line.strip(),
        )
        if not m:
            continue
        user, tty, when, idle, pid, remote = m.groups()
        sessions.append({
            "user": user,
            "tty": tty,
            "login_time": when,
            "idle": idle,
            "pid": pid,
            "remote_host": remote,
        })
    return sessions


def _ss_ssh_established():
    """Established TCP connections on port 22, either direction, via ss.
    This is what actually proves an SSH connection is live right now,
    independent of whether the remote side authenticated a shell (a
    connection can be established mid-handshake before `who` would show
    anything)."""
    result = _run(["ss", "-tnp", "state", "established", f"( sport = :{SSH_PORT} or dport = :{SSH_PORT} )"])
    conns = []
    if result is None or result.returncode != 0:
        return conns

    for line in result.stdout.splitlines()[1:]:
        parts = line.split()
        if len(parts) < 5:
            continue
        local_addr, peer_addr = parts[3], parts[4]
        remote_ip = peer_addr.rsplit(":", 1)[0].strip("[]")
        local_port = local_addr.rsplit(":", 1)[-1]
        conns.append({
            "remote_ip": remote_ip,
            "direction": "inbound" if local_port == str(SSH_PORT) else "outbound",
        })
    return conns


def get_ssh_sessions():
    """Merge `who` (has user/login-time/idle) with `ss` (has the actual
    remote IP, and catches connections `who` wouldn't show yet). Returned
    list is sessions-first; any inbound ss connection with no matching
    `who` entry is appended as an "unauthenticated / key-only" row so a
    connection someone's mid-handshake on, or a non-interactive scp/rsync
    session, doesn't just silently disappear from the view."""
    who = _who_sessions()
    ss_inbound = [c for c in _ss_ssh_established() if c["direction"] == "inbound"]

    sessions = []
    used = 0
    for entry in who:
        remote = entry["remote_host"]
        if not remote and used < len(ss_inbound):
            remote = ss_inbound[used]["remote_ip"]
            used += 1
        sessions.append({
            "user": entry["user"],
            "remote_ip": remote or "unknown",
            "tty": entry["tty"],
            "login_time": entry["login_time"],
            "idle": entry["idle"],
            "authenticated": True,
        })

    # Any leftover established connections with no matching `who` row.
    accounted = {s["remote_ip"] for s in sessions}
    for conn in ss_inbound:
        if conn["remote_ip"] in accounted:
            continue
        sessions.append({
            "user": None,
            "remote_ip": conn["remote_ip"],
            "tty": None,
            "login_time": None,
            "idle": None,
            "authenticated": False,
        })
        accounted.add(conn["remote_ip"])

    return sessions


# ---------------------------------------------------------------------------
# Live session activity — what is each SSH session actually doing right now
# ---------------------------------------------------------------------------

def _fmt_etimes(etimes_str):
    try:
        secs = int(etimes_str)
    except ValueError:
        return etimes_str or "—"
    h, rem = divmod(secs, 3600)
    m, s = divmod(rem, 60)
    if h:
        return f"{h}h{m:02d}m"
    if m:
        return f"{m}m{s:02d}s"
    return f"{s}s"


def _tty_processes(tty):
    """Every process currently attached to a given controlling tty, via ps.
    This is what turns 'someone is logged in' into 'here's what they're
    actually running' — the login shell itself plus anything spawned in it
    (top, a build, a tail -f, vim, etc.)."""
    result = _run(["ps", "-t", tty, "-o", "pid=,pcpu=,pmem=,etimes=,comm=,args="])
    if result is None or result.returncode != 0:
        return []

    procs = []
    for line in result.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split(None, 5)
        if len(parts) < 6:
            continue
        pid, pcpu, pmem, etimes, comm, args = parts
        procs.append({
            "pid": pid,
            "cpu": pcpu,
            "mem": pmem,
            "runtime": _fmt_etimes(etimes),
            "command": comm,
            "args": args[:160],
        })
    # Busiest first so the interesting stuff floats to the top.
    procs.sort(key=lambda p: float(p["cpu"] or 0), reverse=True)
    return procs


def get_session_activity():
    """Live 'what is each SSH session doing' view: every current session
    (from get_ssh_sessions()) paired with the processes attached to its tty.
    Unauthenticated/tty-less entries (raw `ss` connections with no `who`
    match) are skipped since there's no tty to inspect.
    Read-only, same philosophy as everything else in this module — nothing
    to drift out of sync with reality."""
    activity = []
    for s in get_ssh_sessions():
        tty = s.get("tty")
        if not tty:
            continue
        activity.append({
            "user": s["user"],
            "remote_ip": s["remote_ip"],
            "tty": tty,
            "idle": s.get("idle"),
            "processes": _tty_processes(tty),
        })
    return activity


# ---------------------------------------------------------------------------
# Blocked / denied IPs
# ---------------------------------------------------------------------------

def get_blocked_ips():
    """Every 'deny' rule ufw currently has loaded, protected or not, plus
    where it came from (manual vs the DDoS auto-mitigation system tags its
    own rules — see ddos_service.BLOCK_COMMENT)."""
    if not fw.is_installed():
        return []
    try:
        rules = fw.get_numbered_rules()
    except fw.FirewallError:
        return []

    blocked = []
    for rule in rules:
        if rule.get("kind") != "deny" or not rule.get("ip"):
            continue
        blocked.append({
            "number": rule["number"],
            "ip": rule["ip"],
            "text": rule["text"],
            "protected": rule["protected"],
            "auto_blocked": "ddos-auto" in rule["text"],
        })
    return blocked


# ---------------------------------------------------------------------------
# Connection breakdown (top talkers) — the closest universal proxy for
# per-IP "bandwidth usage" without requiring iftop/nethogs to be installed.
# ---------------------------------------------------------------------------

def get_top_connections(limit=10):
    result = _run(["ss", "-tn", "state", "established"])
    if result is None or result.returncode != 0:
        return []

    counts = {}
    for line in result.stdout.splitlines()[1:]:
        parts = line.split()
        if len(parts) < 5:
            continue
        remote_ip = parts[4].rsplit(":", 1)[0].strip("[]")
        if not remote_ip or remote_ip in ("127.0.0.1", "::1"):
            continue
        counts[remote_ip] = counts.get(remote_ip, 0) + 1

    ranked = sorted(counts.items(), key=lambda kv: kv[1], reverse=True)[:limit]
    return [{"ip": ip, "connections": n} for ip, n in ranked]


def get_connection_count():
    try:
        return len(psutil.net_connections(kind="inet"))
    except (PermissionError, OSError):
        return None


# ---------------------------------------------------------------------------
# Rolled-up "smart" health score for the dashboard
# ---------------------------------------------------------------------------

def compute_health(snapshot, ddos_status=None):
    """Turns the raw metrics snapshot (+ optional ddos status) into a single
    healthy/warning/critical verdict with the specific reasons behind it,
    so the dashboard can show one badge instead of making someone eyeball
    four separate gauges."""
    reasons = []
    level = "healthy"

    def bump(new_level, reason):
        nonlocal level
        order = {"healthy": 0, "warning": 1, "critical": 2}
        if order[new_level] > order[level]:
            level = new_level
        reasons.append(reason)

    cpu_pct = snapshot["cpu"]["percent"]
    if cpu_pct >= 90:
        bump("critical", f"CPU at {cpu_pct:.0f}%")
    elif cpu_pct >= 75:
        bump("warning", f"CPU at {cpu_pct:.0f}%")

    mem_pct = snapshot["memory"]["percent"]
    if mem_pct >= 90:
        bump("critical", f"Memory at {mem_pct:.0f}%")
    elif mem_pct >= 80:
        bump("warning", f"Memory at {mem_pct:.0f}%")

    for disk in snapshot.get("disk", []):
        if disk["percent"] >= 95:
            bump("critical", f"{disk['mountpoint']} at {disk['percent']:.0f}% full")
        elif disk["percent"] >= 85:
            bump("warning", f"{disk['mountpoint']} at {disk['percent']:.0f}% full")

    load1 = snapshot["cpu"]["load_avg"]["1m"]
    cores = snapshot["cpu"]["cores_logical"] or 1
    if load1 >= cores * 2:
        bump("critical", f"Load average {load1:.2f} on {cores} cores")
    elif load1 >= cores * 1.3:
        bump("warning", f"Load average {load1:.2f} on {cores} cores")

    if ddos_status:
        if ddos_status["state"] == "under_attack":
            bump("critical", "DDoS protection reports an active attack")
        elif ddos_status["state"] == "elevated":
            bump("warning", "Traffic is elevated above the learned baseline")

    if not reasons:
        reasons.append("All monitored metrics are within normal range")

    return {"level": level, "reasons": reasons}
