"""Adaptive traffic-baseline learning + DDoS/flood detection.

How the "learning" works, in plain terms: this host's normal traffic isn't
a fixed number, so instead of hardcoding thresholds, we keep a running
exponentially-weighted mean and standard deviation for a handful of
metrics (connection count, new-connection rate, in/out bandwidth, and the
largest single-IP connection count seen). Every sample nudges the baseline
a little. Once we've seen enough samples we switch from "learning" to
"active" mode and start comparing each new sample against how many
standard deviations (a z-score) it is from what's normal for this host. A
handful of standard deviations out is unusual by definition, regardless of
whether this box normally does 5 req/s or 5000.

Two independent things get scored:
  1. Global traffic shape (connection count, new-conn rate, bandwidth) —
     produces the overall state: normal / elevated / under_attack.
     Reaching "under_attack" requires a connection-shape anomaly
     (conn_count or new_conn_rate) specifically — a bandwidth-only spike
     (e.g. someone kicking off a large legitimate backup or download)
     caps out at "elevated" instead of triggering a full attack alert,
     since raw bytes moving isn't the DDoS signature on its own.
  2. Per-source-IP connection concentration — a single IP opening far more
     connections than is normal *for this host* is the classic flood/DDoS
     signature, and gets tracked as a "suspect" independent of the global
     state (a slow-and-low flood from one IP might not move the global
     average much, but is still worth flagging). The threshold for this
     is itself adaptive: a host that's normally proxying for many users
     behind NAT and regularly sees 60 connections from one address needs
     a higher bar than a quiet box where 15 would be unusual. A sane
     absolute floor and ceiling keep the adaptive threshold from drifting
     somewhere useless in either direction. Suspects that are far past the
     threshold escalate to auto-block faster than ones that are barely
     over it, instead of every suspect accumulating at the same fixed
     rate regardless of severity.

The baseline deliberately freezes (stops updating) while the host is in
an elevated/under_attack state, so an actual attack never gets "learned"
as the new normal.

The learned baseline is also periodically saved to disk and reloaded on
startup, so restarting the panel (a deploy, a reboot) doesn't reset
detection to a blind ~10-minute relearning window every time — that gap
was previously the easiest moment for an attack to go unnoticed.

--- What's new in this revision ---
  - Trusted-IP / CIDR whitelist (IPv4 and IPv6): addresses you explicitly
    trust (your own monitoring box, a reverse proxy, known NAT gateway,
    etc.) are excluded from per-IP suspect scoring entirely, and are
    purged from any existing suspect record the moment they're added.
  - Runtime-configurable thresholds: the z-score bands, per-IP floor/
    ceiling, and auto-block score are no longer fixed constants you have
    to edit code and restart to change — they live in _state["config"],
    are adjustable via update_config() with sane clamped ranges (so a
    typo can't accidentally disable detection), and persist across
    restarts the same way the learned baseline does.
  - Per-suspect context snapshot: each suspect record now carries the
    global z-scores captured at the moment it was first flagged, so a
    human reviewing the Security page can see *why* the moment looked
    unusual, not just the raw connection count.
  - Periodic re-alerting instead of one-and-done: previously a suspect
    that crossed the auto-block score with auto-mitigation off got
    exactly one "review and block manually" event, ever, for that
    suspect's lifetime. Now it re-alerts every `event_repeat_interval`
    seconds (configurable) for as long as it stays unresolved, without
    spamming the log every 3s tick.

This is statistical anomaly detection, not machine learning in the
model-training sense — no external libraries, no training data, just
adaptive baselining. It runs entirely locally and never phones home.
"""
import ipaddress
import json
import os
import threading
import time
from collections import deque
from datetime import datetime

import psutil

from services import firewall_service as fw
from services import security_service as sec

BLOCK_COMMENT = "ddos-auto"

# How many samples before we trust the baseline enough to start flagging
# anomalies. At the default 3s tick this is ~10 minutes.
LEARNING_SAMPLES = 200

# EWMA smoothing factor for the baseline mean/variance. Lower = slower to
# drift, more resistant to a single noisy sample.
BASELINE_ALPHA = 0.04

