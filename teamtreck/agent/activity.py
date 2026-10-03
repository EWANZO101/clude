"""
Activity monitoring.

Listens for keyboard and mouse events system-wide (via pynput), counts
them, and tracks idle time (no input for longer than config.idle_threshold_seconds).
Every config.activity_report_interval_seconds, aggregates the window and
reports it via ApiClient.log_activity() - only while a timer is running,
matching the spec ("activity monitoring only applies during tracked work
sessions").

pynput requires accessibility permissions on macOS and may need to run as
root/with input group membership on some Linux setups - this is a known,
unavoidable OS-level requirement for any keyboard/mouse monitoring tool
(see Phase 18 notes on packaging/permissions).
"""
import threading
import logging
import time as time_module
from datetime import datetime

logger = logging.getLogger('teamtreck-agent.activity')

try:
    from pynput import keyboard, mouse
    HOOKS_AVAILABLE = True
except ImportError:
    HOOKS_AVAILABLE = False


class ActivityMonitor:
    """
    Tracks keyboard/mouse event counts and idle time in a rolling window,
    reports the window to the server on an interval, then resets counters.
    Only runs its report loop while a timer is active on the server.
    """

    def __init__(self, service):
        self.service = service
        self._stop_event = threading.Event()
        self._report_thread = None

        self._lock = threading.Lock()
        self._keyboard_events = 0
        self._mouse_events = 0
        self._last_input_time = time_module.monotonic()
        self._window_start = datetime.utcnow()

        self._kb_listener = None
        self._mouse_listener = None

    # ---------- input event handlers (called from pynput's own threads) ----------

    def _on_key(self, key):
        with self._lock:
            self._keyboard_events += 1
            self._last_input_time = time_module.monotonic()

    def _on_click(self, x, y, button, pressed):
        if pressed:
            with self._lock:
                self._mouse_events += 1
                self._last_input_time = time_module.monotonic()

    def _on_move(self, x, y):
        with self._lock:
            self._last_input_time = time_module.monotonic()

    def _on_scroll(self, x, y, dx, dy):
        with self._lock:
            self._mouse_events += 1
            self._last_input_time = time_module.monotonic()

    # ---------- lifecycle ----------

    def start(self):
        if not HOOKS_AVAILABLE:
            logger.warning('Activity monitoring disabled: pynput not installed')
            return

        try:
            self._kb_listener = keyboard.Listener(on_press=self._on_key)
            self._mouse_listener = mouse.Listener(on_click=self._on_click, on_move=self._on_move, on_scroll=self._on_scroll)
            self._kb_listener.start()
            self._mouse_listener.start()
        except Exception as e:
            logger.error('Failed to start input listeners (permissions?): %s', e)
            return

        self._window_start = datetime.utcnow()
        self._stop_event.clear()
        self._report_thread = threading.Thread(target=self._report_loop, daemon=True)
        self._report_thread.start()
        logger.info('Activity monitoring started (report interval: %ss, idle threshold: %ss)',
                     self.service.cfg['activity_report_interval_seconds'],
                     self.service.cfg['idle_threshold_seconds'])

    def stop(self):
        self._stop_event.set()
        if self._kb_listener:
            self._kb_listener.stop()
        if self._mouse_listener:
            self._mouse_listener.stop()
        if self._report_thread:
            self._report_thread.join(timeout=5)

    # ---------- reporting loop ----------

    def _report_loop(self):
        while not self._stop_event.is_set():
            self._stop_event.wait(self.service.cfg['activity_report_interval_seconds'])
            if self._stop_event.is_set():
                break
            self._report_window()

    def _report_window(self):
        status = self.service.client.timer_status()
        if not status.get('active'):
            self._reset_window()
            return

        with self._lock:
            keyboard_events = self._keyboard_events
            mouse_events = self._mouse_events
            window_start = self._window_start
            idle_secs_now = time_module.monotonic() - self._last_input_time

        window_end = datetime.utcnow()
        window_seconds = max(1, int((window_end - window_start).total_seconds()))

        idle_threshold = self.service.cfg['idle_threshold_seconds']
        if idle_secs_now >= idle_threshold:
            active_seconds = 0
            idle_seconds = window_seconds
        else:
            active_seconds = window_seconds
            idle_seconds = 0

        entry_id = status.get('id')
        ok = self.service.client.log_activity(
            window_start.isoformat(), window_end.isoformat(),
            keyboard_events, mouse_events, active_seconds, idle_seconds,
            time_entry_id=entry_id,
        )
        if ok:
            logger.info('Activity reported: kb=%s mouse=%s active=%ss idle=%ss',
                         keyboard_events, mouse_events, active_seconds, idle_seconds)
        else:
            logger.info('Activity queued for later sync (offline)')

        self._reset_window()

    def _reset_window(self):
        with self._lock:
            self._keyboard_events = 0
            self._mouse_events = 0
            self._window_start = datetime.utcnow()
