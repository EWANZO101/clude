"""
Reads the config file the Instance Agent's agent/config_manager.py writes
(spec Section 11: Admin Panel -> Instance Agent -> kiosk_config_path ->
Kiosk Application). This is the first real reader that path has ever had —
every part of the Instance Agent project that depended on "a Kiosk
Application exists to read this" was built and tested against that gap
honestly stated; this closes it.

The Agent writes whatever JSON object the Admin Panel operator configured,
with no fixed schema on the Agent's side (agent/config_manager.py::
validate_config only checks "is this a JSON object at all"). This module is
where the Kiosk Application actually defines what it expects to find in
that object — everything is optional with a sensible default, so an empty
or partially-filled config never crashes the display, it just shows
defaults for whatever wasn't set.
"""
import json
import logging
import os
import threading

log = logging.getLogger("kiosk.config")

DEFAULTS = {
    "store_name": "OpsLab Kiosk",
    "display_message": "Welcome!",
    "refresh_interval_seconds": 30,
}


class KioskConfig:
    """Thread-safe holder for the current config, with an optional
    background poller that picks up changes written by the Instance Agent
    without needing a restart — the Agent applies new config by
    atomically replacing the file (os.replace, see config_manager.py), so
    polling mtime is enough to notice a change reliably."""

    def __init__(self, path: str):
        self.path = path
        self._lock = threading.Lock()
        self._values = dict(DEFAULTS)
        self._mtime = None
        self._poll_stop = threading.Event()
        self._poll_thread = None
        self.reload()

    def reload(self) -> bool:
        """Re-reads the config file if it exists and has changed since the
        last read. Returns True if the in-memory config actually changed.
        Never raises: a missing, empty, or malformed file just means
        'nothing new to apply', falling back to whatever was last valid
        (or the defaults, on first run) rather than crashing the display
        over a config problem."""
        if not self.path or not os.path.isfile(self.path):
            return False

        try:
            mtime = os.path.getmtime(self.path)
        except OSError:
            return False

        with self._lock:
            if mtime == self._mtime:
                return False  # unchanged since last read

        try:
            with open(self.path, "r", encoding="utf-8") as f:
                raw = json.load(f)
        except (OSError, ValueError) as e:
            log.warning("Could not read/parse config at %s (keeping current values): %s", self.path, e)
            return False

        if not isinstance(raw, dict):
            log.warning("Config at %s is not a JSON object (keeping current values)", self.path)
            return False

        merged = dict(DEFAULTS)
        merged.update(raw)

        with self._lock:
            changed = merged != self._values
            self._values = merged
            self._mtime = mtime

        if changed:
            log.info("Config reloaded from %s: %s", self.path, merged)
        return changed

    def get(self, key: str, default=None):
        with self._lock:
            return self._values.get(key, default)

    def snapshot(self) -> dict:
        with self._lock:
            return dict(self._values)

    def start_polling(self, interval_seconds: float = 5.0):
        self._poll_stop.clear()

        def _loop():
            while not self._poll_stop.wait(interval_seconds):
                self.reload()

        self._poll_thread = threading.Thread(target=_loop, name="config-poll", daemon=True)
        self._poll_thread.start()

    def stop_polling(self):
        self._poll_stop.set()
        if self._poll_thread:
            self._poll_thread.join(timeout=2)
