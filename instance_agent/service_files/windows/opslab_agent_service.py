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


if __name__ == "__main__":
    if win32serviceutil is None:
        print("pywin32 is required to install/run this as a Windows service "
              "(pip install pywin32). This file can still be read/reviewed "
              "without it.", file=sys.stderr)
        sys.exit(1)
    win32serviceutil.HandleCommandLine(OpsLabAgentService)