# Minimum standard deviation floor per metric, in that metric's own units.
# _z_score() used a single universal epsilon (1e-6) here before, which is
# fine for preventing a literal division by zero but does NOT prevent the
# z-score from exploding: on a quiet host a metric's *real* variance can
# legitimately decay toward zero (e.g. new_conn_rate sitting at ~0 for a
# long stretch), and once std is ~1e-6, any ordinary fluctuation of even a
# few tenths of a unit divides out to a z-score in the hundreds of
# thousands — which is exactly what produced a "391038.54" composite score
# from a completely unremarkable 0.39 conns/sec blip. These floors are
# calibrated to each metric's real-world noise scale, so std can never
# shrink below "a fluctuation this small isn't meaningful anyway."
MIN_STD_FLOOR = {
    "conn_count": 1.0,          # sub-1-connection variance isn't meaningful
    "new_conn_rate": 0.5,       # half a new connection/sec of noise is normal
    "bytes_in_rate": 1024.0,    # sub-1KB/s fluctuation is measurement noise
    "bytes_out_rate": 1024.0,
    "top_ip_conn_count": 1.0,
}

# --- Default thresholds. These seed _state["config"] on first run; after
# that, _state["config"] (adjustable via update_config(), persisted to
# disk) is the source of truth — these constants are just fallbacks. ---

# z-score bands for the composite global-traffic score.
Z_ELEVATED = 3.0
Z_ATTACK = 6.0

# A single remote IP holding this many concurrent connections is treated
# as a flood candidate outright before the baseline has learned anything,
# and is also the hard ceiling divisor for the adaptive threshold below —
# a sane floor for a small self-hosted box, not a per-deployment tuned
# value.
PER_IP_HARD_FLOOR = 40

# Once the baseline is active, the per-IP flood threshold adapts to this
# many standard deviations above this host's normal "largest single-IP
# connection count", bounded below by PER_IP_ABS_MIN (so a very quiet
# host doesn't start flagging at 2-3 connections) and above by
# PER_IP_HARD_FLOOR * PER_IP_ADAPTIVE_CAP_MULT (so a host that's already
# unusually busy can't adapt its way out of ever detecting a flood).
PER_IP_Z_THRESHOLD = 4.0
PER_IP_ABS_MIN = 8
PER_IP_ADAPTIVE_CAP_MULT = 3

# Suspect score needed before auto-mitigation (if enabled) blocks an IP.
AUTO_BLOCK_SCORE = 5

# How often (seconds) to re-emit a "still needs review" event for a
# suspect that's past the auto-block score but auto-mitigation is off.
EVENT_REPEAT_INTERVAL = 60

DEFAULT_CONFIG = {
    "z_elevated": Z_ELEVATED,
    "z_attack": Z_ATTACK,
    "per_ip_z_threshold": PER_IP_Z_THRESHOLD,
    "per_ip_abs_min": PER_IP_ABS_MIN,
    "per_ip_hard_floor": PER_IP_HARD_FLOOR,
    "per_ip_adaptive_cap_mult": PER_IP_ADAPTIVE_CAP_MULT,
    "auto_block_score": AUTO_BLOCK_SCORE,
    "event_repeat_interval": EVENT_REPEAT_INTERVAL,
}

# Allowed [lo, hi] ranges for update_config() — keeps a bad value (typo,
# UI bug) from silently disabling detection instead of just failing loud.
_CONFIG_RANGES = {
    "z_elevated": (1.0, 10.0),
    "z_attack": (2.0, 15.0),
    "per_ip_z_threshold": (1.0, 10.0),
    "per_ip_abs_min": (2, 200),
    "per_ip_hard_floor": (5, 500),
    "per_ip_adaptive_cap_mult": (1, 10),
    "auto_block_score": (2, 20),
    "event_repeat_interval": (10, 3600),
}

# Metrics tracked with an adaptive baseline. top_ip_conn_count feeds the
# per-IP adaptive floor above; the other four feed the global attack_state.
_METRICS = ("conn_count", "new_conn_rate", "bytes_in_rate", "bytes_out_rate", "top_ip_conn_count")

_lock = threading.Lock()

