import re
import subprocess

from utils.ttl_cache import ttl_cache

PORT_RE = re.compile(r"^\d{1,5}$")
IP_RE = re.compile(r"^(\d{1,3}\.){3}\d{1,3}(/\d{1,2})?$")

# Every rule this service creates to guarantee SSH access carries this comment
# tag. It's how "protected" rules get recognised later (delete/close/disable
# guards all key off this string, not off a separate list that could drift
# out of sync with what ufw actually has loaded).
PROTECTED_TAG = "panel-ssh-lock"
SSH_PORT = "22"


class FirewallError(Exception):
    pass


def _run(args, timeout=20):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=timeout, check=False)
    except FileNotFoundError as exc:
        raise FirewallError("ufw isn't installed on this host.") from exc
    except subprocess.TimeoutExpired as exc:
        raise FirewallError(f"Command timed out: {' '.join(args)}") from exc


def _validate_port(port):
    port = str(port).strip()
    if not PORT_RE.match(port) or not (1 <= int(port) <= 65535):
        raise FirewallError(f"'{port}' isn't a valid port number.")
    return port


def _validate_ip(ip):
    ip = ip.strip()
    if not IP_RE.match(ip):
        raise FirewallError(f"'{ip}' isn't a valid IPv4 address or CIDR range.")
    return ip


@ttl_cache(seconds=60)
def is_installed():
    try:
        result = _run(["ufw", "version"])
    except FirewallError:
        return False
    return result.returncode == 0


def get_status():
    result = _run(["ufw", "status", "verbose"])
    if result.returncode != 0:
        raise FirewallError(result.stderr.strip() or "Failed to read ufw status.")

    output = result.stdout
    active = "Status: active" in output

    rules = []
    for line in output.splitlines():
        line = line.strip()
        if not line or line.startswith("Status:") or line.startswith("Logging:") \
                or line.startswith("Default:") or line.startswith("New profiles:") \
                or line.startswith("To") or line.startswith("--"):
            continue
        parts = line.split(None, 2)
        if len(parts) >= 3:
            rules.append({"to": parts[0], "action": parts[1], "from": parts[2]})

    return {"active": active, "raw": output, "rules": rules}


def _parse_added_line(line):
    """Parse one line of `ufw show added` output (the raw commands ufw would
    replay on enable) into structured fields. Used as a fallback source of
    truth when ufw is inactive, since `ufw status numbered` prints nothing
    but 'Status: inactive' in that state even though rules are on disk."""
    line = line.strip()
    if not line.startswith("ufw "):
        return None
    tokens = line.split()[1:]  # drop leading 'ufw'
    if tokens and tokens[0] == "insert" and len(tokens) > 1:
        tokens = tokens[2:]  # drop 'insert N'
    if not tokens or tokens[0] not in ("allow", "deny"):
        return None

    kind = tokens[0]
    rest = tokens[1:]
    ip = None
    port = None
    proto = None
    comment = None

    i = 0
    while i < len(rest):
        tok = rest[i]
        if tok == "from" and i + 1 < len(rest):
            ip = rest[i + 1]
            i += 2
        elif tok == "to" and i + 1 < len(rest) and rest[i + 1] == "any":
            i += 2
        elif tok == "port" and i + 1 < len(rest):
            port = rest[i + 1]
            i += 2
        elif tok == "proto" and i + 1 < len(rest):
            proto = rest[i + 1]
            i += 2
        elif tok == "comment":
            comment = " ".join(rest[i + 1:]).strip("'\"")
            break
        elif "/" in tok and tok.split("/", 1)[0].isdigit():
            port, proto = tok.split("/", 1)
            i += 1
        else:
            i += 1

    return {"kind": kind, "ip": ip, "port": port, "proto": proto, "comment": comment or ""}


def _get_added_rules():
    """Fallback rule source for when ufw is inactive. No rule numbers exist
    in this mode (nothing to delete-by-number against), so callers that need
    real numbers should treat this as read-only/advisory."""
    result = _run(["ufw", "show", "added"])
    if result.returncode != 0:
        return []

    rules = []
    n = 0
    for line in result.stdout.splitlines():
        parsed = _parse_added_line(line)
        if parsed is None:
            continue
        n += 1
        rules.append({
            "number": n,
            "text": line.strip()[len("ufw "):],
            "protected": PROTECTED_TAG in parsed["comment"],
            "kind": parsed["kind"],
            "ip": parsed["ip"],
        })
    return rules


