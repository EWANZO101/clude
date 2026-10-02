<#
.SYNOPSIS
    Runs during MSI uninstall (not on upgrades) to tear down everything
    SetupWizard.ps1 created: the StockToolKioskAPI service, the
    Cloudflared tunnel service (if installed), the Windows Firewall
    rule (if Public mode was ever used), AND all local data.

.NOTES
    CHANGED from the original behavior: this used to deliberately SKIP
    deleting %ProgramData%\StockToolKiosk (the SQLite DB, settings.json,
    and the license cache) specifically to avoid silently destroying
    inventory data on uninstall. That protection is now removed, on
    explicit request: uninstalling is meant to leave nothing behind,
    including the database, settings, and the licence key file in
    Documents. If that's ever not what's wanted for a given uninstall
    (e.g. reinstalling on the same machine without losing history),
    back up %ProgramData%\StockToolKiosk and the Documents\StockToolKiosk
    folder BEFORE uninstalling -- there's no undo once this runs.
#>
$InstallDir = $PSScriptRoot
$NssmPath = Join-Path $InstallDir "nssm.exe"
$CloudflaredPath = Join-Path $InstallDir "cloudflared.exe"
$ServiceName = "StockToolKioskAPI"

try {
    if (Test-Path $NssmPath) {
        & $NssmPath stop $ServiceName confirm 2>$null | Out-Null
        & $NssmPath remove $ServiceName confirm 2>$null | Out-Null
    } else {
        # NSSM wasn't found on disk (e.g. wizard never ran) — still try
        # to stop/delete the service if it exists, via sc.exe.
        sc.exe stop $ServiceName 2>$null | Out-Null
        sc.exe delete $ServiceName 2>$null | Out-Null
    }
} catch {}

try {
    if (Test-Path $CloudflaredPath) {
        & $CloudflaredPath service uninstall 2>$null | Out-Null
    }
} catch {}

try {
    Remove-NetFirewallRule -DisplayName "StockTool Kiosk API" -ErrorAction SilentlyContinue
} catch {}

# ── Wipe all local data -- DB, settings, license key/cache ──────────
# %ProgramData% is machine-wide, not per-user, so this runs once
# regardless of which account is doing the uninstall.
try {
    $ProgramDataDir = Join-Path $env:PROGRAMDATA "StockToolKiosk"
    if (Test-Path $ProgramDataDir) {
        Remove-Item -Path $ProgramDataDir -Recurse -Force -ErrorAction SilentlyContinue
    }
} catch {}

# The licence key file lives in the CURRENT USER's Documents folder
# (see license.py's _documents_dir()). An MSI uninstall runs as the
# user performing the uninstall, so this only reaches that one
# account's copy -- if the kiosk was ever activated while logged in
# as a different Windows user, that other account's license file is
# untouched by this (a limitation of per-user Documents, not a bug
# here: there's no single machine-wide "the" Documents folder to
# clean on a multi-user box).
try {
    $DocsLicenseDir = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "StockToolKiosk"
    if (Test-Path $DocsLicenseDir) {
        Remove-Item -Path $DocsLicenseDir -Recurse -Force -ErrorAction SilentlyContinue
    }
} catch {}
