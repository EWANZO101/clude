# Ownership

This repo hosts **three separate systems** plus one small tooling layer. They
share a working directory, but nothing else — none of them may import from
another, and a change to one must never be the way a change reaches another.
This file is the human-readable version of the rules `tests/test_app_boundaries.py`
enforces mechanically; if you're about to edit something and aren't sure
which bucket it's in, check here first.

| Path | System | Rule |
|---|---|---|
| `app/`, `migrations/`, root `run.py`, root `config.py` | **Admin Panel** | The fleet-management dashboard that's actually running (port 6090). Edits under here take effect **immediately** — the Flask debug reloader restarts the live process on every save. Never `import` anything from `kiosk_app/`. |
| `kiosk_app/` | **Kiosk App** | The actual application a kiosk operator uses (`LocalUser`, `Item`, `Tool`, `Project`, `WireSpool`, `StockAudit`, ...). A fully independent Flask project — its own `run.py`, `app/`, `requirements.txt`. Editing it has **no live effect anywhere**; it only reaches a real machine via **Releases → Build Kiosk Release → Push Update** (see `tools/build_kiosk_release.py`). Never `import` anything from the Admin Panel's `app/`. |
| `agent/`, `service_files/` | **Instance Agent** | The management daemon that runs on a kiosk machine to install/monitor/roll back the Kiosk App. Ships as a tarball via Dev Files → **Publish** (`app/blueprints/dev_files.py::publish()`), picked up by new enrollments immediately, existing machines on their next reinstall. Has its own tests in `tests/test_health_check.py` / `tests/test_rollback_integration.py`. |
| root `requirements.txt` | Admin Panel + Agent | What the running Admin Panel process and the shipped Agent need. **Not** used by the Kiosk App — see `kiosk_app/requirements.txt`. |
| `tools/` | Build tooling | `build_kiosk_release.py` deterministically zips `kiosk_app/` into a release — the only sanctioned way to produce one (manual upload in Releases still exists, but always goes through the same `app/update_validation.py` content-firewall checks either way). |
| `tests/` | All three | One `pytest` run covers all three systems' tests, plus the structural boundary checks in `test_app_boundaries.py`. |

## Why this exists

This repo used to just *be* the Kiosk App, and the Admin Panel was built on
top of it in place — at several shared file paths (`app/__init__.py`,
`app/models.py`, `app/blueprints/dashboard.py`, `app/blueprints/auth.py`,
`app/templates/base.html`, ...) the Admin Panel's content silently replaced
the Kiosk App's. Two real incidents came directly from that:

- The Admin Panel's nav grew a dead **"Inventory" dropdown** pointing at
  Kiosk-only routes that were never registered here — leftover from
  `base.html` being the old Kiosk App's template.
- **v1.0.2** (2026-09-08): a Kiosk release was uploaded that was actually a
  snapshot of the Admin Panel's own source tree. Nothing checked that a
  release's payload was the right application, so it sailed through
  validation and broke two real kiosk machines' health checks.

`kiosk_app/` now holds the real, complete, current Kiosk App source
(reconciled from the last known-good release plus the in-progress
barcode-rendering work that had been stranded under the Admin Panel's
`app/`). The Admin Panel no longer contains any Kiosk-only file. Going
forward:

- **A new script that pushes code changes** (in the spirit of the many
  historical `push_*.sh`/`fix_*.sh` one-off scripts at repo root — those are
  a changelog of already-applied past patches, not a live pipeline, and
  weren't rewritten as part of this pass) must target exactly one of the
  three systems above, never write across two of them in the same run, and
  never rewrite `app/static/installers/opslab-agent.tar.gz` directly — go
  through Dev Files → Publish instead so the artifact always matches
  `agent/`'s actual current source.
- **A new Kiosk release** should be built with `flask build-kiosk-release`
  or Releases → "Build Kiosk release from kiosk_app/" — not a hand-picked
  zip file — so it's structurally impossible for it to be the wrong
  application again.
- **Before adding a genuinely shared component** (something both the Admin
  Panel and the Kiosk App need), don't just drop it in `app/` — decide
  explicitly where it lives and which side imports/copies it, and say so
  here.