_state = {
    "mode": "learning",          # "learning" | "active"
    "samples_seen": 0,
    "attack_state": "normal",    # "normal" | "elevated" | "under_attack"
    "state_reason": "",
    "composite_score": 0.0,
    "auto_mitigation": False,
    "distributed_pattern": False,
    "config": dict(DEFAULT_CONFIG),
    "trusted_ips": [],           # list of normalized IP/CIDR strings
    "baseline": {
        # metric -> {"mean": float, "var": float}
        metric: {"mean": 0.0, "var": 1.0} for metric in _METRICS
    },
    "current": {
        "conn_count": 0,
        "new_conn_rate": 0.0,
        "bytes_in_rate": 0.0,
        "bytes_out_rate": 0.0,
    },
    "z_scores": {},
    "suspects": {},              # ip -> {count, score, first_seen, last_seen, blocked, margin, context_z}
    "history": deque(maxlen=120),  # last N samples of (timestamp, conn_count, composite_score)
}

_last_net = None
_last_net_time = None
_last_conn_count = None

_events = deque(maxlen=200)  # in-memory recent event log, mirrored into the DB

# Save the learned baseline this often (in ticks) and reload it on startup,
# so a restart doesn't force a blind ~10-minute relearn every time.
BASELINE_SAVE_EVERY = 20
_ticks_since_save = 0
_prev_distributed_pattern = False


def _baseline_file_path():
    """Resolve where to persist the learned baseline. Prefers the app's
    configured LOG_DIR (same place app.py already ensures exists) so this
    doesn't need its own config entry; falls back to a local logs/ dir
    next to the app if Config isn't importable for some reason."""
    try:
        from config import Config
        base_dir = getattr(Config, "LOG_DIR", None)
    except Exception:
        base_dir = None
    if not base_dir:
        base_dir = os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "logs"
        )
    return os.path.join(base_dir, "ddos_baseline.json")


def _save_baseline():
    """Best-effort persistence — never let a disk hiccup take down the
    detection loop, same philosophy as _emit_event's DB write below.
    Also persists runtime config and the trusted-IP list so a restart
    doesn't silently revert either to defaults."""
    try:
        path = _baseline_file_path()
        os.makedirs(os.path.dirname(path), exist_ok=True)
        payload = {
            "mode": _state["mode"],
            "samples_seen": _state["samples_seen"],
            "baseline": _state["baseline"],
            "config": _state["config"],
            "trusted_ips": _state["trusted_ips"],
            "saved_at": datetime.utcnow().isoformat(),
        }
        tmp_path = path + ".tmp"
        with open(tmp_path, "w") as f:
            json.dump(payload, f)
        os.replace(tmp_path, path)
    except Exception:
        pass


def _parse_network(ip_or_cidr):
    """Parse a single IP or CIDR range, IPv4 or IPv6. Returns None on
    anything unparseable rather than raising, so callers never need a
    try/except of their own."""
    try:
        if "/" in ip_or_cidr:
            return ipaddress.ip_network(ip_or_cidr, strict=False)
        return ipaddress.ip_network(ip_or_cidr)
    except (ValueError, TypeError):
        return None


def _apply_loaded_config(loaded_cfg):
    """Merge a saved config dict over the defaults during startup load —
    same clamping rules as update_config(), but silent (no event, no
    re-save) since this runs during _load_baseline()."""
    if not isinstance(loaded_cfg, dict):
        return
    for key, (lo, hi) in _CONFIG_RANGES.items():
        if key not in loaded_cfg:
            continue
        try:
            value = type(_state["config"][key])(loaded_cfg[key])
        except (TypeError, ValueError):
            continue
        _state["config"][key] = max(lo, min(hi, value))
    if _state["config"]["z_attack"] < _state["config"]["z_elevated"]:
        _state["config"]["z_attack"] = _state["config"]["z_elevated"]


def _load_baseline():
    """Restore a previously learned baseline, config, and trusted-IP list
    on startup, if a save file exists and still matches the metrics this
    version tracks. Falls back silently to fresh defaults on any
    mismatch or error — never crashes startup over a stale/corrupt file."""
    try:
        path = _baseline_file_path()
        if not os.path.isfile(path):
            return
        with open(path) as f:
            payload = json.load(f)
        loaded_baseline = payload.get("baseline", {})
        if not all(m in loaded_baseline for m in _METRICS):
            return  # older/incompatible file — relearn fresh rather than guess
        for metric in _METRICS:
            b = loaded_baseline[metric]
            _state["baseline"][metric] = {
                "mean": float(b.get("mean", 0.0)),
                "var": float(b.get("var", 1.0)),
            }
        _state["samples_seen"] = int(payload.get("samples_seen", 0))
        if _state["samples_seen"] >= LEARNING_SAMPLES:
            _state["mode"] = "active"

        _apply_loaded_config(payload.get("config", {}))

        loaded_trusted = payload.get("trusted_ips", [])
        if isinstance(loaded_trusted, list):
            valid = []
            for entry in loaded_trusted:
                net = _parse_network(entry)
                if net:
                    valid.append(str(net))
            _state["trusted_ips"] = valid
    except Exception:
        pass