def get_numbered_rules():
    """Rules with index numbers, needed for delete-by-number in the UI.
    ufw appends '# <comment>' to the line when a rule was created with one,
    so this is also how protected rules get recognised later.

    Falls back to `ufw show added` when ufw is inactive: `ufw status
    numbered` only reflects the *running* firewall state, so right after a
    fresh install (before "Enable" has ever been clicked) it reports zero
    rules even though rules were successfully written to disk. Without this
    fallback, a just-added SSH whitelist entry is invisible to the page that
    reads it back, which also means "Enable firewall" can never unlock since
    that requires a visible whitelist entry.

    Every rule carries structured `kind` ('allow'/'deny') and `ip` fields so
    callers can match on those directly instead of substring-matching
    `text` — the active-mode text ("ALLOW IN <ip>") and the added-mode text
    ("allow from <ip> ...") don't share a common substring like "from <ip>",
    so text-matching silently broke depending on which mode was in play.
    """
    result = _run(["ufw", "status", "numbered"])
    if result.returncode != 0:
        raise FirewallError(result.stderr.strip() or "Failed to read numbered rules.")

    if "Status: active" not in result.stdout:
        return _get_added_rules()

    rules = []
    for line in result.stdout.splitlines():
        m = re.match(r"^\[\s*(\d+)\]\s+(.*)$", line.strip())
        if not m:
            continue
        text = m.group(2).strip()
        without_comment = text.split("#")[0].strip()
        tokens = without_comment.split()
        kind = "deny" if "DENY" in tokens else ("allow" if "ALLOW" in tokens else None)
        ip = tokens[-1] if tokens else None
        if ip == "Anywhere":
            ip = None
        rules.append({
            "number": int(m.group(1)),
            "text": text,
            "protected": PROTECTED_TAG in text,
            "kind": kind,
            "ip": ip,
        })
    return rules


# ---------------------------------------------------------------------------
# SSH whitelist — the part that can't be turned off from the panel
# ---------------------------------------------------------------------------

def _has_protected_rule_matching(kind=None, ip=None):
    """True if a protected rule exists matching the given structured
    fields. Matching on `kind`/`ip` directly (rather than substring-matching
    the raw rule text) avoids a latent bug where a needle like "from <ip>"
    only ever matched the inactive-mode text format (`ufw show added`
    echoes the literal command, including the word "from") and silently
    never matched the active-mode text format (`ufw status numbered` just
    lists the bare IP, with no "from")."""
    for rule in get_numbered_rules():
        if not rule["protected"]:
            continue
        if kind is not None and rule.get("kind") != kind:
            continue
        if ip is not None and rule.get("ip") != ip:
            continue
        return True
    return False


def _has_protected_rule_for(ip):
    return _has_protected_rule_matching(kind="allow", ip=ip)


def _ensure_ssh_deny_catchall():
    """Adds a protected 'deny 22/tcp' rule if it doesn't already exist. Must
    only be called after at least one whitelist allow rule is in place and
    must be *appended*, never inserted at the top — ufw/iptables apply rules
    in order, so the specific allow-from rules (inserted at position 1) have
    to sit above this for the whitelist to actually work rather than being
    shadowed by the deny."""
    if _has_protected_rule_matching(kind="deny"):
        return
    _run(["ufw", "deny", f"{SSH_PORT}/tcp", "comment", PROTECTED_TAG])


def list_ssh_whitelist():
    """Currently-active protected SSH *allow* rules, parsed back out of ufw
    (not a separate stored list) so this can never drift from reality. The
    catch-all deny rule is protected too but isn't an "entry" here."""
    entries = []
    for rule in get_numbered_rules():
        if not rule["protected"] or rule.get("kind") != "allow":
            continue
        entries.append({"number": rule["number"], "text": rule["text"], "ip": rule.get("ip") or ""})
    return entries


