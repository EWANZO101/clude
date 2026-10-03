"""
Core agent service. Runs the periodic sync loop in a background thread.
Screenshot capture, activity monitoring, and URL tracking (Phases 15-17)
hook into this by calling their own interval loops, which use the same
ApiClient/local_queue underneath.

This module intentionally has no OS-specific code - that lives in the
platform-specific capture modules added in later phases. This keeps the
core service portable and testable without a real display/input stack.
"""
import threading
import time as time_module
import logging
from agent.config import load_config
from agent.api_client import ApiClient
from agent import local_queue
from agent.screenshot import ScreenshotCapturer
from agent.activity import ActivityMonitor
from agent.url_fallback import WindowTitleFallback

logging.basicConfig(level=logging.INFO, format='%(asctime)s [%(levelname)s] %(message)s')
logger = logging.getLogger('teamtreck-agent')


class AgentService:
    def __init__(self):
        self.cfg = load_config()
        self.client = ApiClient()
        self._stop_event = threading.Event()
        self._sync_thread = None
        self.active_time_entry_id = None  # set by timer control; used to tag activity/url logs
        self.screenshot_capturer = ScreenshotCapturer(self)
        self.activity_monitor = ActivityMonitor(self)
        self.url_fallback = WindowTitleFallback(self)  # disabled by default - see agent/url_fallback.py

    # ---------- lifecycle ----------

    def start(self):
        logger.info('Starting TeamTreck agent service')
        if not self.cfg.get('api_token'):
            logger.warning('No API token configured - run `teamtreck-agent setup` first')

        self._stop_event.clear()
        self._sync_thread = threading.Thread(target=self._sync_loop, daemon=True)
        self._sync_thread.start()
        logger.info('Sync loop started (interval: %ss)', self.cfg['sync_interval_seconds'])

        self.screenshot_capturer.start()
        self.activity_monitor.start()
        self.url_fallback.start()

    def stop(self):
        logger.info('Stopping TeamTreck agent service')
        self._stop_event.set()
        if self._sync_thread:
            self._sync_thread.join(timeout=5)
        self.screenshot_capturer.stop()
        self.activity_monitor.stop()
        self.url_fallback.stop()

    def run_forever(self):
        self.start()
        try:
            while not self._stop_event.is_set():
                time_module.sleep(1)
        except KeyboardInterrupt:
            pass
        finally:
            self.stop()

    # ---------- sync loop ----------

    def _sync_loop(self):
        while not self._stop_event.is_set():
            self._do_sync()
            self._stop_event.wait(self.cfg['sync_interval_seconds'])

    def _do_sync(self):
        pending = local_queue.queue_size()
        if pending == 0:
            return
        result = self.client.sync_queue()
        if result.get('synced', 0) > 0:
            logger.info('Synced %s/%s queued records', result['synced'], result['total'])
        if result.get('error'):
            logger.warning('Sync attempt failed (%s queued), will retry next interval', pending)

    # ---------- timer control (used by CLI and later by tray icon) ----------

    def start_timer(self, project_id=None, task_id=None, note=''):
        ok = self.client.start_timer(project_id, task_id, note)
        status = self.client.timer_status()
        if status.get('active'):
            self.active_time_entry_id = status.get('id')
        return ok

    def pause_timer(self):
        status = self.client.timer_status()
        if status.get('active') and status.get('id'):
            return self.client.pause_timer(status['id'])
        return False

    def resume_timer(self):
        status = self.client.timer_status()
        if status.get('active') and status.get('id'):
            return self.client.resume_timer(status['id'])
        return False

    def stop_timer(self):
        status = self.client.timer_status()
        if status.get('active') and status.get('id'):
            ok = self.client.stop_timer(status['id'])
            self.active_time_entry_id = None
            return ok
        return False

    def status(self):
        s = self.client.timer_status()
        s['queue_size'] = local_queue.queue_size()
        s['server_reachable'] = self.client.ping()
        return s
