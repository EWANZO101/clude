"""
StockTool Kiosk (v2) — entry point.

This is what PyInstaller bundles into StockToolKiosk.exe. It:
  1. Starts the embedded API server under watchdog supervision (auto-
     restarts on crash — see watchdog.py).
  2. Waits for it to actually come up.
  3. Opens the kiosk UI in the system default browser.
  4. Blocks forever so the .exe keeps running as a background service
     for as long as the kiosk needs it (closing the browser tab does
     NOT stop the server — see the tray/quit note below).

No installer, no admin rights, no separate runtime — PyInstaller bundles
the Python interpreter itself into the .exe. First run creates its local
SQLite DB under %LOCALAPPDATA%\\StockToolKiosk\\ automatically.
"""
import sys
import time
import threading
import webbrowser
import urllib.request

from watchdog import Supervisor

BASE_URL = "http://0.0.0.0:8420"


def _wait_for_server(timeout_seconds=15) -> bool:
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(f"{BASE_URL}/api/status", timeout=1) as resp:
                if resp.status == 200:
                    return True
        except Exception:
            pass
        time.sleep(0.3)
    return False


def main():
    supervisor = Supervisor()
    server_thread = threading.Thread(target=supervisor.run_forever, daemon=True)
    server_thread.start()

    if not _wait_for_server():
        print("ERROR: embedded server did not start in time.", file=sys.stderr)
        sys.exit(1)

    webbrowser.open(f"{BASE_URL}/ui/")
    print(f"StockTool Kiosk is running at {BASE_URL}/ui/")
    print("Close this window to stop the kiosk server.")

    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        print("Shutting down.")


if __name__ == "__main__":
    main()
