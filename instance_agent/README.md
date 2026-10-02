# OpsLab Instance Agent — Parts 1–6 (complete): Identity, Heartbeat, Config Sync, Update Lifecycle, Process Supervision, Health Checks + Automatic Rollback, Installers, Error Reporting, Remote Tunnel Stub

The lightweight background service that runs on every installed kiosk
machine, per the remake spec's Section 2.2. This is a **separate project**
from the Admin Panel (which is the server side) — this is the client that
runs on the customer's Ubuntu/Debian/Windows box and talks to it.

## What's new in Part 2

- `agent/package_validation.py` — agent-side re-validation of every
  downloaded package (never trusts "the Admin Panel already checked it"
  alone): ZIP integrity, zip-slip protection, `update.json` + `rescue/`
  requirements, mirroring the Admin Panel's own validator independently
- SHA-256 checksum verified against what the Admin Panel reported, before
  the archive is ever opened for real
- `agent/recovery.py` — Last Known Good snapshots (spec Section 19): before
  any install, the current `app_install_dir` and `kiosk_config_path` are
  copied into a per-deployment recovery point under a completely separate
  `recovery_dir` (spec Section 46 — recovery data never lives only inside
  the files being replaced). `restore_recovery_point()` reverses it exactly.
  `prune_old_recovery_points()` for disk housekeeping (never auto-called)
- `agent/installer.py` — extracts a validated package into `app_install_dir`,
  deliberately excluding `update.json` and the `rescue/` component (spec
  Section 17: rescue stays independent of the application it might need to
  recover)
