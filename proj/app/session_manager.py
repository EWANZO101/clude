import os
import re
import subprocess
import shlex
import tempfile

_ANSI_RE = re.compile(r"\x1b(?:\[[0-9;?]*[a-zA-Z]|\][^\x07]*\x07|[()#][0-9A-Za-z]|[=>c78]|\[[0-9]*[GKJ])")

# Linux users that OS_USER may target, and the exact sudo command allowed for
# each. Kept as an explicit allowlist (rather than trusting the DB value
# blindly) so a bad/unexpected os_user value can never be handed to sudo.
ALLOWED_OS_USERS = {u.strip() for u in os.environ.get("ALLOWED_OS_USERS", "").split(",") if u.strip()}


def _strip_ansi(text):
    text = _ANSI_RE.sub("", text)
    return text.replace("\r\n", "\n").replace("\r", "\n")


def _screen_cmd(os_user, args):
    """Build a `screen` invocation, optionally routed through the narrowly
    scoped `sudo -u <os_user> screen ...` rule set up for that user. Refuses
    to sudo to anything not in ALLOWED_OS_USERS."""
    if os_user:
        if os_user not in ALLOWED_OS_USERS:
            raise ValueError(f"os_user {os_user!r} is not in ALLOWED_OS_USERS")
        return ["sudo", "-n", "-u", os_user, "/usr/bin/screen"] + args
    return ["screen"] + args


def default_home_for(os_user, claude_homes_dir, account_id):
    if os_user:
        return f"/home/{os_user}"
    return os.path.join(claude_homes_dir, f"account_{account_id}")


def _hardcopy(screen_name, os_user):
    """Ask screen to dump its rendered terminal (incl. scrollback) to a temp
    file. Unlike the raw -Logfile stream, this reflects what a terminal would
    actually display — correct spacing, no escape codes — since screen itself
    renders the PTY output before writing it out."""
    if os_user:
        # The hardcopy is written by a `screen` process running AS os_user
        # (via sudo). If we pre-create the file as our own (claude-manager)
        # user first, screen silently fails to write into it even when it's
        # chmod 666 — screen only writes hardcopy files it creates/owns
        # itself. So instead we hand it a fixed, reused path under /tmp and
        # let screen create it fresh each time (comes out world-readable,
        # mode 664, by that user's default umask). /tmp's sticky bit means
        # claude-manager can never delete a file claude-user2 owns, so this
        # is deliberately a stable path that gets overwritten in place
        # rather than a fresh temp file per call — no per-poll litter.
        path = f"/tmp/claude-manager-hardcopy-{screen_name}"
        try:
            subprocess.run(
                _screen_cmd(os_user, ["-S", screen_name, "-X", "hardcopy", "-h", path]),
                check=True, timeout=5,
            )
            with open(path, "r", errors="replace") as f:
                return f.read()
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError, ValueError):
            return None

    fd, path = tempfile.mkstemp(prefix="claude_manager_hardcopy_")
    os.close(fd)
    try:
        subprocess.run(
            _screen_cmd(os_user, ["-S", screen_name, "-X", "hardcopy", "-h", path]),
            check=True, timeout=5,
        )
        with open(path, "r", errors="replace") as f:
            return f.read()
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError, ValueError):
        return None
    finally:
        try:
            os.remove(path)
        except OSError:
            pass


def is_running(screen_name, os_user=None):
    try:
        result = subprocess.run(
            _screen_cmd(os_user, ["-list"]), capture_output=True, text=True
        )
    except (ValueError, OSError):
        return False
    return f".{screen_name}\t" in result.stdout or f".{screen_name}(" in result.stdout


def start_session(account, log_dir, claude_homes_dir):
    if is_running(account.screen_name(), account.os_user):
        return False, "Session already running"

    if account.os_user and account.os_user not in ALLOWED_OS_USERS:
        return False, f"os_user '{account.os_user}' is not allowed"

    os.makedirs(log_dir, exist_ok=True)
    home = default_home_for(account.os_user, claude_homes_dir, account.id)
    config_dir = account.config_dir or os.path.join(home, ".claude")
    project_path = account.project_path or home

    if not account.os_user:
        # only create dirs ourselves when running as our own service user —
        # for an os_user session, that user's home/config already exists
        # (or is created via the OS user's own first login), avoiding the
        # need to chase down cross-user file ownership here.
        os.makedirs(config_dir, exist_ok=True)

    log_file = account.log_path(log_dir)

    env_prefix = f"CLAUDE_CONFIG_DIR={shlex.quote(config_dir)}"
    if account.api_key:
        env_prefix += f" ANTHROPIC_API_KEY={shlex.quote(account.api_key)}"

    model_flag = f" --model {shlex.quote(account.model)}" if account.model else ""

    inner_cmd = (
        f"cd {shlex.quote(project_path)} && "
        f"{env_prefix} claude{model_flag}"
    )

    args = [
        "-L", "-Logfile", log_file,
        "-h", "2000",
        "-dmS", account.screen_name(),
        "bash", "-lc", inner_cmd,
    ]
    try:
        subprocess.run(_screen_cmd(account.os_user, args), check=True)
    except (subprocess.CalledProcessError, OSError) as e:
        return False, f"Failed to start: {e}"
    return True, "Session started"


def stop_session(account):
    if not is_running(account.screen_name(), account.os_user):
        return False, "Session not running"
    subprocess.run(
        _screen_cmd(account.os_user, ["-S", account.screen_name(), "-X", "quit"]),
        check=False,
    )
    return True, "Session stopped"


def send_keys(account, text):
    """Inject literal keystrokes into the running session's stdin — used to
    drive interactive prompts (e.g. pasting an OAuth code back to `claude
    login`) from the web console."""
    if not is_running(account.screen_name(), account.os_user):
        return False, "Session not running"
    try:
        subprocess.run(
            _screen_cmd(account.os_user, ["-S", account.screen_name(), "-X", "stuff", text]),
            check=True, timeout=5,
        )
        return True, "Sent"
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, ValueError) as e:
        return False, str(e)


def tail_log(account, log_dir, lines=200):
    if is_running(account.screen_name(), account.os_user):
        snapshot = _hardcopy(account.screen_name(), account.os_user)
        if snapshot is not None:
            return snapshot.rstrip("\n")

    log_file = account.log_path(log_dir)
    if not os.path.exists(log_file):
        return ""
    result = subprocess.run(
        ["tail", "-n", str(lines), log_file], capture_output=True, text=True,
        errors="replace",
    )
    return _strip_ansi(result.stdout)
