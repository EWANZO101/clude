"""
Real functional health checks (spec Sections 28-32) for the Kiosk
Application. Used both for the ordinary post-install check and, on failure,
for re-checking the restored version after an automatic rollback (spec
Section 29).

Part 3 could only confirm "the process is still running" — a hung process,
one listening on the wrong port, or one crash-looping *past* that exact
check all sailed through as "healthy". This module actually asks the
application whether it's working, in whichever way it's configured to be
asked:

  - kiosk_health_check_url set   -> GET it; 2xx/3xx = healthy
  - kiosk_health_check_command set (and no URL) -> run it; exit 0 = healthy
  - neither set -> falls back to "is the supervised process running", which
    is honestly weaker than a functional check, and says so in the result

This is deliberately configurable rather than hardcoded to one mechanism,
because the actual Kiosk Application is still a separate, unbuilt project
(see the Admin Panel's and this Agent's progress notes) — configuring a URL
or command lets this be exercised for real today against a stand-in
process, and works unmodified once a real Kiosk Application exists to point
it at.

Retries within a short budget rather than a single shot, because a
freshly-(re)started process legitimately needs a moment to come up — one
premature check right after restart() would mistake normal startup latency
for a genuine failure.
"""
import logging
import shlex
import subprocess
import time

import requests

log = logging.getLogger("agent.health_check")


class HealthCheckResult:
    def __init__(self, passed: bool, message: str, method: str, attempts: int = 1):
        self.passed = passed
        self.message = message
        self.method = method
        self.attempts = attempts

    def __repr__(self):
        return (f"HealthCheckResult(passed={self.passed}, method={self.method!r}, "
                f"attempts={self.attempts}, message={self.message!r})")


def check_structural(app_install_dir: str) -> (bool, str):
    """The one check that's never worth retrying: if the install directory
    is missing or empty, no amount of waiting fixes that — it's a hard
    failure to report (or roll back from) immediately."""
    import os
    if not os.path.isdir(app_install_dir):
        return False, f"app_install_dir does not exist: {app_install_dir}"
    if not os.listdir(app_install_dir):
        return False, f"app_install_dir is empty: {app_install_dir}"
    return True, "application files are present on disk"


def check_process_alive(supervisor) -> (bool, str):
    if supervisor is None:
        return True, "no process supervisor configured — process liveness not checked"
    if supervisor.is_running():
        return True, "supervised process is running"
    return False, "supervised process is not running"


def _check_http_once(url: str, timeout: float) -> (bool, str):
    try:
        resp = requests.get(url, timeout=timeout)
        healthy = 200 <= resp.status_code < 400
        return healthy, f"GET {url} -> HTTP {resp.status_code}"
    except requests.RequestException as e:
        return False, f"GET {url} failed: {e}"


def _check_command_once(command, timeout: float, working_dir: str = None) -> (bool, str):
    argv = shlex.split(command) if isinstance(command, str) else list(command)
    try:
        proc = subprocess.run(
            argv, cwd=working_dir, timeout=timeout,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        if proc.returncode == 0:
            return True, f"command exited 0: {command}"
        return False, f"command exited {proc.returncode}: {command}"
    except subprocess.TimeoutExpired:
        return False, f"command timed out after {timeout}s: {command}"
    except OSError as e:
        return False, f"command could not be run: {e}"


def run_functional_check(settings, supervisor=None, retries: int = 5,
                          retry_delay_seconds: float = 2.0) -> HealthCheckResult:
    """Runs the configured functional check, retrying within a budget.
    Does NOT check app_install_dir for files — call check_structural() first
    and skip this entirely if that fails, since retrying a functional check
    against a directory that was never populated is pointless."""
    url = (getattr(settings, "kiosk_health_check_url", "") or "").strip()
    command = (getattr(settings, "kiosk_health_check_command", "") or "").strip()
    timeout = getattr(settings, "health_check_timeout_seconds", 5.0) or 5.0
    working_dir = getattr(settings, "kiosk_working_dir", None) or None

    if not url and not command:
        passed, msg = check_process_alive(supervisor)
        return HealthCheckResult(
            passed,
            f"{msg} (no kiosk_health_check_url/kiosk_health_check_command configured "
            "— process liveness is the only signal available, this is not a "
            "functional check)",
            method="process-only",
        )

    method = "http" if url else "command"
    last_message = "not attempted"
    for attempt in range(1, max(1, retries) + 1):
        if url:
            passed, last_message = _check_http_once(url, timeout)
        else:
            passed, last_message = _check_command_once(command, timeout, working_dir)

        # A functional check that reports "healthy" is only trustworthy if
        # it's actually checking the process we think it is. If we have a
        # supervisor and it says the process died, trust that over a stale
        # or coincidentally-successful HTTP/command response.
        if passed and supervisor is not None and not supervisor.is_running():
            passed = False
            last_message = f"{last_message}, but the supervised process is not running"

        if passed:
            log.info("Health check passed on attempt %d/%d (%s): %s",
                      attempt, retries, method, last_message)
            return HealthCheckResult(True, last_message, method=method, attempts=attempt)

        log.warning("Health check attempt %d/%d failed (%s): %s",
                    attempt, retries, method, last_message)
        if attempt < retries:
            time.sleep(retry_delay_seconds)

    return HealthCheckResult(False, last_message, method=method, attempts=retries)


def run_health_check(app_install_dir: str, settings, supervisor=None,
                      retries: int = 5, retry_delay_seconds: float = 2.0) -> HealthCheckResult:
    """The full check used by update_manager: structural first (no retry —
    a hard failure), then the functional check (with retries) if structural
    passes."""
    structural_ok, structural_msg = check_structural(app_install_dir)
    if not structural_ok:
        return HealthCheckResult(False, structural_msg, method="structural")
    return run_functional_check(settings, supervisor, retries, retry_delay_seconds)
