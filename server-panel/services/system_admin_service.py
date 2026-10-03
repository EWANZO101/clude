"""OS-level system administration: apt update/upgrade, root password reset,
and Linux (system) user management — distinct from models/user.py, which is
this panel's own login accounts. These operate on real OS users via
useradd/usermod/userdel/chpasswd/passwd, and are irreversible in ways the
panel's own user management isn't, so every function here validates
aggressively and raises SystemAdminError with a plain-English message
rather than letting a subprocess failure surface as a raw traceback.
"""
import grp
import os
import pwd
import re
import subprocess

USERNAME_RE = re.compile(r"^[a-z_][a-z0-9_-]{0,31}$")
PROTECTED_USERNAMES = {"root", "daemon", "bin", "sys", "sync", "games", "man", "lp", "mail",
                        "news", "uucp", "proxy", "www-data", "backup", "list", "irc", "gnats",
                        "nobody", "systemd-network", "systemd-resolve", "messagebus", "sshd",
                        "syslog", "_apt", "systemd-timesync", "landscape"}

VALID_SHELLS = ["/bin/bash", "/bin/sh", "/usr/sbin/nologin", "/bin/false"]


class SystemAdminError(Exception):
    pass


def _run(args, input_text=None, timeout=30):
    try:
        return subprocess.run(args, input=input_text, capture_output=True, text=True, timeout=timeout)
    except FileNotFoundError as exc:
        raise SystemAdminError(f"'{args[0]}' isn't available on this host.") from exc
    except subprocess.TimeoutExpired as exc:
        raise SystemAdminError(f"'{' '.join(args)}' timed out.") from exc


# ---------------------------------------------------------------------------
# apt update / upgrade — run as background Jobs (see tasks/background.py)
# since upgrades can take minutes; ctx is a JobContext for live log/progress.
# ---------------------------------------------------------------------------

