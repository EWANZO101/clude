<#
.SYNOPSIS
    OpsLab Instance Agent — Windows uninstaller. Counterpart to install.ps1.

.DESCRIPTION
    Same "untested on real Windows, and this build environment couldn't
    even run a PowerShell interpreter to check the syntax" caveat as
    install.ps1 — see that script's header for the full explanation.

    By default PRESERVES C:\ProgramData\OpsLabAgent (settings.json — the
    instance's identity/secret — plus downloads and recovery points), same
    reasoning as uninstall.sh on Linux: a machine can be reinstalled onto
    without losing its registration or Last-Known-Good rollback history.
    Pass -Purge to remove that too (irreversible — re-enrollment needed).

.PARAMETER Purge
    Also remove C:\ProgramData\OpsLabAgent (identity + recovery points).

.EXAMPLE
    .\uninstall.ps1
.EXAMPLE
    .\uninstall.ps1 -Purge
#>
[CmdletBinding()]
param(
    [switch]$Purge
)

$InstallDir  = "$env:ProgramFiles\OpsLabAgent"
$DataDir     = "$env:ProgramData\OpsLabAgent"
$ServiceName = "OpsLabAgent"

function Write-Log { param([string]$Message) Write-Host "[opslab-agent-uninstall] $Message" }

$currentPrincipal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent()
)
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "[opslab-agent-uninstall] ERROR: must be run from an elevated (Administrator) PowerShell prompt."
    exit 1
}

$service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($service) {
    Write-Log "Stopping $ServiceName service..."
    Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue

    $venvPython = "$InstallDir\venv\Scripts\python.exe"
    if (Test-Path $venvPython) {
        Write-Log "Removing $ServiceName service registration..."
        & $venvPython "$InstallDir\opslab_agent_service.py" remove | Out-Null
    } else {
        # venv is already gone (e.g. a prior partial uninstall) — fall back
        # to sc.exe, which only needs the service to exist in the registry,
        # not the Python that originally registered it.
        Write-Log "venv not found — removing service registration via sc.exe instead..."
        & sc.exe delete $ServiceName | Out-Null
    }
}

if (Test-Path $InstallDir) {
    Write-Log "Removing Agent code at $InstallDir..."
    Remove-Item -Path $InstallDir -Recurse -Force
}

if ($Purge) {
    if (Test-Path $DataDir) {
        Write-Log "Purging $DataDir (settings, downloads, recovery points)..."
        Remove-Item -Path $DataDir -Recurse -Force
    }
} else {
    Write-Log "Leaving $DataDir in place (identity, recovery points). Re-run with -Purge to remove it too."
}

Write-Log "Uninstall complete."
