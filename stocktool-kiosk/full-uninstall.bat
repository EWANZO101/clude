@echo off
setlocal
echo == StockTool Kiosk: full uninstall + wipe ==
echo.

:: Self-elevate if not already admin -- needed for service removal,
:: firewall rules, and %ProgramData% access.
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

echo [1/5] Stopping any running StockToolKiosk.exe...
taskkill /IM StockToolKiosk.exe /F >nul 2>&1

echo [2/5] Uninstalling the MSI package (if installed via MSI)...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$pkg = Get-Package -Name 'StockTool Kiosk*' -ErrorAction SilentlyContinue;" ^
  "if ($pkg) {" ^
  "  Write-Host ('    Found: ' + $pkg.Name + ' ' + $pkg.Version + ' -- uninstalling...');" ^
  "  $pkg | Uninstall-Package -Force -ErrorAction SilentlyContinue | Out-Null;" ^
  "  Write-Host '    Done.';" ^
  "} else {" ^
  "  Write-Host '    Not found via Get-Package (probably never installed through the .msi, or was removed already) -- skipping.';" ^
  "}"

echo [3/5] Stopping and removing the Windows service (safety net -- in case
echo       the MSI uninstall above didn't already do this, or the app was
echo       only ever run as the raw .exe without going through the .msi)...
sc.exe stop StockToolKioskAPI >nul 2>&1
sc.exe delete StockToolKioskAPI >nul 2>&1

echo [4/5] Removing the firewall rule (if Public/Tunnel mode was ever used)...
powershell -NoProfile -Command "Remove-NetFirewallRule -DisplayName 'StockTool Kiosk API' -ErrorAction SilentlyContinue" >nul 2>&1

echo [5/5] Wiping all local data (database, settings, licence key)...
if exist "%PROGRAMDATA%\StockToolKiosk" (
    rmdir /S /Q "%PROGRAMDATA%\StockToolKiosk"
    echo     Removed: %PROGRAMDATA%\StockToolKiosk
) else (
    echo     Nothing at %PROGRAMDATA%\StockToolKiosk -- already clean.
)
if exist "%USERPROFILE%\Documents\StockToolKiosk" (
    rmdir /S /Q "%USERPROFILE%\Documents\StockToolKiosk"
    echo     Removed: %USERPROFILE%\Documents\StockToolKiosk
) else (
    echo     Nothing at %USERPROFILE%\Documents\StockToolKiosk -- already clean.
)

echo.
echo == Done ==
echo.
echo NOTE: this does NOT delete C:\StockTool\kiosk-v2 itself (your source
echo code / venv / dist folder) -- only the installed service, MSI
echo registration, and the data it created elsewhere on the machine. If
echo you also want the project folder gone, delete it by hand:
echo   rmdir /S /Q C:\StockTool\kiosk-v2
echo.
echo NOTE: if the licence key was ever activated while logged in as a
echo DIFFERENT Windows user, that user's Documents\StockToolKiosk folder
echo is untouched by this script (Documents is per-user, and this only
echo ran as %USERNAME%).
echo.
pause