- `agent/update_manager.py` — drives the full lifecycle against the Admin
  Panel's Part 6 endpoints: `waiting → downloading → validating → preparing
  → installing → restarting → health_check → successful`, reporting every
  transition. `restarting` is currently a log line only (no process to
  restart — Part 3), and `health_check` is an honestly-labeled **structural**
  check only (files present on disk, not "is it actually running" — Part 4)
- On failure at any stage, reports `failed` and stops — the recovery point
  is left intact and ready for `restore_recovery_point()`, but automatic
  triggering of the `rolling_back → rolled_back` path is Part 4's job (needs
  a real health check worth trusting enough to act on automatically)
- Tracks the installed version locally (`current_version.txt` next to
  `app_install_dir`) so heartbeats report real `app_version`
- Wired into `main.py` as a third background thread (update-poll)

## What's honestly NOT done yet (updated for Part 2)

- **No process supervision** — `restarting` is a log line, not a real
  restart, because there's no supervised Kiosk Application process. Part 3.
- **Health check is structural only** — confirms files exist, says nothing
  about whether an application is actually running or responding. Part 4.
- **No automatic rollback** — a failed health check reports `failed` and
  stops; the recovery point is there and `restore_recovery_point()` works
  (proven by direct test), but nothing calls it automatically yet. Part 4.
- **No mid-flight resume** — if the Agent restarts while a deployment is
  partway through (e.g. status=`installing`), the current poll loop logs
  that something's already in progress and does nothing further with it,
  rather than picking up where it left off.
- Still no remote tunnel, still no installer script/MSI (Parts 5, 6).

Everything above was integration-tested against the real Admin Panel
codebase running as an actual HTTP server (not mocked), including a full
happy-path lifecycle end to end, correct exclusion of `update.json`/`rescue/`
from the installed application files, an upgrade over an existing install
with correct `previous_version` snapshotting, and a real manual rollback
that correctly restored the prior version's exact file content.

## What's new in Part 3

- `agent/process_supervisor.py` — `ProcessSupervisor`: real start/stop/restart
  of a subprocess (the Kiosk Application, once it exists — generic in the
  meantime), plus a crash watchdog thread independent of the update lifecycle
  (spec Sections 44-45):
  - Detects an unexpected exit, waits a short backoff, restarts automatically
  - Tracks crashes in a rolling time window; after too many in too short a
    time it **gives up** on automatic restarts rather than looping forever
    (spec Section 45's explicit requirement) — `status()["giving_up"]` flags
    this for something upstream to surface (Part 6's error reporting)
  - A single crash followed by a long stable run resets the crash counter,
    so an old blip is never held against the app forever
  - `clear_giving_up()` for manual (or update-triggered) recovery
- `update_manager.py`'s `restarting` step now actually calls
  `supervisor.restart()` when a supervisor is configured (previously a log
  line only), and the health check now also confirms the process is running
  post-restart — still honestly labeled non-functional (a running-but-broken
  process still isn't caught; that's Part 4's real check)
- `service_files/systemd/opslab-agent.service` — supervises the **Agent
  itself** via systemd (`Restart=always`), the OS-level layer above the
  Agent's own supervision of the Kiosk Application, matching the spec's
  two-layer recovery hierarchy (Section 52)
- `service_files/windows/opslab_agent_service.py` — a standard
  `win32serviceutil`-pattern Windows service wrapper. **Explicitly flagged as
  untested on real Windows** (this build environment is Linux-only, no
  Windows box available) — structurally correct against the well-known
  pattern, but needs a real Windows smoke test before Part 5 ships it in the
  MSI. Every other file in this project has been tested for real; this one
  hasn't, and that's stated plainly rather than implied otherwise.
- New settings: `kiosk_start_command`, `kiosk_working_dir` — empty by
  default, so the Agent runs fine with nothing to supervise yet

All of `process_supervisor.py`'s crash/recovery/give-up logic was tested
against real subprocesses (not mocked): start/stop/restart with real PIDs,
a genuine crash-loop hitting the give-up threshold and then correctly
refusing further restarts, a single crash recovering normally, the crash
counter resetting after a stable run, and the real threaded watchdog
end-to-end. The update lifecycle integration was also re-verified against
the real Admin Panel over real HTTP: a working supervised process gets
genuinely restarted mid-update (confirmed via a changed PID) and reports
Successful; a process that can't stay up correctly fails the health check,
reports Failed, and leaves `app_version`/Last Known Good untouched.

## What's new in Part 4

- `agent/health_check.py` — a **real functional health check**, not just
  "is the process still alive":
  - `kiosk_health_check_url` set → GETs it; 2xx/3xx = healthy
  - `kiosk_health_check_command` set (and no URL) → runs it; exit 0 = healthy
  - neither set → falls back to process-liveness only, and the result
    message says so honestly rather than pretending it checked something it
    didn't
  - retries within a short budget (`health_check_retries` /
    `health_check_retry_delay_seconds`) so a freshly-restarted process
    isn't judged unhealthy just for needing a moment to come up
  - a structural check (files present on disk) still runs first and is
    **not** retried — a missing/empty `app_install_dir` is a hard failure
    no amount of waiting fixes
  - even a "healthy" HTTP/command response is distrusted if the configured
    `ProcessSupervisor` says the process it's supposedly checking isn't
    actually running
- `update_manager.py` now wires spec Section 29's full automatic-rollback
  flow for real: on a failed `health_check`, reports `rolling_back`, calls
  `agent.recovery.restore_recovery_point()` (Part 2's proven mechanism),
  restarts the configured supervisor onto the restored files, and
  **re-checks health on the restored version** before reporting
  `rolled_back` — a rollback that hasn't been verified healthy isn't
  reported as done. Two honest failure floors:
  - the restore itself can't run (e.g. no recovery point) → reports
    `failed` with a clear "manual intervention required" message
  - the restore runs but the restored version *also* fails its health
    check → reports `failed`, not a false `rolled_back` — this is the one
    outcome with no good automatic answer and it's surfaced, not papered
    over
- Status reporting to the Admin Panel is now wrapped (`_report_status_safe`)
  so a reporting failure — including the Admin Panel not yet recognizing
  `rolling_back`/`rolled_back` as valid statuses, which this Agent project
  can't verify from its own side — never blocks the actual local rollback
  action. The physical recovery happens regardless of whether the Admin
  Panel could be told about it.
- New settings: `kiosk_health_check_url`, `kiosk_health_check_command`,
  `health_check_timeout_seconds`, `health_check_retries`,
  `health_check_retry_delay_seconds`, `health_check_grace_period_seconds` —
  all optional, all with sensible defaults, so the Agent behaves exactly as
  Part 3 left it (structural + process-liveness only) if none are set.

### Testing note for Part 4 — read this one

Everything **local to this machine** is tested for real, no mocking:
`tests/test_health_check.py` (17 tests) drives a real background HTTP
server that's toggled healthy/unhealthy mid-test, real subprocesses for the
command-check path, and a real `ProcessSupervisor`.
`tests/test_rollback_integration.py` (4 tests) builds real update packages,
runs them through the real validator/installer/recovery-point machinery,
and supervises real subprocess "kiosk" stand-ins (tiny real HTTP servers)
that either serve 200, serve 500, or crash on startup — proving the full
`restarting → health_check → rolling_back → rolled_back` (or `failed`)
sequence end to end, including confirming via a real HTTP request that the
process actually answering after rollback is genuinely the restored
version.

**What's different from how Parts 1–3 were tested, stated plainly:** those
were integration-tested against the real Admin Panel checked out and
running as an actual HTTP server. This build environment does not have the
Admin Panel project available to run, so `tests/test_rollback_integration.py`
uses `_FakeAdminPanelClient`, a scripted stand-in that returns a fixed
deployment and records every `report_update_status()` call — it is not a
real server. That means the exact wire format the Admin Panel expects for
`rolling_back`/`rolled_back`, and whether it actually accepts those two new
status values, has **not** been verified against the real Admin Panel this
time. Worth a real end-to-end check against the actual Admin Panel before
this is trusted in production — flagged here rather than left implicit.

## What's honestly NOT done yet (updated for Part 4)

- **No mid-flight resume** — unchanged from Part 2: if the Agent restarts
  while a deployment is partway through, the poll loop logs that something's
  in progress and does nothing further with it. This now also applies to a
  deployment interrupted mid-*rollback* — a machine that loses power exactly
  between `rolling_back` and `rolled_back` needs a human to check its actual
  state on next boot.
- **`rolling_back`/`rolled_back` unverified against the real Admin Panel**
  — see the testing note above.
- Still no remote tunnel, still no installer script/MSI (Parts 5, 6).
- Windows service wrapper still unverified on real Windows (Part 3).

## What's new in Part 5 — installers

- `install/install.sh` / `install/uninstall.sh` — a real, tested Ubuntu/
  Debian installer (see spec Section 2.2's install-script line item):
  creates a dedicated unprivileged `opslab-agent` system user/group, lays
  down the Agent's own code + a fresh venv under `/opt/opslab-agent`, sets
  up `/etc/opslab-agent` (settings, downloads, recovery points) with
  restrictive permissions, installs the Part 3 systemd unit, and either
  writes an initial `settings.json` from `--admin-url`/
  `--registration-token` and starts the service, or installs everything
  short of starting it (to avoid crash-looping with nothing to register
  against) and prints exactly what to do next. Idempotent — safe to re-run
  as an upgrade, preserving `settings.json`.
  **Tested for real** in this build environment (this sandbox is Ubuntu
  24.04 with root access): full install → verify-as-service-user →
  re-install-as-upgrade → uninstall → purge cycles all actually run, plus
  the Agent genuinely registering against a real stand-in HTTP server while
  running as the unprivileged `opslab-agent` user exactly as systemd's
  `ExecStart` would invoke it. The one thing that could **not** be tested
  here: actual `systemctl enable/start` behavior, since this sandbox has no
  running systemd (no PID 1 systemd) — everything up to that boundary is
  proven; the `systemctl` calls themselves are standard usage.
- `install/windows/install.ps1` / `install/windows/uninstall.ps1` — the
  Windows counterpart. **Two honesty flags on this one, stated plainly in
  the script's own header too:**
  1. The build plan calls this "a Windows MSI-equivalent installer" — it's
     a PowerShell script, not a literal `.msi`. Building a real `.msi`
     needs the WiX Toolset on an actual Windows build chain, which doesn't
     exist in this Linux sandbox. This script does the same *work* a real
     installer would (venv, pywin32, service registration via the Part 3
     wrapper, crash-recovery via `sc.exe failure`) using tools that behave
     the same with or without Windows to run them on — it should get
     wrapped in (or replaced by) a real `.msi` once actual Windows CI
     exists.
  2. Unlike the Linux installer, this could not be execution-tested at
     all — this sandbox has no `pwsh`/PowerShell interpreter available (not
     installable from the allowed package sources either), so this was
     reviewed by hand rather than run. That review already caught and
     fixed two real bugs before they'd have hit a real machine: a project-
     root path computed one directory level too shallow (would have broken
     every file-copy step), and two string-concatenation expressions
     written without parentheses, which PowerShell's command-argument
     parser doesn't evaluate as concatenation the way it looks like it
     should. There's a real chance further issues like these exist that
     only surface at actual runtime — this needs a real Windows smoke test
     before production use, same as the Part 3 service wrapper it wraps.

## What's new in Part 6 — error reporting, remote tunnel stub, final polish

- `agent/error_reporter.py` — ships ERROR/CRITICAL log records to the
  Admin Panel (spec Section 2.2's error-reporting line item) from
  *anywhere* in the Agent, not just one module: it attaches to the `agent`
  logger, which every `agent.*` module's logger is a child of, so every
  existing `log.error()`/`log.exception()` call across the whole project —
  a failed health check, a crash-loop give-up, an install failure — starts
  flowing to the Admin Panel automatically, no per-module changes needed.
  Built deliberately defensive against three failure modes: recursion (a
  reporting failure that itself logs an error must not report itself
  forever — a re-entrancy guard handles this), storms (rate limiting +
  short-window deduplication so a genuinely broken machine logging the same
  failure hundreds of times a minute doesn't turn into hundreds of HTTP
  calls), and reporting itself never raising into the logging system.
  17 real tests (13 in `test_error_reporter.py` covering all three failure
  modes against a real `logging.Logger` hierarchy, plus a live check that a
  real exception actually reaches a real HTTP server over the wire).
- `agent/tunnel.py` — the remote-access tunnel client (spec Section 2.2),
  honestly scoped as a **stub**, exactly as the 6-part plan called it: the
  poll loop and status-reporting plumbing are real and tested (6 tests),
  but actual tunnel *establishment* is not implemented and says so in its
  own status report (`"unsupported"`) rather than silently doing nothing.
  Why: a working tunnel needs a broker on the Admin Panel side (something
  to terminate the reverse connection) that doesn't exist in that project —
  building a client against a broker that isn't there would mean guessing
  a protocol, which is worse than not building it. The one function that
  would need to change once a real broker exists
  (`tunnel._establish_tunnel()`) is isolated and clearly marked.
- Closed the forward reference left in Part 3's `process_supervisor.py`
  docstring ("`status()['giving_up']` flags this for something upstream to
  surface (Part 6's error reporting)"): `heartbeat.py` now includes the
  supervisor's full `status()` dict (running/pid/giving_up/
  restarts_in_window) in every heartbeat when a supervisor is configured,
  tested against a real crash-looping subprocess actually hitting
  `giving_up=True`.
- **Caught and fixed a real bug** while building the end-to-end test
  harness for this part: `main.py` called `signal.signal()`
  unconditionally, which raises `ValueError` when `run()` isn't executing
  on the main thread — which is exactly how the Part 3 Windows service
  wrapper calls it (`agent.main.run()` inside a worker thread, shutdown via
  `SvcStop()` setting an event rather than an OS signal). This would have
  crashed the Agent on every real Windows service start. Fixed: OS signal
  handlers are now only registered when running on the main thread;
  otherwise shutdown relies purely on `external_stop_event`, which the
  Windows wrapper already sets. Verified with a full in-process harness —
  real registration, heartbeat, config-poll, update-poll, and tunnel-poll
  threads all running together against a real (stand-in) HTTP server, then
  a clean shutdown with no signal errors, run from a non-main thread the
  same way the Windows wrapper does it.
- New settings: `tunnel_poll_interval_seconds`, `error_report_max_per_window`,
  `error_report_window_seconds`, `error_report_dedup_seconds` — all
  optional, all defaulted.

### Testing gap, still open — same caveat as Part 4, now covering more surface

The Admin Panel project itself has not been available to run in this build
environment since Part 4 (see that section's testing note). Part 6 adds two
more endpoints this affects: `POST /api/v1/instances/errors` and
`GET/POST /api/v1/instances/tunnel[/​<id>​/status]`. Both are exercised
against a scripted stand-in server (proving the Agent's own HTTP client
code, JSON shape, and error handling are correct), and the error-reporter
end-to-end check does hit a *real* HTTP server, just not the real Admin
Panel. Whether the actual Admin Panel recognizes these two endpoints (and
Part 4's `rolling_back`/`rolled_back` statuses) at all has still not been
verified against it. This is the single most important thing to check
before any of Parts 4–6 is trusted in production — everything else, this
project is confident in; this specific wire contract, it is not, and says
so rather than implying otherwise.

## What's in Part 1

- `agent/config.py` — settings.json load/save (atomic writes), with
  sensible default paths (`/etc/opslab-agent/settings.json` on Linux,
  `%ProgramData%\OpsLabAgent\settings.json` on Windows)
- `agent/system_info.py` — OS/hostname/local-IP detection (maps to the
  Admin Panel's `ubuntu`/`debian`/`windows` values)
- `agent/api_client.py` — thin wrapper over the Admin Panel's agent-facing
  `/api/v1` (register, heartbeat, config get/ack, plus stubs for Part 2's
  update endpoints so api_client.py won't need touching again)
- `agent/identity.py` — one-time registration: consumes an enrollment
  token from settings, gets back a permanent `instance_id`/`instance_secret`,
  persists them, and clears the now-spent token
- `agent/heartbeat.py` — periodic check-in loop
- `agent/config_manager.py` — the receive → validate → apply → confirm →
  report cycle from spec Section 11: polls for a pending config, writes it
  to `kiosk_config_path` as JSON, acks the result back to the Admin Panel
- `agent/main.py` — entrypoint wiring it all together, with a heartbeat
  thread and a config-poll thread running until SIGINT/SIGTERM

## Running it

### Production install (Linux)

```bash
sudo ./install/install.sh --admin-url https://admin.opslabsystems.cloud \
                           --registration-token <token from the Admin Panel's enrollment screen>
