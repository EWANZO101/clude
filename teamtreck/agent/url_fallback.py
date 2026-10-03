"""
OS-level window-title fallback for URL tracking.

The browser extension (see /browser-extension) is the RECOMMENDED way to
track URLs - it gets real URLs, respects incognito natively, and needs no
special OS permissions. This module is a fallback for setups where the
extension isn't installed: it reads the active window's title (not a real
URL) and reports that instead, so at least something shows up in the
Website Activity report.

Known limitations (why this is a fallback, not the primary method):
- Only gets the window/tab TITLE, not the actual URL - "category"
  detection on the server (which matches by domain) won't work well
  since there's no domain to categorize, just a title string.
- Can't reliably distinguish incognito/private browser windows from
  normal ones at the OS level - titles look the same. Because of this,
  this fallback is DISABLED by default (see ENABLE_FALLBACK below) and
  should only be turned on with the user's informed consent, since it
  can't honor "never track private browsing" as reliably as the
  extension can.
- Requires different libraries per OS. Implementation below covers
  Windows and macOS; Linux falls back to doing nothing (no reliable
  cross-compositor API, especially on Wayland, without extra setup).
"""
import sys
import threading
import logging
from datetime import datetime

logger = logging.getLogger('teamtreck-agent.url_fallback')

# Off by default - see limitations above. An installer/setup wizard (Phase 18)
# should surface this as an explicit opt-in checkbox, not silently enable it.
ENABLE_FALLBACK = False

BROWSER_PROCESS_HINTS = ['chrome', 'firefox', 'safari', 'edge', 'brave', 'opera']


def _get_active_window_title():
    """Returns the active window title, or None if unavailable on this platform."""
    try:
        if sys.platform == 'win32':
            import win32gui
            hwnd = win32gui.GetForegroundWindow()
            return win32gui.GetWindowText(hwnd) or None

        elif sys.platform == 'darwin':
            from AppKit import NSWorkspace
            active_app = NSWorkspace.sharedWorkspace().activeApplication()
            return active_app.get('NSApplicationName') if active_app else None

        else:
            return None
    except Exception as e:
        logger.debug('Could not read active window title: %s', e)
        return None


def _looks_like_browser(title):
    if not title:
        return False
    lowered = title.lower()
    return any(hint in lowered for hint in BROWSER_PROCESS_HINTS)


class WindowTitleFallback:
    """Polls the active window title periodically and logs it as a pseudo-URL
    entry, ONLY if it looks like a browser window and ONLY if explicitly
    enabled. Intended purely as a stopgap until the browser extension is
    installed."""

    def __init__(self, service, poll_interval_seconds=30):
        self.service = service
        self.poll_interval_seconds = poll_interval_seconds
        self._stop_event = threading.Event()
        self._thread = None
        self._current_title = None
        self._window_start = None

    def start(self):
        if not ENABLE_FALLBACK:
            logger.info('Window-title URL fallback is disabled by default (install the browser extension instead)')
            return
        self._stop_event.clear()
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()
        logger.info('Window-title URL fallback started (poll interval: %ss)', self.poll_interval_seconds)

    def stop(self):
        self._stop_event.set()
        if self._thread:
            self._thread.join(timeout=5)
        self._flush()

    def _loop(self):
        while not self._stop_event.is_set():
            self._poll()
            self._stop_event.wait(self.poll_interval_seconds)

    def _poll(self):
        title = _get_active_window_title()

        if title != self._current_title:
            self._flush()
            if _looks_like_browser(title):
                self._current_title = title
                self._window_start = datetime.utcnow()
            else:
                self._current_title = None
                self._window_start = None

    def _flush(self):
        if not self._current_title or not self._window_start:
            return

        status = self.service.client.timer_status()
        if not status.get('active'):
            self._current_title = None
            self._window_start = None
            return

        duration = max(1, int((datetime.utcnow() - self._window_start).total_seconds()))
        pseudo_url = f'window-title://{self._current_title}'

        self.service.client.log_url(
            pseudo_url,
            title=self._current_title,
            duration_seconds=duration,
            visited_at_iso=self._window_start.isoformat(),
            time_entry_id=status.get('id'),
            private_browsing=False,
        )

        self._current_title = None
        self._window_start = None
