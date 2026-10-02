<#
.SYNOPSIS
    StockTool Kiosk -- Start. Installed as the "Start StockTool Kiosk"
    Start Menu shortcut, so starting the background service again after
    a stop doesn't require services.msc or a command line.

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
        "StockTool Kiosk isn't installed as a service on this machine. " +
        "Run 'StockTool Kiosk Setup' from the Start Menu first.",
        "StockTool Kiosk",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    ) | Out-Null
    exit
}

if ($svc.Status -eq "Running") {
    [System.Windows.Forms.MessageBox]::Show(
        "StockTool Kiosk is already running.",
        "StockTool Kiosk",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
    exit
}

try {
    Start-Service -Name $ServiceName -ErrorAction Stop
    [System.Windows.Forms.MessageBox]::Show(
        "StockTool Kiosk has been started.",
        "StockTool Kiosk",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
} catch {
    [System.Windows.Forms.MessageBox]::Show(
        "Could not start StockTool Kiosk: $($_.Exception.Message)" +
        "`n`nCheck %ProgramData%\StockToolKiosk\service.log for details.",
        "StockTool Kiosk",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
}
