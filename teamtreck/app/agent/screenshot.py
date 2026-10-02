"""
Screenshot capture.

Uses mss (cross-platform, works on Windows/Mac/Linux without extra system
deps) to grab the full virtual screen, downscale it to keep upload size
reasonable, and hand it to ApiClient.upload_screenshot() as base64 PNG.

Design notes matching the TeamTreck spec:
- Only captures while a time entry is actively running (never idle/no-timer).
- Interval is configurable (config.screenshot_interval_seconds), matching
  TeamTreck's "every 5/10/15 min" examples - default 10 min here.
- Never records webcam or audio - screen only, this module does nothing else.
- Screenshots are NOT queued in the local offline SQLite queue (that's meant
  for small JSON records); if a screenshot upload fails, it's simply
  dropped and the next interval takes a fresh one - avoids accumulating
  large binary blobs in the lightweight sync queue.
"""
import io
import base64
import threading
import logging
from datetime import datetime

logger = logging.getLogger('teamtreck-agent.screenshot')

try:
    import mss
    from PIL import Image
    CAPTURE_AVAILABLE = True
except ImportError:
    CAPTURE_AVAILABLE = False


MAX_WIDTH = 1600  # downscale target - keeps upload size reasonable without losing readability


def capture_screenshot_b64():
    """Captures the full virtual screen (all monitors) and returns a base64-encoded PNG string.
    Returns None if capture isn't available on this platform or fails."""
    if not CAPTURE_AVAILABLE:
        logger.warning('Screenshot capture unavailable - install mss and Pillow')
        return None

    try:
        with mss.mss() as sct:
            # monitor 0 = the union of all monitors (full virtual screen)
            raw = sct.grab(sct.monitors[0])
            img = Image.frombytes('RGB', raw.size, raw.bgra, 'raw', 'BGRX')

            if img.width > MAX_WIDTH:
                ratio = MAX_WIDTH / img.width
                img = img.resize((MAX_WIDTH, int(img.height * ratio)), Image.LANCZOS)

            buf = io.BytesIO()
            img.save(buf, format='PNG', optimize=True)
            return base64.b64encode(buf.getvalue()).decode('ascii')
    except Exception as e:
        logger.error('Screenshot capture failed: %s', e)
        return None


class ScreenshotCapturer:
    """Runs a background loop that captures + uploads a screenshot on an interval,
    but only while the agent reports an active (running or paused) time entry."""

    def __init__(self, service):
        self.service = service  # AgentService instance - gives us client + active entry state
        self._stop_event = threading.Event()
        self._thread = None

    def start(self):
        if not CAPTURE_AVAILABLE:
            logger.warning('Screenshot capture disabled: mss/Pillow not installed')
            return
        self._stop_event.clear()
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()
        logger.info('Screenshot capture loop started (interval: %ss)',
                     self.service.cfg['screenshot_interval_seconds'])

    def stop(self):
        self._stop_event.set()
        if self._thread:
            self._thread.join(timeout=5)

    def _loop(self):
        while not self._stop_event.is_set():
            self._maybe_capture()
            self._stop_event.wait(self.service.cfg['screenshot_interval_seconds'])

    def _maybe_capture(self):
        status = self.service.client.timer_status()
        if not status.get('active'):
            return  # no running/paused timer - don't capture

        image_b64 = capture_screenshot_b64()
        if not image_b64:
            return

        entry_id = status.get('id')
        session_id = f'{entry_id}-{datetime.utcnow().strftime("%Y%m%d")}'
        ok = self.service.client.upload_screenshot(image_b64, time_entry_id=entry_id, session_id=session_id)
        if ok:
            logger.info('Screenshot uploaded (entry %s)', entry_id)
        else:
            logger.warning('Screenshot upload failed (entry %s) - dropped, will try again next interval', entry_id)