def sync_ssh_whitelist(ips):
    """Idempotently ensure every ip in `ips` has a protected allow-22 rule,
    then lock everyone else out with a protected deny-22 catch-all. There is
    deliberately no "open to everyone" fallback: with zero ips configured,
    this is a no-op and does NOT add the deny rule either, since a deny with
    no matching allow would just lock out all SSH access including yours.
    Add at least one IP first (add_ssh_whitelist_ip does this atomically:
    allow-rule then catch-all, in that order, every time)."""
    if not is_installed():
        return
    if not ips:
        return

    for ip in ips:
        ip = _validate_ip(ip)
        if _has_protected_rule_for(ip):
            continue
        _run([
            "ufw", "insert", "1", "allow", "from", ip, "to", "any",
            "port", SSH_PORT, "proto", "tcp", "comment", PROTECTED_TAG,
        ])

    _ensure_ssh_deny_catchall()


def add_ssh_whitelist_ip(ip):
    ip = _validate_ip(ip)
    if _has_protected_rule_for(ip):
        raise FirewallError(f"{ip} is already whitelisted for SSH.")
    result = _run([
        "ufw", "insert", "1", "allow", "from", ip, "to", "any",
        "port", SSH_PORT, "proto", "tcp", "comment", PROTECTED_TAG,
    ])
    if result.returncode != 0:
        raise FirewallError(result.stderr.strip() or f"Failed to whitelist {ip} for SSH.")
    # The allow rule is now above (position 1); safe to add the deny-all
    # catch-all immediately — every other IP gets locked out of SSH from
    # this point on, no separate "enable" step required.
    _ensure_ssh_deny_catchall()
    return True


def remove_ssh_whitelist_ip(ip):
    """Blocked if this would leave zero protected SSH rules — that's the
    'no way to turn off the ufw allow system' guarantee. Going down to one
    remaining whitelist entry is fine; removing the last one is not."""
    ip = _validate_ip(ip)
    current = list_ssh_whitelist()
    if len(current) <= 1:
        raise FirewallError(
            "Can't remove the last SSH whitelist rule — this would risk locking "
            "everyone out. Add another IP first, then remove this one."
        )
    result = _run(["ufw", "delete", "allow", "from", ip, "to", "any", "port", SSH_PORT, "proto", "tcp"])
    if result.returncode != 0:
        raise FirewallError(result.stderr.strip() or f"Failed to remove SSH whitelist entry for {ip}.")
    return True


# ---------------------------------------------------------------------------
# Standard ufw actions, with guards layered on top
# ---------------------------------------------------------------------------

def _current_whitelist_ips():
    try:
        from flask import current_app
        return list(current_app.config.get("SSH_WHITELIST_IPS", []))
    except RuntimeError:
        return []


def enable():
    whitelist_ips = _current_whitelist_ips()
    if not whitelist_ips:
        raise FirewallError(
            "Add at least one SSH whitelist IP before enabling the firewall. "
            "There's no 'allow SSH from anywhere' fallback by design — without "
            "a whitelisted IP, enabling ufw would have nothing to let you back in."
        )
    # Re-assert SSH access immediately before flipping ufw on, every time,
    # so "enable" can never be the thing that locks someone out.
    sync_ssh_whitelist(whitelist_ips)
    result = _run(["ufw", "--force", "enable"])
    if result.returncode != 0:
        raise FirewallError(result.stderr.strip() or "Failed to enable ufw.")
    return True


def disable():
    raise FirewallError(
        "Disabling ufw from the panel is disabled by design — it's how this "
        "guarantees SSH access never gets accidentally cut off. If you truly "
        "need it off, run `ufw disable` directly on the host over SSH."
    )


def open_port(port, protocol="tcp", description=""):
    port = _validate_port(port)
    if protocol not in ("tcp", "udp"):
        raise FirewallError("Protocol must be tcp or udp.")
    args = ["ufw", "allow", f"{port}/{protocol}"]
    if description:
        args += ["comment", description]
    result = _run(args)
    if result.returncode != 0:
        raise FirewallError(result.stderr.strip() or f"Failed to open port {port}/{protocol}.")
    return True


def close_port(port, protocol="tcp"):
    port = _validate_port(port)
    if port == SSH_PORT:
        raise FirewallError(
            "Port 22 can't be closed from the panel — that's the SSH lockout guard. "
            "Manage individual SSH source IPs via the whitelist instead."
        )
    if protocol not in ("tcp", "udp"):
        raise FirewallError("Protocol must be tcp or udp.")
    result = _run(["ufw", "delete", "allow", f"{port}/{protocol}"])
    if result.returncode != 0:
        raise FirewallError(result.stderr.strip() or f"Failed to close port {port}/{protocol}.")
    return True