def _emit_event(event_type, severity, message, ip=None):
    entry = {
        "type": event_type,
        "severity": severity,
        "ip": ip,
        "message": message,
        "at": datetime.utcnow().isoformat(),
    }
    _events.appendleft(entry)
    try:
        from database import db
        from models.security_event import SecurityEvent
        db.session.add(SecurityEvent(event_type=event_type, severity=severity, ip=ip, message=message))
        db.session.commit()
    except Exception:
        # Never let event persistence take down the detection loop — the
        # in-memory deque above is still there for the UI either way.
        try:
            from database import db
            db.session.rollback()
        except Exception:
            pass


def recent_events(limit=50):
    return list(_events)[:limit]


def _ewma_update(metric, value):
    b = _state["baseline"][metric]
    delta = value - b["mean"]
    b["mean"] += BASELINE_ALPHA * delta
    b["var"] = (1 - BASELINE_ALPHA) * (b["var"] + BASELINE_ALPHA * delta * delta)


def _z_score(metric, value):
    b = _state["baseline"][metric]
    floor = MIN_STD_FLOOR.get(metric, 1e-6)
    std = max(b["var"] ** 0.5, floor)
    return (value - b["mean"]) / std


def _sample_network():
    """One tick of raw signal: current connection count, the *increase* in
    connection count since the last tick (a rise means new connections are
    landing faster than old ones are closing — the shape a SYN flood or
    connection-exhaustion attack makes), and in/out bandwidth rates."""
    global _last_net, _last_net_time, _last_conn_count
    counters = psutil.net_io_counters()
    now = time.time()
    elapsed = max(now - _last_net_time, 0.001) if _last_net_time else None

    bytes_in_rate = bytes_out_rate = 0.0
    if _last_net is not None and elapsed:
        bytes_in_rate = max((counters.bytes_recv - _last_net.bytes_recv) / elapsed, 0)
        bytes_out_rate = max((counters.bytes_sent - _last_net.bytes_sent) / elapsed, 0)
    _last_net = counters
    _last_net_time = now

    try:
        conn_count = len(psutil.net_connections(kind="inet"))
    except (PermissionError, OSError):
        conn_count = _last_conn_count or 0

    new_conn_rate = 0.0
    if _last_conn_count is not None and elapsed:
        new_conn_rate = max(conn_count - _last_conn_count, 0) / elapsed
    _last_conn_count = conn_count

    return {
        "conn_count": conn_count,
        "new_conn_rate": new_conn_rate,
        "bytes_in_rate": bytes_in_rate,
        "bytes_out_rate": bytes_out_rate,
    }


def _is_trusted(ip):
    """True if `ip` (IPv4 or IPv6) falls inside any trusted IP/CIDR entry.
    Unparseable input (shouldn't happen — it comes from psutil/the OS
    connection table) is treated as not-trusted rather than raising."""
    try:
        addr = ipaddress.ip_address(ip)
    except (ValueError, TypeError):
        return False
    for net_str in _state["trusted_ips"]:
        net = _parse_network(net_str)
        if net and addr in net:
            return True
    return False


def _per_ip_effective_floor():
    """The adaptive per-IP flood threshold: the configured hard floor
    while still learning (we don't trust the adaptive number yet),
    otherwise the learned mean + configured z-threshold std of this
    host's normal top-IP connection count, clamped to
    [per_ip_abs_min, hard_floor * cap_mult]."""
    cfg = _state["config"]
    if _state["mode"] != "active":
        return float(cfg["per_ip_hard_floor"])
    b = _state["baseline"]["top_ip_conn_count"]
    std = max(b["var"] ** 0.5, 1e-6)
    adaptive = b["mean"] + cfg["per_ip_z_threshold"] * std
    ceiling = cfg["per_ip_hard_floor"] * cfg["per_ip_adaptive_cap_mult"]
    return max(min(adaptive, ceiling), cfg["per_ip_abs_min"])


