"""
Windows service wrapper for the Instance Agent, using the standard
pywin32 win32serviceutil pattern.

IMPORTANT — HONEST LIMITATION: this file is structurally correct per the
standard pywin32 service pattern (the same shape used by essentially every
Windows service written in Python), but it has NOT been run or tested on an
actual Windows machine — this build environment is Linux-only and has no
Windows box available. Treat this as a solid, standard-pattern starting
point that needs a real Windows smoke test before Part 5's MSI installer
ships it, not as verified-working code the way everything else in this
project has been.

Requires: pip install pywin32

Install as a service (from an elevated/Administrator prompt):
    python opslab_agent_service.py install
    python opslab_agent_service.py start

Uninstall:
    python opslab_agent_service.py stop
    python opslab_agent_service.py remove

Windows Service Manager restarts this automatically on crash if configured
via `sc.exe failure` (Part 5's installer sets this up) — the same role
systemd's Restart=always plays on Linux (spec Section 52).
"""
import sys

# The Windows Service Manager launches this script with sys.path[0] set to
# its OWN directory (...\OpsLabAgent\service\), not the parent install
# directory where agent\ actually lives as a sibling folder - so `from
# agent.main import run` fails with "ModuleNotFoundError: No module named
# 'agent'" every time, and the service exits immediately after start.
# Fixed by explicitly adding the parent install directory to sys.path
# before that import is ever attempted. Harmless when run any other way
# (console "run" mode, non-Windows import-for-review) since it's just an
# extra sys.path entry.
import os
_INSTALL_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _INSTALL_ROOT not in sys.path:
    sys.path.insert(0, _INSTALL_ROOT)

try:
    import win32serviceutil
    import win32service
    import win32event
    import servicemanager
    import threading
except ImportError:
    win32serviceutil = None  # allows this file to at least be imported/read on non-Windows for review


if win32serviceutil is not None:

    class OpsLabAgentService(win32serviceutil.ServiceFramework):
        _svc_name_ = "OpsLabAgent"
        _svc_display_name_ = "OpsLab Instance Agent"
        _svc_description_ = (
            "Connects this kiosk to the OpsLab Admin Panel, applies remote "
            "configuration and updates, and supervises the kiosk application."
        )

        def __init__(self, args):
            win32serviceutil.ServiceFramework.__init__(self, args)
            self.stop_event = win32event.CreateEvent(None, 0, 0, None)
            self._agent_stop_event = threading.Event()

        def SvcStop(self):
            self.ReportServiceStatus(win32service.SERVICE_STOP_PENDING)
            win32event.SetEvent(self.stop_event)
            self._agent_stop_event.set()

        def SvcDoRun(self):
            servicemanager.LogMsg(
                servicemanager.EVENTLOG_INFORMATION_TYPE,
                servicemanager.PYS_SERVICE_STARTED,
                (self._svc_name_, ""),
            )
            self.main()

        def main(self):
            # Imported here rather than at module level so `--help`/install/
            # remove subcommands don't need the full agent package importable.
            from agent.main import run as agent_run

            # Runs agent.main.run() with OUR event as its internal stop_event,
            # so SvcStop() can signal a clean shutdown directly rather than
            # relying on OS signals (which behave differently for Windows
            # services than for a console process).
            def target():
                agent_run(external_stop_event=self._agent_stop_event)

            t = threading.Thread(target=target, daemon=True)
            t.start()
            win32event.WaitForSingleObject(self.stop_event, win32event.INFINITE)

            # SvcStop() has now signaled both events, but agent_run()'s own
            # shutdown — stopping the supervised kiosk-app child process
            # (which holds the bundled Python runtime's DLLs open) and
            # joining the heartbeat/update/command threads — runs
            # asynchronously on `t` and was NOT being waited for here.
            # Returning from main() immediately let pywin32 report the
            # service as STOPPED to the SCM before that cleanup had
            # actually finished — which is exactly what caused a real
            # reinstall to fail with "Can't unlink already-existing
            # object: Permission denied" on python.exe and its DLLs:
            # Stop-Service returned "stopped", but the old kiosk-app
            # process (spawned by the old python.exe) was, for a moment
            # longer, still alive and still holding those files open.
            # 30s comfortably covers agent.main.run()'s own worst case
            # (up to four 5s thread joins plus ProcessSupervisor.stop()'s
            # own 10s subprocess-terminate timeout).
            t.join(timeout=30)
            if t.is_alive():
                servicemanager.LogWarningMsg(
                    "OpsLabAgent: shutdown did not finish within 30s — reporting the "
                    "service stopped anyway. Some file handles (the Python runtime, "
                    "any supervised kiosk-app process) may still briefly be open, "
                    "which can make an immediately-following reinstall fail to "
                    "overwrite them — if that happens, wait a few seconds and retry."
                )


if __name__ == "__main__":
    # "run" is a foreground/console mode this file adds on top of the
    # standard pywin32 install/start/stop/remove subcommands — lets the
    # single built exe be run interactively (no service install, no admin
    # rights, Ctrl+C to stop) for first-run registration or debugging,
    # without needing pywin32 at all.
    if len(sys.argv) > 1 and sys.argv[1] == "run":
        from agent.main import run as agent_run
        agent_run()
        sys.exit(0)

    if win32serviceutil is None:
        print("pywin32 is required to install/run this as a Windows service "
              "(pip install pywin32). This file can still be read/reviewed "
              "without it. Use 'run' for a plain console mode instead.",
              file=sys.stderr)
        sys.exit(1)
    win32serviceutil.HandleCommandLine(OpsLabAgentService)
