<#
.SYNOPSIS
    StockTool Kiosk -- Stop. Installed as the "Stop StockTool Kiosk"
    Start Menu shortcut, so stopping the background service doesn't
    require services.msc or a command line.

    NOTE ON ENCODING: plain ASCII on purpose -- see the same note at the
    top of SetupWizard.ps1.
#>
#Requires -Version 5.1

Add-Type -AssemblyName System.Windows.Forms

$ServiceName = "StockToolKioskAPI"

# -- Re-launch elevated if needed (starting/stopping a service needs admin) --
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList (
        "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    )
    exit
}

$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if (-not $svc) {
    [System.Windows.Forms.MessageBox]::Show(
        "StockTool Kiosk isn't installed as a service on this machine.",
        "StockTool Kiosk",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    ) | Out-Null
    exit
}

if ($svc.Status -eq "Stopped") {
    [System.Windows.Forms.MessageBox]::Show(
        "StockTool Kiosk is already stopped.",
        "StockTool Kiosk",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
    exit
}

try {
    Stop-Service -Name $ServiceName -Force -ErrorAction Stop
    [System.Windows.Forms.MessageBox]::Show(
        "StockTool Kiosk has been stopped. Nobody on this network can " +
        "reach the inventory API until it's started again.",
        "StockTool Kiosk",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
} catch {
    [System.Windows.Forms.MessageBox]::Show(
        "Could not stop StockTool Kiosk: $($_.Exception.Message)",
        "StockTool Kiosk",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
}