def _score_per_ip(app, top, effective_floor):
    """Flag remote IPs holding an outsized share of established
    connections, relative to the adaptive per-IP floor. Runs every tick;
    independent of the global attack_state. Trusted IPs are excluded
    entirely, both from new flagging and from any existing suspect
    record."""
    global _prev_distributed_pattern
    now = time.time()
    cfg = _state["config"]
    suspects = _state["suspects"]

    # An IP added to the trust list after already being flagged should
    # stop being treated as a suspect immediately, not linger until it
    # decays out on its own.
    for ip in list(suspects.keys()):
        if _is_trusted(ip):
            del suspects[ip]

    seen_this_tick = set()
    for entry in top:
        ip, count = entry["ip"], entry["connections"]
        if _is_trusted(ip):
            continue
        if count < effective_floor:
            continue
        seen_this_tick.add(ip)
        margin = count / max(effective_floor, 1.0)
        rec = suspects.get(ip)
        if rec is None:
            rec = {
                "first_seen": now,
                "score": 0,
                "blocked": False,
                # Snapshot of global z-scores at the moment this IP was
                # first flagged, so a reviewer can see whether it lined
                # up with a broader traffic anomaly or was an isolated
                # single-source spike.
                "context_z": {k: round(v, 2) for k, v in _state["z_scores"].items()},
            }
            suspects[ip] = rec
            _emit_event(
                "ip_flagged", "warning",
                f"{ip} is holding {count} concurrent connections "
                f"({margin:.1f}x this host's adaptive threshold of {effective_floor:.0f})",
                ip=ip,
            )
        rec["count"] = count
        rec["margin"] = round(margin, 2)
        rec["last_seen"] = now

        # Escalate faster the further past the threshold an IP is, instead
        # of every suspect accumulating score at the same fixed rate
        # regardless of how severe the flood actually looks.
        if margin < 1.5:
            increment = 1
        elif margin < 3:
            increment = 2
        elif margin < 6:
            increment = 3
        else:
            increment = 4
        rec["score"] = min(rec["score"] + increment, cfg["auto_block_score"] + 2)

        if rec["score"] >= cfg["auto_block_score"] and not rec["blocked"]:
            if _state["auto_mitigation"]:
                try:
                    if fw.auto_block_ip(ip, BLOCK_COMMENT):
                        rec["blocked"] = True
                        _emit_event("ip_blocked", "critical",
                                    f"Auto-blocked {ip} after sustained flood ({count} connections)", ip=ip)
                    else:
                        _emit_event("info", "info",
                                    f"{ip} is on the SSH whitelist — skipped auto-block", ip=ip)
                except fw.FirewallError as exc:
                    _emit_event("error", "warning", f"Auto-block of {ip} failed: {exc}", ip=ip)
            else:
                # Re-alert periodically instead of once-and-done, so an
                # unresolved flood doesn't quietly drop off the radar —
                # but not every 3s tick either.
                last_alert = rec.get("last_alert_at", 0)
                if now - last_alert >= cfg["event_repeat_interval"]:
                    rec["last_alert_at"] = now
                    _emit_event("suspect_high_score", "warning",
                                f"{ip} still looks like a flood source ({count} connections) — "
                                f"auto-mitigation is off, review and block manually", ip=ip)

    # Decay/forget suspects that have quieted down for a while.
    for ip in list(suspects.keys()):
        if ip not in seen_this_tick:
            rec = suspects[ip]
            rec["score"] = max(rec["score"] - 1, 0)
            if rec["score"] == 0 and now - rec.get("last_seen", now) > 300:
                del suspects[ip]

    # Global traffic looks anomalous but no single IP crosses the floor —
    # worth surfacing distinctly, since it points at a distributed source
    # (botnet-style) rather than one address to just block.
    distributed = _state["attack_state"] in ("elevated", "under_attack") and not seen_this_tick
    _state["distributed_pattern"] = distributed
    if distributed and not _prev_distributed_pattern:
        _emit_event(
            "distributed_pattern", "warning",
            "Traffic looks anomalous but no single IP is dominant — "
            "possible distributed source rather than one flood IP",
        )
    _prev_distributed_pattern = distributed