```

See `install/install.sh --help` and the Part 5 section above for details.
`install/uninstall.sh` reverses it (`--purge` also removes identity/recovery
data). Windows: `install/windows/install.ps1` / `uninstall.ps1` — see the
honesty flags on those in the Part 5 section above before relying on them.

### Running directly (development, or first run on a fresh machine)

```bash
export OPSLAB_ADMIN_URL=https://admin.opslabsystems.cloud
export OPSLAB_REGISTRATION_TOKEN=<token from the Admin Panel's enrollment token screen>
python -m agent.main
```

It registers once, saves `instance_id`/`instance_secret` to `settings.json`,
clears the token from disk, then starts heartbeating, polling for config,
checking for updates, polling for tunnel requests, and (if
`kiosk_start_command` is set) supervising the Kiosk Application — all
configurable, see `settings.example.json`. On every later run, just:

```bash
python -m agent.main
```

— no environment variables needed once `settings.json` has an identity.

## Current honest gaps (as of Part 6, the end of the 6-part plan)

- **`rolling_back`/`rolled_back`/error-reporting/tunnel endpoints unverified
  against the real Admin Panel** — this build environment hasn't had the
  Admin Panel project available to run since Part 4. See the Part 6 testing
  note above; this is the top thing to check before production use.
- **No mid-flight resume** if the Agent restarts partway through a
  deployment or a rollback.
- **Windows is untested on real Windows** — both `opslab_agent_service.py`
  (Part 3) and `install/windows/install.ps1`/`uninstall.ps1` (Part 5) are
  reviewed-but-unrun; this sandbox has never had a Windows machine or even
  a PowerShell interpreter available.
- **The Windows installer is a PowerShell script, not a literal `.msi`** —
  see Part 5 above for why, and what it would take to close that gap.
- **Remote tunnel establishment is a stub** — the request/status plumbing
  is real; actually opening a tunnel needs a broker that doesn't exist yet
  on the Admin Panel side. See Part 6 above.
- **`kiosk_config_path` has no reader and the Kiosk Application itself
  still doesn't exist** as a separate project — every part of this Agent
  that depends on it (config sync, process supervision, health checks) has
  been built and tested against generic stand-ins for exactly this reason,
  and works unmodified once a real Kiosk Application exists to point at.
  **Update:** a real, minimal OpsLab Kiosk Application now exists (separate
  project) and `tests/test_real_kiosk_integration.py` proves process
  supervision, health checks, config sync, and automatic rollback against
  it for real — see that test and `tests/fixtures/real_kiosk_app/README.md`.
  This closes the "no real Kiosk Application exists to test against"
  caveat specifically; it does not close the Admin Panel or Windows gaps
  above, which are unrelated and still open.

## Setup

```bash
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

Running the test suite (all real — no mocking of the Agent's own local
behavior; only the Admin Panel side is a lightweight stand-in, see the
Part 4/6 testing notes above for why):

```bash
python3 -m unittest discover -s tests -v
```

