<#
.SYNOPSIS
    OpsLab Instance Agent — Windows installer.

.DESCRIPTION
    HONEST NOTE ON WHAT THIS IS: the build plan calls this "a Windows
    MSI-equivalent installer". This is a PowerShell script, not a literal
    .msi. Building a real .msi needs the WiX Toolset running on an actual
    Windows (or Windows-hosted CI) build chain, which this build environment
    — a Linux sandbox with no Windows machine available (see
    service_files/windows/opslab_agent_service.py's own header, and Part 3's
    progress notes) — does not have and cannot fake convincingly. Rather
    than produce an untested, unverifiable .msi binary and imply it works,
    this script does everything a real installer needs to (install
    prerequisites into an isolated venv, lay down files, register a real
    Windows service via pywin32, configure failure recovery, start it) using
    tools that exist and behave the same with or without a Windows box to
    run them on. It should get wrapped in an actual .msi (or swapped for
    one) once real Windows CI is available — flagged here rather than
    silently presented as the real thing.

    ALSO UNTESTED ON REAL WINDOWS, same as opslab_agent_service.py itself:
    this script has been reviewed for correctness against standard
    PowerShell/pywin32 patterns but has not been run on an actual Windows
    machine. Needs a real smoke test before production use.

.PARAMETER AdminUrl
    The Admin Panel's base URL, e.g. https://admin.opslabsystems.cloud

.PARAMETER RegistrationToken
    A one-time enrollment token from the Admin Panel's enrollment screen.
    Both -AdminUrl and -RegistrationToken are optional — if omitted, the
    service is installed and registered to auto-start, but NOT started,
    to avoid crash-looping with nothing to register against (same reasoning
    as install.sh on Linux). Finish setup by writing settings.json by hand
    (see settings.example.json) and running: Start-Service OpsLabAgent

.EXAMPLE
    .\install.ps1 -AdminUrl "https://admin.opslabsystems.cloud" -RegistrationToken "abc123"
#>
[CmdletBinding()]
param(
    [string]$AdminUrl = "",
    [string]$RegistrationToken = ""
)

$ErrorActionPreference = "Stop"

$InstallDir = "$env:ProgramFiles\OpsLabAgent"
$DataDir    = "$env:ProgramData\OpsLabAgent"   # must match agent/config.py::default_data_dir on Windows
$ServiceName = "OpsLabAgent"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path      # .../instance_agent/install/windows
$InstallScriptsDir = Split-Path -Parent $ScriptDir                 # .../instance_agent/install
$ProjectRoot = Split-Path -Parent $InstallScriptsDir                # .../instance_agent
$ServiceWrapperSrc = Join-Path $ProjectRoot "service_files\windows\opslab_agent_service.py"

function Write-Log  { param([string]$Message) Write-Host "[opslab-agent-install] $Message" }
function Write-Warn2 { param([string]$Message) Write-Warning "[opslab-agent-install] $Message" }
function Die { param([string]$Message) Write-Error "[opslab-agent-install] ERROR: $Message"; exit 1 }

# --- preflight -------------------------------------------------------------
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent()
)
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Die "must be run from an elevated (Administrator) PowerShell prompt."
}

if (-not (Test-Path "$ProjectRoot\agent\main.py")) {
    Die ("expected to find agent\main.py next to this script's parent directory " +
         "($ProjectRoot) — run this from inside the extracted instance_agent project.")
}

$python = Get-Command python -ErrorAction SilentlyContinue
if (-not $python) { $python = Get-Command py -ErrorAction SilentlyContinue }
if (-not $python) {
    Die ("Python 3 was not found on PATH. Install Python 3 from https://python.org " +
         "(check 'Add python.exe to PATH' during setup) and re-run this installer. " +
         "This script does not attempt to silently install Python, since doing that " +
         "reliably and verifiably from a script is its own significant undertaking.")
}
$pythonExe = $python.Source

$existingService = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
$isUpgrade = $false
if (Test-Path "$DataDir\settings.json") {
    $isUpgrade = $true
    Write-Log "Existing installation detected at $DataDir — this will be an upgrade, settings.json is preserved."
}

if ($existingService) {
    Write-Log "Stopping existing $ServiceName service for upgrade..."
    Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
}

# --- 1. install directory / agent code --------------------------------------
Write-Log "Installing Agent code to $InstallDir..."
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
New-Item -ItemType Directory -Force -Path "$InstallDir\agent" | Out-Null

