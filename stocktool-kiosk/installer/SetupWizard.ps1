<#
.SYNOPSIS
    StockTool Kiosk Setup Wizard.

.DESCRIPTION
    Installed alongside StockToolKiosk.exe by the MSI. Registers/updates
    the "StockToolKioskAPI" Windows service (via the bundled NSSM), lets
    an admin choose the bind mode (local / tunnel / public - see
    app/settings.py for what each means), and can be re-run any time from
    the "StockTool Kiosk Setup" Start Menu shortcut without reinstalling.

    Two ways to run:
      - Interactively (double-click the Start Menu shortcut): prompts for
        the bind mode and any mode-specific values, then registers/
        restarts the service.
      - `-Silent`: no prompts, uses whatever is already in settings.json
        (or the defaults, if this is a first run) - this is what
        main.py's `_register_service_silently()` calls automatically
        right after `--pair`/`--provision` succeed, and what
        Product.wxs's silent-install custom action calls for a fully
        unattended MSI install.

    Requires an elevated (Administrator) PowerShell session - service
    registration and writing to %ProgramData% both need it.

.PARAMETER Silent
    Skip all prompts. Uses the bind mode already in settings.json if
    present, else "local".

.PARAMETER BindMode
    Optional - pre-selects local/tunnel/public without prompting even in
    interactive mode. Combine with -Silent for a fully scripted install.

.PARAMETER TunnelToken
    Cloudflare Tunnel token - only used when BindMode is "tunnel".
#>
param(
    [switch]$Silent,
    [ValidateSet("local", "tunnel", "public")]
    [string]$BindMode,
    [string]$TunnelToken
)

$ErrorActionPreference = "Stop"

$InstallDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$ExePath      = Join-Path $InstallDir "StockToolKiosk.exe"
$NssmPath     = Join-Path $InstallDir "nssm.exe"
$ServiceName  = "StockToolKioskAPI"
$DataDir      = Join-Path $env:PROGRAMDATA "StockToolKiosk"
$SettingsPath = Join-Path $DataDir "settings.json"

function Write-Info($msg)  { Write-Host $msg -ForegroundColor Cyan }
function Write-Ok($msg)    { Write-Host $msg -ForegroundColor Green }
function Write-Warn2($msg) { Write-Host $msg -ForegroundColor Yellow }
function Write-Err2($msg)  { Write-Host $msg -ForegroundColor Red }

function Assert-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Err2 "This must be run as Administrator (service registration and %ProgramData% both need it)."
        Write-Err2 "Right-click 'StockTool Kiosk Setup' and choose 'Run as administrator'."
        exit 1
    }
}

function Get-CurrentSettings {
    if (Test-Path $SettingsPath) {
        try { return (Get-Content $SettingsPath -Raw | ConvertFrom-Json) } catch { }
    }
    return [PSCustomObject]@{ bind_mode = "local"; port = 8420; cloudflare_tunnel_hostname = $null }
}

function Set-BindMode([string]$Mode, [string]$Token) {
    # Mirrors app/settings.py's save_settings() shape/atomic-write pattern
    # so the Python side reads back exactly what this wrote, whichever
    # process touches settings.json next.
    New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
    $settings = Get-CurrentSettings
    $settings | Add-Member -NotePropertyName bind_mode -NotePropertyValue $Mode -Force
    if ($Mode -eq "tunnel" -and $Token) {
        $settings | Add-Member -NotePropertyName cloudflare_tunnel_token -NotePropertyValue $Token -Force
    }
    $tmp = "$SettingsPath.tmp"
    $settings | ConvertTo-Json -Depth 5 | Set-Content -Path $tmp -Encoding UTF8
    Move-Item -Force $tmp $SettingsPath
    Write-Ok "Bind mode set to '$Mode'."
}

function Register-ApiService {
    <#
        Registers StockToolKiosk.exe --service as a Windows service using
        NSSM (bundled next to this script by the MSI - see Product.wxs).
        Safe to call repeatedly: if the service already exists, this
        updates its target/args and restarts it rather than failing.
    #>
    if (-not (Test-Path $NssmPath)) {
        Write-Err2 "nssm.exe not found at $NssmPath - the install is incomplete."
        exit 1
    }
    if (-not (Test-Path $ExePath)) {
        Write-Err2 "StockToolKiosk.exe not found at $ExePath - the install is incomplete."
        exit 1
    }

    $existing = & $NssmPath status $ServiceName 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Info "Service '$ServiceName' already exists - stopping to reconfigure..."
        & $NssmPath stop $ServiceName | Out-Null
        & $NssmPath set $ServiceName Application $ExePath | Out-Null
        & $NssmPath set $ServiceName AppParameters "--service" | Out-Null
    } else {
        Write-Info "Installing service '$ServiceName'..."
        & $NssmPath install $ServiceName $ExePath "--service"
    }

    # LocalSystem so the service works identically regardless of who's
    # logged in (or isn't) - matches license.py's %ProgramData% choice
    # for exactly the same reason.
    & $NssmPath set $ServiceName Start SERVICE_AUTO_START | Out-Null
    & $NssmPath set $ServiceName AppDirectory $InstallDir | Out-Null
    & $NssmPath set $ServiceName AppStdout (Join-Path $DataDir "service-stdout.log") | Out-Null
    & $NssmPath set $ServiceName AppStderr (Join-Path $DataDir "service-stderr.log") | Out-Null
    & $NssmPath set $ServiceName AppRotateFiles 1 | Out-Null
    & $NssmPath set $ServiceName AppRotateBytes 5242880 | Out-Null
    # Restart automatically if it exits unexpectedly, on top of the
    # in-process Supervisor's own restart loop (server_supervisor.py)  - 
    # belt and braces against the whole process dying, not just the
    # embedded server thread inside it.
    & $NssmPath set $ServiceName AppExit Default Restart | Out-Null
    & $NssmPath set $ServiceName AppRestartDelay 3000 | Out-Null

    New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
    & $NssmPath start $ServiceName | Out-Null

    Start-Sleep -Seconds 2
    $status = & $NssmPath status $ServiceName
    if ($status -match "SERVICE_RUNNING") {
        Write-Ok "Service '$ServiceName' is running."
    } else {
        Write-Warn2 "Service status: $status - check $DataDir\service.log / service-stderr.log if the kiosk doesn't come up."
    }
}