def apt_update(ctx):
    ctx.set_progress(5, "Running apt-get update…")
    env = dict(os.environ, DEBIAN_FRONTEND="noninteractive")
    proc = subprocess.Popen(
        ["apt-get", "update"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, env=env,
    )
    for line in iter(proc.stdout.readline, ""):
        if line:
            ctx.log(line.rstrip())
    proc.wait()
    if proc.returncode != 0:
        raise SystemAdminError(f"apt-get update exited with code {proc.returncode}.")
    ctx.set_progress(100, "Package index updated.")


def apt_upgrade(ctx):
    ctx.set_progress(5, "Running apt-get update…")
    env = dict(os.environ, DEBIAN_FRONTEND="noninteractive")
    update_proc = subprocess.Popen(
        ["apt-get", "update"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env,
    )
    for line in iter(update_proc.stdout.readline, ""):
        if line:
            ctx.log(line.rstrip())
    update_proc.wait()
    if update_proc.returncode != 0:
        raise SystemAdminError(f"apt-get update exited with code {update_proc.returncode}.")

    ctx.set_progress(30, "Upgrading packages…")
    upgrade_proc = subprocess.Popen(
        ["apt-get", "upgrade", "-y", "--with-new-pkgs"],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env,
    )
    for line in iter(upgrade_proc.stdout.readline, ""):
        if line:
            ctx.log(line.rstrip())
    upgrade_proc.wait()
    if upgrade_proc.returncode != 0:
        raise SystemAdminError(f"apt-get upgrade exited with code {upgrade_proc.returncode}.")
    ctx.set_progress(100, "Packages upgraded.")


def count_upgradable():
    """Quick, read-only check of how many packages have updates pending
    (doesn't run apt-get update first, so this reflects the last time the
    index was refreshed — good enough for a dashboard badge)."""
    result = _run(["apt-get", "-s", "upgrade"], timeout=15)
    if result.returncode != 0:
        return None
    return len(re.findall(r"^Inst ", result.stdout, re.MULTILINE))


# ---------------------------------------------------------------------------
# Root password reset
# ---------------------------------------------------------------------------

def reset_root_password(new_password):
    if len(new_password) < 8:
        raise SystemAdminError("Password must be at least 8 characters.")
    result = _run(["chpasswd"], input_text=f"root:{new_password}\n")
    if result.returncode != 0:
        raise SystemAdminError(result.stderr.strip() or "Failed to set the root password.")
    return True


# ---------------------------------------------------------------------------
# Linux (OS) user management
# ---------------------------------------------------------------------------

def _sudo_members():
    try:
        return set(grp.getgrnam("sudo").gr_mem)
    except KeyError:
        try:
            return set(grp.getgrnam("wheel").gr_mem)
        except KeyError:
            return set()


def _account_status(username):
    """P (usable password), L (locked), NP (no password) via `passwd -S`."""
    result = _run(["passwd", "-S", username], timeout=10)
    if result.returncode != 0:
        return "unknown"
    parts = result.stdout.split()
    if len(parts) >= 2:
        code = parts[1]
        return {"P": "active", "L": "locked", "NP": "no-password"}.get(code, "unknown")
    return "unknown"


def list_system_users():
    """Human login accounts: uid 0 (root) and uid >= 1000, excluding
    'nobody' (65534) and other unassigned placeholder accounts."""
    sudoers = _sudo_members()
    users = []
    for entry in pwd.getpwall():
        if entry.pw_uid != 0 and not (1000 <= entry.pw_uid < 60000):
            continue
        if entry.pw_name == "nobody":
            continue
        users.append({
            "username": entry.pw_name,
            "uid": entry.pw_uid,
            "home": entry.pw_dir,
            "shell": entry.pw_shell,
            "is_sudo": entry.pw_name in sudoers or entry.pw_uid == 0,
            "is_root": entry.pw_uid == 0,
            "status": _account_status(entry.pw_name),
            "protected": entry.pw_name in PROTECTED_USERNAMES,
        })
    users.sort(key=lambda u: (not u["is_root"], u["uid"]))
    return users


def validate_username(username):
    if not username or not USERNAME_RE.match(username):
        raise SystemAdminError(
            "Username must be lowercase, start with a letter or underscore, and contain only "
            "letters, numbers, hyphens, or underscores (max 32 characters)."
        )
    try:
        pwd.getpwnam(username)
        raise SystemAdminError(f"A user named '{username}' already exists.")
    except KeyError:
        pass
    return True


def create_system_user(username, password, shell="/bin/bash", sudo=False, ssh_public_key=None):
    validate_username(username)
    if len(password) < 8:
        raise SystemAdminError("Password must be at least 8 characters.")
    if shell not in VALID_SHELLS:
        raise SystemAdminError("Unrecognized shell.")

    result = _run(["useradd", "-m", "-s", shell, username])
    if result.returncode != 0:
        raise SystemAdminError(result.stderr.strip() or f"Failed to create user '{username}'.")

    pw_result = _run(["chpasswd"], input_text=f"{username}:{password}\n")
    if pw_result.returncode != 0:
        # Roll back the half-created account rather than leaving a
        # passwordless (effectively locked, but confusing) user behind.
        _run(["userdel", "-r", username])
        raise SystemAdminError(pw_result.stderr.strip() or "Failed to set the new user's password.")

    if sudo:
        sudo_result = _run(["usermod", "-aG", "sudo", username])
        if sudo_result.returncode != 0:
            raise SystemAdminError(
                f"User '{username}' was created, but adding it to the sudo group failed: "
                f"{sudo_result.stderr.strip()}"
            )

    if ssh_public_key and ssh_public_key.strip():
        try:
            entry = pwd.getpwnam(username)
            ssh_dir = os.path.join(entry.pw_dir, ".ssh")
            os.makedirs(ssh_dir, mode=0o700, exist_ok=True)
            auth_keys = os.path.join(ssh_dir, "authorized_keys")
            with open(auth_keys, "a", encoding="utf-8") as f:
                f.write(ssh_public_key.strip() + "\n")
            os.chmod(auth_keys, 0o600)
            _run(["chown", "-R", f"{username}:{username}", ssh_dir])
        except OSError as exc:
            raise SystemAdminError(
                f"User '{username}' was created, but installing the SSH key failed: {exc}"
            ) from exc

    return True


def delete_system_user(username, remove_home=True):
    if username in PROTECTED_USERNAMES:
        raise SystemAdminError(f"Refusing to delete '{username}' — it's a core system account.")
    try:
        pwd.getpwnam(username)
    except KeyError as exc:
        raise SystemAdminError(f"No such user '{username}'.") from exc

    args = ["userdel"]
    if remove_home:
        args.append("-r")
    args.append(username)
    result = _run(args)
    if result.returncode != 0:
        raise SystemAdminError(result.stderr.strip() or f"Failed to delete user '{username}'.")
    return True


def set_sudo(username, enabled):
    if username in PROTECTED_USERNAMES:
        raise SystemAdminError(f"'{username}' is a core system account.")
    if enabled:
        result = _run(["usermod", "-aG", "sudo", username])
    else:
        result = _run(["deluser", username, "sudo"])
    if result.returncode != 0:
        raise SystemAdminError(result.stderr.strip() or "Failed to update sudo membership.")
    return True


def reset_user_password(username, new_password):
    if len(new_password) < 8:
        raise SystemAdminError("Password must be at least 8 characters.")
    try:
        pwd.getpwnam(username)
    except KeyError as exc:
        raise SystemAdminError(f"No such user '{username}'.") from exc
    result = _run(["chpasswd"], input_text=f"{username}:{new_password}\n")
    if result.returncode != 0:
        raise SystemAdminError(result.stderr.strip() or "Failed to set the password.")
    return True