def allow_ip(ip):
    ip = _validate_ip(ip)
    result = _run(["ufw", "allow", "from", ip])
    if result.returncode != 0:
        raise FirewallError(result.stderr.strip() or f"Failed to allow {ip}.")
    return True


def block_ip(ip):
    ip = _validate_ip(ip)
    if _has_protected_rule_for(ip):
        raise FirewallError(
            f"{ip} is on the SSH whitelist — blocking it here would fight the "
            f"protected rule. Remove it from the SSH whitelist first if that's the goal."
        )
    result = _run(["ufw", "deny", "from", ip])
    if result.returncode != 0:
        raise FirewallError(result.stderr.strip() or f"Failed to block {ip}.")
    return True


def auto_block_ip(ip, comment):
    """Like block_ip(), but tags the rule with `comment` so its origin
    (e.g. the DDoS auto-mitigation system) is visible later in the rule
    list, and returns False instead of raising when the target is on the
    SSH whitelist — callers doing automated blocking want a decision they
    can act on, not an exception to catch on every tick."""
    ip = _validate_ip(ip)
    if _has_protected_rule_for(ip):
        return False
    result = _run(["ufw", "deny", "from", ip, "comment", comment])
    return result.returncode == 0


def categorize_rules(numbered_rules):
    """Splits get_numbered_rules() output into the buckets the Firewall
    page renders as separate tables:
      - port_rules: plain port/protocol allows (no source IP attached)
      - ip_rules: allow/deny rules scoped to a specific source IP, minus
        the protected SSH whitelist (that has its own dedicated section)
      - ssh_catchall_active: whether the protected 'deny 22/tcp' rule that
        locks out everyone not on the SSH whitelist currently exists
      - other_rules: anything protected but not the SSH catch-all, kept
        so a rule never silently disappears from view just because it
        doesn't fit one of the two main buckets above
    """
    port_rules = []
    ip_rules = []
    other_rules = []
    ssh_catchall_active = False

    for rule in numbered_rules:
        if rule["protected"]:
            if rule.get("kind") == "deny" and not rule.get("ip"):
                ssh_catchall_active = True
            elif rule.get("kind") == "allow" and rule.get("ip"):
                pass  # SSH whitelist entry — rendered separately via list_ssh_whitelist()
            else:
                other_rules.append(rule)
            continue

        if rule.get("ip"):
            ip_rules.append(rule)
        else:
            port_rules.append(rule)

    return {
        "port_rules": port_rules,
        "ip_rules": ip_rules,
        "other_rules": other_rules,
        "ssh_catchall_active": ssh_catchall_active,
    }


def switch_ip_rule(number, ip, target):
    """Flip an existing IP rule between allow/deny. ufw has no in-place
    'change' operation, so this deletes the old numbered rule and adds a
    fresh one — both steps guarded by the same validation/protection
    checks as the individual operations."""
    if target not in ("allow", "deny"):
        raise FirewallError("Target status must be 'allow' or 'deny'.")
    delete_rule_by_number(number)
    if target == "allow":
        allow_ip(ip)
    else:
        block_ip(ip)
    return True


def remove_ip_rule(ip, action="allow"):
    ip = _validate_ip(ip)
    if action not in ("allow", "deny"):
        raise FirewallError("Action must be allow or deny.")
    if action == "allow" and _has_protected_rule_for(ip):
        raise FirewallError(f"{ip}'s SSH allow rule is protected — use the SSH whitelist remove action instead.")
    result = _run(["ufw", "delete", action, "from", ip])
    if result.returncode != 0:
        raise FirewallError(result.stderr.strip() or f"Failed to remove rule for {ip}.")
    return True


def delete_rule_by_number(number):
    number = int(number)
    for rule in get_numbered_rules():
        if rule["number"] == number and rule["protected"]:
            raise FirewallError(
                f"Rule #{number} protects SSH access and can't be deleted from the panel."
            )
    result = _run(["ufw", "--force", "delete", str(number)])
    if result.returncode != 0:
        raise FirewallError(result.stderr.strip() or f"Failed to delete rule #{number}.")
    return True