def _tick(app):
    global _ticks_since_save
    with _lock:
        cfg = _state["config"]
        metrics = _sample_network()
        _state["current"] = metrics

        top = sec.get_top_connections(limit=15)
        top_ip_max = max((entry["connections"] for entry in top), default=0)
        z_metrics = dict(metrics)
        z_metrics["top_ip_conn_count"] = top_ip_max

        z = {metric: _z_score(metric, value) for metric, value in z_metrics.items()}
        _state["z_scores"] = z

        # Connection-shape anomaly is the actual DDoS signature; a
        # bandwidth-only spike (e.g. a legitimate large transfer) is
        # noted but capped at "elevated" rather than a full attack alert.
        conn_z = max(z["conn_count"], z["new_conn_rate"])
        bw_z = max(z["bytes_in_rate"], z["bytes_out_rate"])
        composite = max(0.0, conn_z, bw_z)
        _state["composite_score"] = round(composite, 2)

        _state["samples_seen"] += 1
        if _state["samples_seen"] >= LEARNING_SAMPLES and _state["mode"] == "learning":
            _state["mode"] = "active"
            _emit_event("mode_change", "info",
                        f"Baseline learning complete after {LEARNING_SAMPLES} samples — "
                        f"anomaly detection is now active")

        prev_state = _state["attack_state"]
        if _state["mode"] == "learning":
            new_state, reason = "normal", "still learning this host's baseline"
        elif conn_z >= cfg["z_attack"]:
            new_state, reason = "under_attack", f"connection-shape anomaly (z={conn_z:.1f})"
        elif conn_z >= cfg["z_elevated"]:
            new_state, reason = "elevated", f"connection-shape anomaly (z={conn_z:.1f})"
        elif bw_z >= cfg["z_attack"]:
            new_state, reason = "elevated", f"bandwidth anomaly only, capped (z={bw_z:.1f})"
        elif bw_z >= cfg["z_elevated"]:
            new_state, reason = "elevated", f"bandwidth anomaly (z={bw_z:.1f})"
        else:
            new_state, reason = "normal", "within normal range"
        _state["attack_state"] = new_state
        _state["state_reason"] = reason

        if new_state != prev_state:
            severity = {"normal": "info", "elevated": "warning", "under_attack": "critical"}[new_state]
            _emit_event("state_change", severity,
                        f"Traffic state changed: {prev_state} -> {new_state} ({reason})")

        # Only fold this sample into the baseline when things look normal,
        # so an ongoing attack never gets learned as "business as usual".
        if new_state == "normal":
            for metric, value in z_metrics.items():
                _ewma_update(metric, value)

        _state["history"].append({
            "t": time.time(),
            "conn_count": metrics["conn_count"],
            "score": _state["composite_score"],
            "state": new_state,
        })

        effective_floor = _per_ip_effective_floor()
        _score_per_ip(app, top, effective_floor)

        _ticks_since_save += 1
        if _ticks_since_save >= BASELINE_SAVE_EVERY:
            _ticks_since_save = 0
            _save_baseline()


def get_status():
    with _lock:
        return {
            "mode": _state["mode"],
            "state": _state["attack_state"],
            "state_reason": _state["state_reason"],
            "composite_score": _state["composite_score"],
            "samples_seen": _state["samples_seen"],
            "learning_target": LEARNING_SAMPLES,
            "auto_mitigation": _state["auto_mitigation"],
            "distributed_pattern": _state["distributed_pattern"],
            "per_ip_effective_floor": round(_per_ip_effective_floor(), 1),
            "current": dict(_state["current"]),
            "z_scores": {k: round(v, 2) for k, v in _state["z_scores"].items()},
            "baseline": {
                m: {"mean": round(b["mean"], 2), "std": round(b["var"] ** 0.5, 2)}
                for m, b in _state["baseline"].items()
            },
            "suspects": [
                {"ip": ip, **{k: v for k, v in rec.items()}}
                for ip, rec in sorted(_state["suspects"].items(), key=lambda kv: kv[1]["score"], reverse=True)
            ],
            "history": list(_state["history"]),
            # --- new, additive fields ---
            "config": dict(_state["config"]),
            "trusted_ips": list(_state["trusted_ips"]),
        }