# Copy just what's needed to run: agent/ (minus __pycache__/tests, which
# don't belong in an installed runtime), requirements.txt, and the service
# wrapper itself.
Get-ChildItem -Path "$ProjectRoot\agent" -Recurse -File |
    Where-Object { $_.FullName -notmatch '__pycache__' } |
    ForEach-Object {
        $relative = $_.FullName.Substring("$ProjectRoot\agent\".Length)
        $dest = Join-Path "$InstallDir\agent" $relative
        New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
        Copy-Item -Path $_.FullName -Destination $dest -Force
    }
Copy-Item -Path "$ProjectRoot\requirements.txt" -Destination "$InstallDir\requirements.txt" -Force
if (-not (Test-Path $ServiceWrapperSrc)) {
    Die "expected to find the service wrapper at $ServiceWrapperSrc — is service_files\windows intact?"
}
Copy-Item -Path $ServiceWrapperSrc -Destination "$InstallDir\opslab_agent_service.py" -Force

# --- 2. virtualenv -----------------------------------------------------------
Write-Log "Creating/updating the Agent's virtualenv..."
& $pythonExe -m venv "$InstallDir\venv"
$venvPython = "$InstallDir\venv\Scripts\python.exe"
& $venvPython -m pip install --quiet --upgrade pip
& $venvPython -m pip install --quiet -r "$InstallDir\requirements.txt"
& $venvPython -m pip install --quiet pywin32

# pywin32's post-install step registers some COM/registry bits that the
# plain pip install doesn't always do on its own. Best-effort: some pywin32
# versions/environments don't need or ship this script under that exact
# path, so a failure here is logged, not fatal — win32serviceutil has
# worked without it in many setups, but this is the standard place to look
# first if service install/start fails.
$postInstall = Get-ChildItem -Path "$InstallDir\venv" -Recurse -Filter "pywin32_postinstall.py" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($postInstall) {
    Write-Log "Running pywin32 post-install step..."
    try {
        & $venvPython $postInstall.FullName -install | Out-Null
    } catch {
        Write-Warn2 "pywin32 post-install step failed (continuing): $_"
    }
} else {
    Write-Warn2 ("pywin32_postinstall.py not found in the venv — if service install/start " +
                 "fails below, this is the first thing to check by hand.")
}

# --- 3. data directory (settings, downloads, recovery points) ---------------
Write-Log "Setting up $DataDir..."
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
# Restrict to Administrators + SYSTEM (the service runs as LocalSystem by
# default) — settings.json holds the instance's secret credential. Using
# the well-known names rather than raw SIDs here deliberately — simpler to
# get right without a real Windows box to verify SID string syntax on.
icacls $DataDir /inheritance:r | Out-Null
icacls $DataDir /grant "SYSTEM:(OI)(CI)F" | Out-Null
icacls $DataDir /grant "Administrators:(OI)(CI)F" | Out-Null

$canStart = $false
if (Test-Path "$DataDir\settings.json") {
    $canStart = $true  # already configured — leave settings.json alone
} elseif ($AdminUrl -and $RegistrationToken) {
    Write-Log "Writing initial settings.json with the provided admin URL and enrollment token..."
    $settings = @{
        admin_url          = $AdminUrl
        registration_token = $RegistrationToken
    } | ConvertTo-Json
    Set-Content -Path "$DataDir\settings.json" -Value $settings -Encoding UTF8
    $canStart = $true
} else {
    Write-Warn2 "No settings.json exists yet and -AdminUrl/-RegistrationToken were not both given."
    Write-Warn2 "The service will be installed and set to auto-start, but NOT started now, to avoid"
    Write-Warn2 "crash-looping with no way to register. Finish setup with either:"
    Write-Warn2 "  .\install.ps1 -AdminUrl <url> -RegistrationToken <token>"
    Write-Warn2 "or by writing $DataDir\settings.json by hand (see settings.example.json), then:"
    Write-Warn2 "  Start-Service $ServiceName"
}

# --- 4. Windows service -------------------------------------------------------
Write-Log "Registering the Windows service..."
if ($existingService) {
    & $venvPython "$InstallDir\opslab_agent_service.py" remove | Out-Null
}
& $venvPython "$InstallDir\opslab_agent_service.py" --startup=auto install
if ($LASTEXITCODE -ne 0) {
    Die ("service install failed (exit $LASTEXITCODE) — see output above. " +
         "Common cause: pywin32 not fully registered, see the post-install step above.")
}

# Failure recovery — the Windows-service equivalent of systemd's
# Restart=always (spec Section 52's "Instance Agent crashes -> OS service
# manager restarts it"): restart 5s after 1st/2nd/3rd+ crash, reset the
# failure count after a day of stability.
Write-Log "Configuring automatic restart on crash..."
& sc.exe failure $ServiceName reset= 86400 actions= restart/5000/restart/5000/restart/5000 | Out-Null

if ($canStart) {
    Write-Log "Starting $ServiceName service..."
    Start-Service -Name $ServiceName
    Write-Log "$ServiceName service started."
    Write-Log "Check status with: Get-Service $ServiceName"
    Write-Log "Check logs with:   Get-EventLog -LogName Application -Source $ServiceName -Newest 20"
} else {
    Write-Log "$ServiceName service installed (not started — see warnings above)."
}

if ($isUpgrade) {
    Write-Log "Upgrade complete."
} else {
    Write-Log "Install complete."
}