function Set-ShortcutRunAsAdmin([string]$LnkPath) {
    <#
        Flips the "Run as administrator" compatibility flag directly in
        the saved .lnk file (byte offset 0x15, bit 0x20 of the header) --
        the same flag Explorer sets when a user manually right-clicks a
        shortcut and checks that box under Properties > Advanced. This
        makes double-clicking the shortcut trigger the UAC prompt
        automatically every time, rather than silently failing (as
        Start-Service/Stop-Service/this script's own service
        registration all do without elevation) and leaving the user to
        discover they needed to right-click "Run as administrator"
        themselves -- see main.py's _register_service_silently(), whose
        warning message used to be the only way anyone found this out.
    #>
    $bytes = [System.IO.File]::ReadAllBytes($LnkPath)
    $bytes[0x15] = $bytes[0x15] -bor 0x20
    [System.IO.File]::WriteAllBytes($LnkPath, $bytes)
}

function New-Shortcuts {
    $startMenu = Join-Path ([Environment]::GetFolderPath("CommonPrograms")) "StockTool Kiosk"
    New-Item -ItemType Directory -Force -Path $startMenu | Out-Null
    $shell = New-Object -ComObject WScript.Shell

    $open = $shell.CreateShortcut((Join-Path $startMenu "StockTool Kiosk.lnk"))
    $open.TargetPath = $ExePath
    $open.WorkingDirectory = $InstallDir
    $open.Description = "Open the StockTool Kiosk screen"
    $open.Save()

    $setupLnkPath = Join-Path $startMenu "StockTool Kiosk Setup.lnk"
    $setup = $shell.CreateShortcut($setupLnkPath)
    $setup.TargetPath = "powershell.exe"
    $setup.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`""
    $setup.WorkingDirectory = $InstallDir
    $setup.Description = "Reconfigure StockTool Kiosk (bind mode, service)"
    $setup.Save()
    Set-ShortcutRunAsAdmin $setupLnkPath

    $startLnkPath = Join-Path $startMenu "Start StockTool Kiosk.lnk"
    $start = $shell.CreateShortcut($startLnkPath)
    $start.TargetPath = "powershell.exe"
    $start.Arguments = "-NoProfile -Command `"Start-Service '$ServiceName'`""
    $start.Save()
    Set-ShortcutRunAsAdmin $startLnkPath

    $stopLnkPath = Join-Path $startMenu "Stop StockTool Kiosk.lnk"
    $stop = $shell.CreateShortcut($stopLnkPath)
    $stop.TargetPath = "powershell.exe"
    $stop.Arguments = "-NoProfile -Command `"Stop-Service '$ServiceName'`""
    $stop.Save()
    Set-ShortcutRunAsAdmin $stopLnkPath

    Write-Ok "Start Menu shortcuts created under 'StockTool Kiosk'."
}

# -- Main -----------------------------------------------------------------

Assert-Admin

if (-not $Silent -and -not $BindMode) {
    Write-Host ""
    Write-Host "=== StockTool Kiosk Setup ===" -ForegroundColor Magenta
    Write-Host ""
    Write-Host "How should this kiosk be reachable?"
    Write-Host "  1) Local only (default, safest - only this machine)"
    Write-Host "  2) Tunnel (Cloudflare Tunnel - needs a tunnel token)"
    Write-Host "  3) Public (binds 0.0.0.0 - only for trusted/isolated networks)"
    $choice = Read-Host "Choice [1]"
    switch ($choice) {
        "2" { $BindMode = "tunnel" }
        "3" { $BindMode = "public" }
        default { $BindMode = "local" }
    }
    if ($BindMode -eq "tunnel" -and -not $TunnelToken) {
        $TunnelToken = Read-Host "Cloudflare Tunnel token (from the Cloudflare dashboard)"
    }
    if ($BindMode -ne "local") {
        Write-Warn2 "NOTE: /api/auth/login and most inventory endpoints have no auth beyond a badge code."
        Write-Warn2 "'$BindMode' mode exposes that to whoever can reach this machine's hostname/IP. See app/settings.py."
    }
}

if (-not $BindMode) {
    $current = Get-CurrentSettings
    $BindMode = if ($current.bind_mode) { $current.bind_mode } else { "local" }
}

Set-BindMode -Mode $BindMode -Token $TunnelToken
Register-ApiService
New-Shortcuts

Write-Host ""
Write-Ok "Setup complete. StockTool Kiosk is running at http://127.0.0.1:8420/ui/"
if (-not $Silent) {
    Write-Host "Press Enter to close..."
    Read-Host | Out-Null
}