def set_auto_mitigation(enabled):
    with _lock:
        _state["auto_mitigation"] = bool(enabled)
    _emit_event("config_change", "info",
                f"Auto-mitigation {'enabled' if enabled else 'disabled'}")


def reset_baseline():
    with _lock:
        for b in _state["baseline"].values():
            b["mean"] = 0.0
            b["var"] = 1.0
        _state["mode"] = "learning"
        _state["samples_seen"] = 0
        _state["attack_state"] = "normal"
        _state["state_reason"] = ""
        _state["distributed_pattern"] = False
        _state["suspects"] = {}
    _save_baseline()
    _emit_event("config_change", "info", "Baseline reset — relearning traffic patterns")


def unblock_suspect(ip):
    with _lock:
        rec = _state["suspects"].get(ip)
        if rec:
            rec["blocked"] = False
            rec["score"] = 0


# --- New: trusted-IP management ---

def add_trusted_ip(ip_or_cidr):
    """Add an IP or CIDR range (IPv4 or IPv6) to the trust list. Returns
    False if the input doesn't parse as a valid address/network."""
    net = _parse_network(ip_or_cidr)
    if net is None:
        return False
    normalized = str(net)
    with _lock:
        if normalized not in _state["trusted_ips"]:
            _state["trusted_ips"].append(normalized)
    _save_baseline()
    _emit_event("config_change", "info", f"Added {normalized} to DDoS trusted list")
    return True


def remove_trusted_ip(ip_or_cidr):
    """Remove a previously trusted IP/CIDR. Returns False if it wasn't
    in the list (nothing to remove)."""
    net = _parse_network(ip_or_cidr)
    normalized = str(net) if net else ip_or_cidr
    removed = False
    with _lock:
        if normalized in _state["trusted_ips"]:
            _state["trusted_ips"].remove(normalized)
            removed = True
    if removed:
        _save_baseline()
        _emit_event("config_change", "info", f"Removed {normalized} from DDoS trusted list")
    return removed


def list_trusted_ips():
    with _lock:
        return list(_state["trusted_ips"])


# --- New: runtime-configurable thresholds ---

def get_config():
    with _lock:
        return dict(_state["config"])


def update_config(overrides):
    """Update one or more detection thresholds at runtime. Each value is
    validated against _CONFIG_RANGES and clamped rather than rejected
    outright, so a slightly-off value from a settings form still takes
    effect at the nearest sane bound instead of silently doing nothing.
    Unknown keys are ignored. Returns a dict of the keys that actually
    changed (empty dict if nothing changed)."""
    changed = {}
    with _lock:
        for key, value in overrides.items():
            if key not in _CONFIG_RANGES:
                continue
            lo, hi = _CONFIG_RANGES[key]
            try:
                value = type(_state["config"][key])(value)
            except (TypeError, ValueError):
                continue
            value = max(lo, min(hi, value))
            if value != _state["config"][key]:
                _state["config"][key] = value
                changed[key] = value
        # Keep z_attack >= z_elevated so "under_attack" can't become
        # unreachable due to a misconfigured pair.
        if _state["config"]["z_attack"] < _state["config"]["z_elevated"]:
            _state["config"]["z_attack"] = _state["config"]["z_elevated"]
            changed["z_attack"] = _state["config"]["z_attack"]
    if changed:
        _save_baseline()
        _emit_event("config_change", "info", f"DDoS thresholds updated: {changed}")
    return changed


def reset_config():
    """Restore all thresholds to their built-in defaults."""
    with _lock:
        _state["config"] = dict(DEFAULT_CONFIG)
    _save_baseline()
    _emit_event("config_change", "info", "DDoS thresholds reset to defaults")


_loop_started = False
_loop_lock = threading.Lock()


def _background_loop(app, socketio):
    with app.app_context():
        while True:
            try:
                _tick(app)
                socketio.emit("ddos_update", get_status(), namespace="/security")
            except Exception as exc:  # noqa: BLE001 - keep the loop alive no matter what
                app.logger.warning("DDoS detection loop error: %s", exc)
            socketio.sleep(3)


def start_detection_loop(app, socketio):
    global _loop_started
    with _loop_lock:
        if _loop_started:
            return
        _loop_started = True
        with _lock:
            _load_baseline()
        socketio.start_background_task(_background_loop, app, socketio)