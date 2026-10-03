"""
Holds "an update is coming" state so the UI can show a warning and
countdown BEFORE the kiosk restarts itself -- separate from
sync_loop.py's own poll interval, since the wait-then-apply timer here
runs on its own clock (DELAY_SECONDS) regardless of how often the sync
loop itself checks for updates.

Previously (see sync_loop.py's fix note) a verified update applied
immediately, with zero warning to whoever was using the kiosk mid-task.
Now: verify -> schedule_update() -> UI polls get_status() and shows a
countdown -> apply only once the delay elapses.
"""
import threading
import time

DEFAULT_DELAY_SECONDS = 60

_lock = threading.Lock()
_state = {"pending": False, "version": None, "apply_at": None}


def schedule_update(new_path, version, apply_update_fn, delay_seconds=DEFAULT_DELAY_SECONDS):
    """No-ops if an update is already pending, so a re-detection on the
    next sync cycle (before the first one has even applied) can't stack
    multiple competing timers."""
    with _lock:
        if _state["pending"]:
            return False
        apply_at = time.time() + delay_seconds
        _state["pending"] = True
        _state["version"] = version
        _state["apply_at"] = apply_at

    def wait_then_apply():
        remaining = apply_at - time.time()
        if remaining > 0:
            time.sleep(remaining)
        apply_update_fn(new_path)  # does not return on success -- process exits and relaunches

    threading.Thread(target=wait_then_apply, daemon=True, name="UpdateApply").start()
    return True


def get_status():
    with _lock:
        if not _state["pending"]:
            return {"pending": False}
        remaining = max(0, int(_state["apply_at"] - time.time()))
        return {"pending": True, "version": _state["version"], "seconds_remaining": remaining}


def _reset_for_tests():
    """Test-only hook -- production code never needs to un-schedule a
    pending update once verified and committed to."""
    with _lock:
        _state["pending"] = False
        _state["version"] = None
        _state["apply_at"] = None
