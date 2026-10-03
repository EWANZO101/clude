# Fixture: a real snapshot of the OpsLab Kiosk Application

This is a copy of `kiosk/` from the (separate) OpsLab Kiosk Application
project, snapshotted here so `tests/test_real_kiosk_integration.py` is
self-contained and doesn't depend on a sibling project directory that
would only exist in the original build sandbox.

This is real, working application source — not a synthetic test double.
The integration test builds real update packages from this exact code
(a genuinely working v1.0.0, and a v1.1.0 with a real injected regression
to exercise automatic rollback), installs them with the real
`agent/installer.py`, and supervises/health-checks them with the real
`agent/process_supervisor.py` and `agent/health_check.py` — proving those
modules against an actual Kiosk Application for the first time, rather
than against generic stand-ins.

If the Kiosk Application project's `kiosk/` package changes, re-sync this
copy (`cp -r ../../../kiosk_app/kiosk tests/fixtures/real_kiosk_app/`) so
the integration test keeps exercising real, current application code.
