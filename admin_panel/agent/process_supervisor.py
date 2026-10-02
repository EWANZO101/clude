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
    def __init__(self, command=None, working_dir: str = None, env: dict = None, name: str = "kiosk-app",
                 restart_backoff_seconds: float = 2.0, max_restarts_in_window: int = 5,
                 window_seconds: float = 60.0, healthy_reset_after_seconds: float = 120.0,
                 log_path: str = None):
        """command: a string (parsed with shlex), a list of argv, or None/empty
        for 'not configured yet' — the Agent now always keeps ONE
        ProcessSupervisor instance alive for the whole run (see agent/main.py),
        rather than being None until a kiosk_start_command exists, so a
        remote 'configure' command (agent/commands.py) has something to call
        reconfigure() on instead of needing to construct a new supervisor and
        somehow hand it to the already-running heartbeat/update/watchdog
        threads."""
        self.command = self._parse_command(command)
        self.working_dir = working_dir
        self.env = env
        self.name = name
        # Was DEVNULL before this — every diagnosis of a supervised process
        # dying (including a real one: a clean exit(0) about 12s after a
        # successful start, cause unknown) hit the same dead end of having
        # no idea why, because its stdout/stderr went straight to the void.
        # Appended to (not truncated) across restarts so a crash-loop's
        # full history stays in one place; the file itself is never
        # rotated/pruned here — an operator's problem to manage disk usage
        # for, same as any other log.
        self.log_path = log_path

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

    @staticmethod
    def _parse_command(command):
        if not command:
            return []
        return shlex.split(command) if isinstance(command, str) else list(command)

    def is_configured(self) -> bool:
        with self._lock:
            return bool(self.command)

    def reconfigure(self, command, working_dir: str = None):
        """Updates what start()/restart() will run, WITHOUT touching any
        currently-running process — callers (agent/commands.py's 'configure'
        handler) decide whether to stop the old one / start the new one, so
        this can't leave a half-applied state if something after it fails."""
        with self._lock:
            self.command = self._parse_command(command)
            if working_dir is not None:
                self.working_dir = working_dir
            # A fresh configuration deserves a fresh chance, same reasoning
            # as restart()'s explicit-request reset.
            self._giving_up = False
            self._restart_timestamps = []

    # --- basic lifecycle ---
    def start(self):
        with self._lock:
            if not self.command:
                log.info("%s has no command configured — nothing to start.", self.name)
                return
            if self.is_running():
                log.debug("%s already running (pid=%s)", self.name, self._process.pid)
                return
            log.info("Starting %s: %s", self.name, " ".join(self.command))
            log_handle = subprocess.DEVNULL
            if self.log_path:
                try:
                    os.makedirs(os.path.dirname(self.log_path), exist_ok=True)
                    log_handle = open(self.log_path, "a", encoding="utf-8", errors="replace")
                    log_handle.write(f"\n----- {self.name} starting: {' '.join(self.command)} -----\n")
                    log_handle.flush()
                except OSError as e:
                    log.warning("Could not open %s for %s output (%s) — falling back to discarding it.",
                                self.log_path, self.name, e)
                    log_handle = subprocess.DEVNULL
            proc_env = dict(self.env) if self.env else os.environ.copy()
            # Force unbuffered stdout/stderr on the child. Python fully
            # buffers stdio by default whenever it isn't a real terminal -
            # which it never is here, it's redirected to log_handle above -
            # and only flushes that buffer on a clean exit. stop()/restart()
            # (and the watchdog, on a real crash) kill the child with
            # terminate()/kill(), which does NOT run Python's normal
            # shutdown/flush machinery - so anything printed but not yet
            # flushed was silently lost. This is exactly what made an
            # earlier debugging attempt capture only a start banner and
            # nothing else, even though the child clearly did print
            # something before whatever ended it. Harmless for a
            # non-Python command (CPython-specific env var, ignored by
            # anything else).
            proc_env.setdefault("PYTHONUNBUFFERED", "1")
            popen_kwargs = {}
            if os.name == "nt":
                # Without this, the child shares the parent console's
                # process group, and Windows broadcasts Ctrl+C/Ctrl+Break
                # to EVERY process in that group - so stopping the Agent's
                # own foreground "run" session with Ctrl+C also silently
                # kills the supervised kiosk-app child out from under it,
                # cleanly and with no error output, completely independent
                # of anything ProcessSupervisor itself does. This matches
                # exactly what was observed: a clean exit(0), no traceback,
                # nothing logged - because nothing actually went wrong in
                # the app, something outside it just signaled it to stop.
                # A new process group isolates the child from that
                # broadcast; explicit stop()/restart() below are unaffected
                # since terminate()/kill() operate on the process handle
                # directly, not through console signals.
                popen_kwargs["creationflags"] = subprocess.CREATE_NEW_PROCESS_GROUP
            self._process = subprocess.Popen(
                self.command, cwd=self.working_dir, env=proc_env,
                stdout=log_handle, stderr=subprocess.STDOUT if log_handle != subprocess.DEVNULL else subprocess.DEVNULL,
                **popen_kwargs,
            )
            if log_handle != subprocess.DEVNULL:
                log_handle.close()  # the child has its own inherited copy of the fd now
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
        with self._lock:
            if self._watchdog_thread is not None and self._watchdog_thread.is_alive():
                return  # already running — safe to call more than once (main.py always calls it)
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
