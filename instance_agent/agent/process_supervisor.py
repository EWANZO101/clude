"""
Manages the Kiosk Application as a real OS subprocess (spec Section 2.2:
'Starting/stopping/restarting the kiosk application') and watches it for
crashes independently of the update lifecycle (spec Sections 44-45).

This is deliberately generic — it supervises whatever command is configured
as the kiosk app, since the actual Kiosk Application is still a separate,
unbuilt project. Every behavior here is exercised in tests against real
dummy subprocesses, not mocked.

Two failure modes this is built around:
  - A single crash: detect it, restart automatically, keep going.
  - A crash LOOP (genuinely broken app): spec Section 45 explicitly says
    the watchdog "should not repeatedly restart a genuinely broken
    application forever" — after too many crashes in too short a window,
    this gives up and reports it rather than burning CPU in a restart loop
    forever. Manual intervention (or a fixed update) is needed to clear it.
"""
import logging
import os
import shlex
import subprocess
import threading
import time

log = logging.getLogger("agent.process_supervisor")


class ProcessSupervisor:
    def __init__(self, command, working_dir: str = None, env: dict = None, name: str = "kiosk-app",
                 restart_backoff_seconds: float = 2.0, max_restarts_in_window: int = 5,
                 window_seconds: float = 60.0, healthy_reset_after_seconds: float = 120.0):
        """command: a string (parsed with shlex) or a list of argv."""
        self.command = shlex.split(command) if isinstance(command, str) else list(command)
        self.working_dir = working_dir
        self.env = env
        self.name = name

        self.restart_backoff_seconds = restart_backoff_seconds
        self.max_restarts_in_window = max_restarts_in_window
        self.window_seconds = window_seconds
        self.healthy_reset_after_seconds = healthy_reset_after_seconds

        self._process = None
        self._last_start_time = None
        self._restart_timestamps = []
        self._giving_up = False
        self._explicit_stop = False  # True while stop() is in progress — watchdog ignores the exit

        self._lock = threading.RLock()
        self._watchdog_stop = threading.Event()
        self._watchdog_thread = None

    # --- basic lifecycle ---
    def start(self):
        with self._lock:
            if self.is_running():
                log.debug("%s already running (pid=%s)", self.name, self._process.pid)
                return
            log.info("Starting %s: %s", self.name, " ".join(self.command))
            self._process = subprocess.Popen(
                self.command, cwd=self.working_dir, env=self.env,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            self._last_start_time = time.monotonic()
            self._explicit_stop = False

    def stop(self, timeout: float = 10.0):
        with self._lock:
            self._explicit_stop = True
            proc = self._process
            if proc is None or proc.poll() is not None:
                self._process = None
                return
            log.info("Stopping %s (pid=%s)...", self.name, proc.pid)
            proc.terminate()
        # Wait outside the lock — terminate()/wait() shouldn't block other callers.
        try:
            proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            log.warning("%s did not exit within %ss, killing it", self.name, timeout)
            proc.kill()
            proc.wait()
        with self._lock:
            self._process = None

    def restart(self):
        """An explicit, requested restart (e.g. after an update installs) —
        distinct from the watchdog's automatic crash-recovery restart. Always
        clears any prior 'giving up' state, since a fresh install is a good
        reason to give the process another chance."""
        log.info("Restarting %s (explicit request)", self.name)
        self.stop()
        with self._lock:
            self._giving_up = False
            self._restart_timestamps = []
        self.start()

    def is_running(self) -> bool:
        with self._lock:
            return self._process is not None and self._process.poll() is None

    def status(self) -> dict:
        with self._lock:
            return {
                "name": self.name,
                "running": self.is_running(),
                "pid": self._process.pid if self.is_running() else None,
                "giving_up": self._giving_up,
                "restarts_in_window": len(self._restart_timestamps),
            }

    # --- watchdog ---
    def start_watchdog(self, poll_interval: float = 2.0):
        self._watchdog_stop.clear()
        self._watchdog_thread = threading.Thread(
            target=self._watchdog_loop, args=(poll_interval,), name=f"{self.name}-watchdog", daemon=True,
        )
        self._watchdog_thread.start()

    def stop_watchdog(self):
        self._watchdog_stop.set()
        if self._watchdog_thread:
            self._watchdog_thread.join(timeout=5)

    def _watchdog_loop(self, poll_interval: float):
        while not self._watchdog_stop.wait(poll_interval):
            self._tick()

    def _tick(self):
        """One watchdog check. Split out from _watchdog_loop so tests can
        drive it deterministically instead of racing a real timer."""
        with self._lock:
            if self._explicit_stop or self._process is None:
                return  # intentionally stopped — nothing to watch
            if self._giving_up:
                return  # already gave up — don't keep hammering a broken app
            if self._process.poll() is None:
                # Still running — check whether it's been stable long enough
                # to forgive past crashes (spec Section 45's watchdog
                # shouldn't hold a years-old blip against the app forever).
                if self._restart_timestamps and self._last_start_time and \
                        (time.monotonic() - self._last_start_time) > self.healthy_reset_after_seconds:
                    log.info("%s has been stable for %.0fs — resetting crash counter",
                             self.name, self.healthy_reset_after_seconds)
                    self._restart_timestamps = []
                return

            exit_code = self._process.returncode
            log.error("%s exited unexpectedly (code=%s)", self.name, exit_code)
            self._process = None

        # Handle the crash outside the lock — start()/backoff shouldn't block
        # status()/stop() calls from other threads.
        self._handle_crash()

    def _handle_crash(self):
        now = time.monotonic()
        with self._lock:
            self._restart_timestamps = [t for t in self._restart_timestamps if now - t < self.window_seconds]
            self._restart_timestamps.append(now)
            count = len(self._restart_timestamps)

        if count > self.max_restarts_in_window:
            with self._lock:
                self._giving_up = True
            log.error(
                "%s has crashed %d times in the last %.0fs — giving up on automatic "
                "restarts. This requires manual attention (or a fixed update).",
                self.name, count, self.window_seconds,
            )
            return

        log.warning("Attempting automatic restart of %s (crash %d of %d allowed in window)",
                    self.name, count, self.max_restarts_in_window)
        time.sleep(self.restart_backoff_seconds)
        self.start()

    def clear_giving_up(self):
        """Manual (or update-triggered) reset of the giving-up state, e.g.
        after an operator has fixed whatever was crashing the app."""
        with self._lock:
            self._giving_up = False
            self._restart_timestamps = []
