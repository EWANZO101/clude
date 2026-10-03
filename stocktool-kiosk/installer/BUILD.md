# Building a new StockTool Kiosk release (.exe / .msi)

This produces the offline Windows kiosk app — separate from the
browser-based kiosk in `stocktool-api`/`stocktool-admin` (that one just
needs a server restart, no build step).

## What's here

| File | Purpose |
|---|---|
| `build.spec` | PyInstaller spec — builds `dist\StockToolKiosk.exe` (onefile) |
| `installer/Product.wxs` | WiX Toolset v3 MSI definition |
| `installer/SetupWizard.ps1` | Registers the Windows service (via NSSM), lets an admin pick local/tunnel/public exposure, creates Start Menu shortcuts |
| `build.ps1` | Runs all of the above in order, on Windows |
| `scripts/publish_release.py` | Announces a built exe to `stocktool-api` so paired kiosks self-update |

## Requirements (Windows build machine only)

- Python 3.11+ with `pyinstaller` (already in `requirements.txt`)
- [WiX Toolset](https://wixtoolset.org/) — the modern `wix.exe` CLI
  (v4/v5/v6+; whatever `wix.exe --version` reports). `Product.wxs` is
  authored for that CLI's schema, **not** the old v3 `candle.exe`/
  `light.exe` pair — if you only have WiX v3 installed, install the
  current CLI instead: `dotnet tool install --global wix`.
- [NSSM](https://nssm.cc/download) — win64 build, any location; pass its
  path to `build.ps1`

This cannot be built on Linux/macOS: PyInstaller only builds for the
platform it runs on, and WiX is Windows-only.

## One-time setup

1. Install the WiX CLI: `dotnet tool install --global wix` (needs the
   .NET SDK). Confirm with `wix.exe --version`.
2. `build.ps1` auto-installs the one required extension
   (`WixToolset.UI.wixext`) the first time it runs if it's missing — no
   separate step needed.
3. Download NSSM, note the path to `nssm.exe`.
4. (Optional) Drop a real `installer\icon.ico` in — falls back to
   PyInstaller's default icon if missing.

## Build

```powershell
cd backup22
.\build.ps1 -Version 2.2.0 -NssmPath C:\tools\nssm.exe -Verify
```

Leave off `-Version` to build the current `version.py` version as-is
(useful for a local test build without bumping anything). `-Verify`
launches the freshly built exe afterward and confirms it actually serves
the kiosk UI (checks for known page markers) before declaring success —
worth including on any build you're about to ship.

Output:
```
dist\StockToolKiosk.exe
dist\checksums.txt
installer\StockToolKiosk.msi
```

## Publish the update (this is the "online update" part)

Every kiosk already paired with StockTool Setup checks
`/api/updates/latest` on its own sync cycle (30s+ interval), downloads a
newer release, verifies its SHA-256, and self-applies with an automatic
rollback if the new build fails to boot. **You don't push anything to
kiosks directly** — you publish a release record, and they pull it
themselves next time they check in.

1. Host `dist\StockToolKiosk.exe` somewhere reachable by every kiosk
   (your own static file server, S3/R2, a GitHub release asset — this
   repo doesn't do the hosting for you).
2. Publish it:

```powershell
.\build.ps1 -Version 2.2.0 -NssmPath C:\tools\nssm.exe -Publish `
    -ApiBase https://api.opslabsystems.cloud `
    -AdminUser admin -AdminPass "..." `
    -DownloadUrl https://cdn.opslabsystems.cloud/StockToolKiosk.exe
```

or, if you already built the exe separately and just want to publish it:

```powershell
python scripts\publish_release.py `
    --api-base https://api.opslabsystems.cloud `
    --username admin --password "..." `
    --version 2.2.0 --exe-path dist\StockToolKiosk.exe `
    --download-url https://cdn.opslabsystems.cloud/StockToolKiosk.exe `
    --release-notes "Whatever changed"
```

Kiosks show a countdown warning before applying (see
`app/update_notifier.py`), so nobody mid-scan gets yanked out from under
themselves — it applies ~60s after being verified, not instantly.

## Installing fresh (new machine)

Two ways to hand someone `StockToolKiosk.msi`:

- **Plain download**: `msiexec /i StockToolKiosk.msi` (or just
  double-click it). At the end, a checkbox offers to pair the kiosk right
  away — that launches `StockToolKiosk.exe --pair`, which prompts for a
  setup code from `stocktoolsetup.opslabsystems.cloud` and registers the
  Windows service on success.
- **Personalized / silent** (account details already decided on the
  website via its `/provision` route): build the MSI the same way, then
  install with the provisioning properties set —
  ```
  msiexec /i StockToolKiosk.msi /quiet PROVISION_TOKEN=... PROVISION_USERNAME=... PROVISION_BADGECODE=...
  ```
  This runs `--provision` and registers the service automatically, no
  prompts at all.

## A bug fixed while building this tooling

`updater.py`'s `confirm_or_rollback()` — the safety net that verifies a
self-applied update actually boots, and rolls back to the previous build
if it doesn't — was fully implemented but **never called anywhere** in
`main.py`. Fixed: it's now the first thing `main()` does. Without this,
a self-update that produced a broken build would have replaced a working
kiosk with a non-booting one, with no automatic recovery.

## Known gaps (not built here — flagging rather than guessing)

- `installer/icon.ico` and `installer/nssm.exe` aren't included (a real
  icon file and NSSM's binary — see NSSM's license note in `Product.wxs`
  for why it's not redistributed here).
- None of the WiX/PowerShell has been run through an actual `wix.exe`/
  NSSM toolchain in this environment (Linux, no WiX available) — I
  validated `Product.wxs` as well-formed XML against the v4/v5 schema
  and parsed both PowerShell scripts with a real PowerShell 7 parser
  (zero syntax errors), but a first real build should be treated as a
  test build, not assumed production-ready. Use `-Verify` on that first
  build.
- The self-update **client** side (`updater.py`, `sync_loop.py`,
  `app/update_notifier.py`) and the **server** side
  (`/api/updates`, `ReleaseVersion`) already existed and needed no new
  code — only `publish_release.py` (a convenience wrapper around the
  existing `POST /api/updates`) and the `confirm_or_rollback` wiring
  above were added.

## Why this dropped WiX v3 (candle/light)

An earlier version of this tooling targeted WiX v3's `candle.exe`/
`light.exe`. If your build machine only has the modern `wix.exe` CLI
installed (v4/v5/v6+), that old `Product.wxs` would only build after
extensive runtime patching — different root element (`<Product>` vs
`<Package>`), different XML namespace, no more `Win64="yes"` on
components, `<UIRef>` replaced by `<ui:WixUI>`, `<Directory
Id="TARGETDIR">` boilerplate replaced by `<StandardDirectory>`, and
more. Rather than regex-patch a v3 file into looking like v4 XML at
build time (fragile, and any future edit to `Product.wxs` would need
patching all over again), `Product.wxs` and `build.ps1` here are
authored natively for the modern CLI. If you specifically need to build
with WiX v3, you'd want a separate `candle`/`light`-targeted `.wxs` —
ask and I'll produce one, rather than trying to make one file serve
both toolchains.
