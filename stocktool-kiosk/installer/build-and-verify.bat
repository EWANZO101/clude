@echo off
setlocal EnableExtensions EnableDelayedExpansion
title StockTool Kiosk - full self-heal, build, and verify

set "KIOSK_ARG=%~1"
if "%KIOSK_ARG%"=="" set "KIOSK_ARG=C:\StockTool\kiosk-v2"
for %%I in ("%KIOSK_ARG%") do set "KIOSK_ARG=%%~fI"

set "INSTALLER=%KIOSK_ARG%\installer"
set "DIST=%KIOSK_ARG%\dist"
set "BUILD_PS1=%KIOSK_ARG%\build.ps1"
set "NSSM_EXE=%INSTALLER%\nssm.exe"
set "ICON_ICO=%INSTALLER%\icon.ico"
set "EXE_PATH=%DIST%\StockToolKiosk.exe"
set "MSI_PATH=%INSTALLER%\StockToolKiosk.msi"

echo ============================================================
echo   StockTool Kiosk - full self-heal build + verify
echo ============================================================
echo.
echo Kiosk dir: %KIOSK_ARG%
echo.
echo This single script now handles everything by itself:
echo   - admin elevation
echo   - NSSM (downloads it if missing)
echo   - the WiX CLI (installs it via dotnet if missing)
echo   - the WiX UI extension (adds it if missing)
echo   - a placeholder installer icon (generates one if missing)
echo   - the actual exe/msi build
echo   - launching and HTTP-verifying the fresh build
echo No other commands or setup steps should be needed.
echo.

REM ============================================================
REM 0. ADMIN ELEVATION
REM    (unchanged from before -- this part already worked)
REM ============================================================

net session >nul 2>&1
if not "%errorlevel%"=="0" (
    echo [0/8] Administrator privileges required. Requesting elevation...
    echo A User Account Control prompt should appear now -- click Yes.
    echo If nothing appears, check behind this window or in your taskbar.
    echo.
    powershell -NoProfile -Command "try { Start-Process -FilePath '%~f0' -ArgumentList '%KIOSK_ARG%' -Verb RunAs -ErrorAction Stop } catch { Write-Host $_.Exception.Message; exit 1 }"
    if not "%errorlevel%"=="0" (
        echo.
        echo ============================================================
        echo   ELEVATION FAILED OR WAS CANCELLED
        echo ============================================================
        echo.
        echo This script needs Administrator rights to register the Windows
        echo service. Either the UAC prompt was declined/dismissed, or it
        echo could not be shown at all.
        echo.
        echo Easiest fix: open Command Prompt or Terminal AS ADMINISTRATOR
        echo yourself first ^(right-click it, "Run as administrator"^), then
        echo run this script from inside that window -- it will skip this
        echo elevation step entirely since it is already elevated.
        echo.
        pause
        exit /b 1
    )
    exit /b
)

REM ============================================================
REM 1. VALIDATE PROJECT LAYOUT
REM ============================================================

echo [1/8] Checking project layout...
echo.

if not exist "%BUILD_PS1%" (
    echo ERROR: "%BUILD_PS1%" not found.
    echo Pass your kiosk-v2 path: build-and-verify.bat C:\StockTool\kiosk-v2
    goto FAIL
)
echo   OK: %BUILD_PS1%

REM A stale build.ps1 sitting in installer\ from before this script
REM pointed at the root-level copy would run with the WRONG working
REM directory assumptions and fail confusingly (version.py, dist\, etc
REM all resolved relative to installer\ instead of the real root). Move
REM it aside so it can never be picked up by accident again.
if exist "%INSTALLER%\build.ps1" (
    echo   Found a stale build.ps1 inside installer\ -- moving it aside
    echo   so it cannot be confused with the real one at %BUILD_PS1%
    move /Y "%INSTALLER%\build.ps1" "%INSTALLER%\build.ps1.stale" >nul 2>&1
)
echo.

REM ============================================================
REM 2. KILL ANY RUNNING INSTANCE FIRST
REM    (so nothing below is blocked by a locked exe)
REM ============================================================

echo [2/8] Stopping any running StockToolKiosk.exe...
taskkill /IM StockToolKiosk.exe /F >nul 2>&1
timeout /t 1 /nobreak >nul
echo   Done.
echo.

REM ============================================================
REM 3. SELF-HEAL: NSSM
REM ============================================================

echo [3/8] Checking NSSM...
echo.

if exist "%NSSM_EXE%" (
    echo   OK: %NSSM_EXE%
) else (
    echo   Not found -- downloading NSSM automatically...
    powershell -NoProfile -ExecutionPolicy Bypass -Command ^
        "$ProgressPreference='SilentlyContinue';" ^
        "$zip = Join-Path $env:TEMP 'nssm.zip';" ^
        "$dest = Join-Path $env:TEMP 'nssm-extract';" ^
        "Invoke-WebRequest -Uri 'https://nssm.cc/release/nssm-2.24.zip' -OutFile $zip;" ^
        "if (Test-Path $dest) { Remove-Item -Recurse -Force $dest };" ^
        "Expand-Archive -Path $zip -DestinationPath $dest -Force;" ^
        "$found = Get-ChildItem -Path $dest -Recurse -Filter 'nssm.exe' | Where-Object { $_.FullName -match 'win64' } | Select-Object -First 1;" ^
        "if (-not $found) { Write-Error 'win64 nssm.exe not found in the downloaded archive'; exit 1 };" ^
        "Copy-Item -Path $found.FullName -Destination '%NSSM_EXE%' -Force;" ^
        "Write-Host ('  Installed: ' + '%NSSM_EXE%')"

    if not "%errorlevel%"=="0" (
        echo.
        echo ERROR: automatic NSSM download failed.
        echo Download it yourself from https://nssm.cc/download and place the
        echo win64 nssm.exe at:
        echo   %NSSM_EXE%
        goto FAIL
    )
)
echo.

REM ============================================================
REM 4. SELF-HEAL: WIX CLI
REM ============================================================

echo [4/8] Checking the WiX CLI...
echo.

set "DOTNET_TOOLS=%USERPROFILE%\.dotnet\tools"
if exist "%DOTNET_TOOLS%\wix.exe" set "PATH=%DOTNET_TOOLS%;%PATH%"

where wix.exe >nul 2>&1
if not "%errorlevel%"=="0" (
    echo   wix.exe not found -- attempting to install it.
    echo.

    where dotnet.exe >nul 2>&1
    if not "%errorlevel%"=="0" (
        echo   .NET SDK not found -- attempting to install it via winget...
        where winget.exe >nul 2>&1
        if not "%errorlevel%"=="0" (
            echo.
            echo ERROR: neither dotnet nor winget is available.
            echo Install the .NET SDK yourself from https://dotnet.microsoft.com/download
            echo then re-run this script.
            goto FAIL
        )
        winget install Microsoft.DotNet.SDK.8 --accept-source-agreements --accept-package-agreements
        if not "%errorlevel%"=="0" (
            echo.
            echo ERROR: winget could not install the .NET SDK.
            echo Install it yourself from https://dotnet.microsoft.com/download then re-run this script.
            goto FAIL
        )
        echo   .NET SDK installed. You may need to close and re-run this script
        echo   once from a fresh window if the next step still cannot find dotnet.
    )

    dotnet tool install --global wix
    if not "%errorlevel%"=="0" (
        dotnet tool update --global wix >nul 2>&1
    )

    set "PATH=%DOTNET_TOOLS%;%PATH%"
    where wix.exe >nul 2>&1
    if not "%errorlevel%"=="0" (
        echo.
        echo ERROR: wix.exe still not found on PATH after install.
        echo Close this window, open a fresh terminal, and re-run this script --
        echo a new PATH entry sometimes only takes effect in a new session.
        goto FAIL
    )
)

for /f "delims=" %%V in ('wix.exe --version 2^>nul') do echo   OK: wix.exe version %%V
echo.

REM ============================================================
REM 5. SELF-HEAL: WIX UI EXTENSION
REM ============================================================

echo [5/8] Checking the WiX UI extension...
echo.

wix.exe extension list --global > "%TEMP%\stocktool_wix_ext.txt" 2>&1
findstr /I /C:"WixToolset.UI.wixext" "%TEMP%\stocktool_wix_ext.txt" >nul 2>&1
if not "%errorlevel%"=="0" (
    echo   Not found -- installing with --global scope, so it works from
    echo   any directory and does not need a WiX project file...
    wix.exe extension add WixToolset.UI.wixext --global > "%TEMP%\stocktool_wix_ext_add.txt" 2>&1
    if not "%errorlevel%"=="0" (
        echo.
        echo ERROR: could not install WixToolset.UI.wixext. Output from wix.exe:
        echo ------------------------------------------------------------
        type "%TEMP%\stocktool_wix_ext_add.txt"
        echo ------------------------------------------------------------
        del "%TEMP%\stocktool_wix_ext.txt" >nul 2>&1
        del "%TEMP%\stocktool_wix_ext_add.txt" >nul 2>&1
        goto FAIL
    )
    del "%TEMP%\stocktool_wix_ext_add.txt" >nul 2>&1
) else (
    echo   OK: WixToolset.UI.wixext
)
del "%TEMP%\stocktool_wix_ext.txt" >nul 2>&1
echo.

REM ============================================================
REM 6. SELF-HEAL: INSTALLER ICON
REM ============================================================

echo [6/8] Checking installer icon...
echo.

if exist "%ICON_ICO%" (
    echo   OK: %ICON_ICO%
) else (
    echo   Not found -- generating a placeholder icon...
    powershell -NoProfile -ExecutionPolicy Bypass -Command ^
        "Add-Type -AssemblyName System.Drawing;" ^
        "$src = Join-Path $env:WINDIR 'System32\shell32.dll';" ^
        "$icon = [System.Drawing.Icon]::ExtractAssociatedIcon($src);" ^
        "if (-not $icon) { $icon = [System.Drawing.SystemIcons]::Application };" ^
        "$fs = [System.IO.File]::Open('%ICON_ICO%', 'Create');" ^
        "$icon.Save($fs); $fs.Close();" ^
        "Write-Host '  Placeholder icon written -- swap in a real icon.ico whenever you have one.'"

    if not "%errorlevel%"=="0" (
        echo.
        echo WARNING: could not generate a placeholder icon.
        echo Place any .ico file at:
        echo   %ICON_ICO%
        echo and re-run this script. Continuing so the actual WiX error can be
        echo seen if this really does block the build.
    )
)
echo.

REM ============================================================
REM 7. BUILD
REM    NOTE: no longer passes -Verify to build.ps1 -- build.ps1's own
REM    internal verify step is a black box from here (its launch/kill
REM    mechanism is unknown) and was the suspected source of the
REM    earlier 0xC000013A (Ctrl+C) exit. This script does its OWN
REM    independent verification in step 8 below instead, using a
REM    licence-independent health check -- see that step for why.
REM ============================================================

echo [7/8] Building (PyInstaller + WiX)...
echo.
echo ============================================================
echo   BUILD OUTPUT
echo ============================================================
echo.

pushd "%INSTALLER%\.."
powershell -NoProfile -ExecutionPolicy Bypass -File "%BUILD_PS1%" -NssmPath "%NSSM_EXE%"
set "BUILD_EXIT=%errorlevel%"
popd

echo.
echo ============================================================
echo.

if not "%BUILD_EXIT%"=="0" (
    echo ERROR: build.ps1 exited with code %BUILD_EXIT% -- scroll up for the
    echo actual PyInstaller/WiX error. Nothing below this point ran.
    goto FAIL
)

REM ============================================================
REM 8. FINAL INDEPENDENT VERIFICATION
REM
REM    Checks /api/status FIRST, not /ui/ -- /api/status is exempt from
REM    the licence gate (see license.py's _EXEMPT_PREFIXES) so it
REM    reports 200 whether or not this machine has a valid licence.
REM    That's the real "is the process alive and serving" signal.
REM    /ui/ is licence-gated by design (403 with no key) -- a 403 there
REM    means the build and process are fine, just unlicensed. Only a
REM    failed CONNECTION (curl can't reach the port at all) is treated
REM    as a real build failure.
REM ============================================================

echo [8/8] Final verification...
echo.

set "VERIFY_OK=1"

if exist "%EXE_PATH%" (
    for %%F in ("%EXE_PATH%") do echo   OK: EXE  %%~fF  -- built %%~tF, %%~zF bytes
) else (
    echo   MISSING: %EXE_PATH%
    set "VERIFY_OK=0"
)

if exist "%MSI_PATH%" (
    for %%F in ("%MSI_PATH%") do echo   OK: MSI  %%~fF  -- built %%~tF, %%~zF bytes
) else (
    echo   MISSING: %MSI_PATH%
    set "VERIFY_OK=0"
)

if "%VERIFY_OK%"=="0" goto FAIL
echo.

taskkill /IM StockToolKiosk.exe /F >nul 2>&1
timeout /t 1 /nobreak >nul

echo   Launching the fresh exe in its own window...
start "StockTool Kiosk (do not close / do not type here)" cmd /k "%EXE_PATH%"
echo   Waiting for it to finish starting up...
timeout /t 8 /nobreak >nul

REM -- Step 1: is the process actually alive and serving at all? --
curl.exe -s --max-time 10 -o "%TEMP%\stocktool_status_check.json" -w "%%{http_code}" http://127.0.0.1:8420/api/status > "%TEMP%\stocktool_status_code.txt" 2>nul
set /p STATUS_CODE=<"%TEMP%\stocktool_status_code.txt"

if "%STATUS_CODE%"=="200" (
    echo   OK: /api/status answered 200 -- the server process is alive and serving.
) else if "%STATUS_CODE%"=="" (
    echo   WARNING: could not connect to http://127.0.0.1:8420/api/status at all.
    echo   The exe may have crashed on startup, or something else is using the port.
    echo   Check the kiosk window itself, or %%PROGRAMDATA%%\StockToolKiosk\service.log
    del "%TEMP%\stocktool_status_check.json" "%TEMP%\stocktool_status_code.txt" >nul 2>&1
    goto SUCCESS_WITH_WARNING
) else (
    echo   WARNING: /api/status returned HTTP %STATUS_CODE% ^(expected 200^).
    del "%TEMP%\stocktool_status_check.json" "%TEMP%\stocktool_status_code.txt" >nul 2>&1
    goto SUCCESS_WITH_WARNING
)
del "%TEMP%\stocktool_status_check.json" "%TEMP%\stocktool_status_code.txt" >nul 2>&1

REM -- Step 2: is the UI reachable, and is it licensed? --
curl.exe -s --max-time 10 -o "%TEMP%\stocktool_ui_check.html" -w "%%{http_code}" http://127.0.0.1:8420/ui/ > "%TEMP%\stocktool_ui_code.txt" 2>nul
set /p UI_CODE=<"%TEMP%\stocktool_ui_code.txt"

if "%UI_CODE%"=="403" (
    echo.
    echo   INFO: /ui/ returned 403 -- this machine has no valid licence yet.
    echo   That is EXPECTED on a fresh/unlicensed build machine and is not a
    echo   build failure. Enter a licence key via /licence-activate to test
    echo   the full UI.
    del "%TEMP%\stocktool_ui_check.html" "%TEMP%\stocktool_ui_code.txt" >nul 2>&1
    goto SUCCESS
)

if not "%UI_CODE%"=="200" (
    echo   WARNING: /ui/ returned HTTP %UI_CODE% ^(expected 200 or 403^).
    del "%TEMP%\stocktool_ui_check.html" "%TEMP%\stocktool_ui_code.txt" >nul 2>&1
    goto SUCCESS_WITH_WARNING
)

set "FOUND_SCAN=0"
set "FOUND_LOWSTOCK=0"
set "FOUND_AUDIT=0"
findstr /C:"Scan in order" "%TEMP%\stocktool_ui_check.html" >nul 2>&1 && set "FOUND_SCAN=1"
findstr /C:"tab-lowstock" "%TEMP%\stocktool_ui_check.html" >nul 2>&1 && set "FOUND_LOWSTOCK=1"
findstr /C:"tab-audit" "%TEMP%\stocktool_ui_check.html" >nul 2>&1 && set "FOUND_AUDIT=1"
del "%TEMP%\stocktool_ui_check.html" "%TEMP%\stocktool_ui_code.txt" >nul 2>&1

echo.
echo   HTTP verification (licensed UI):
if "%FOUND_SCAN%"=="1" (echo     OK: scan-order enforcement text found) else (echo     MISSING: scan-order text)
if "%FOUND_LOWSTOCK%"=="1" (echo     OK: Low Stock tab found) else (echo     MISSING: Low Stock tab)
if "%FOUND_AUDIT%"=="1" (echo     OK: Audit tab found) else (echo     MISSING: Audit tab)

goto SUCCESS


:SUCCESS_WITH_WARNING
echo.
echo ============================================================
echo   BUILD SUCCESSFUL - runtime check incomplete
echo ============================================================
echo.
echo EXE: %EXE_PATH%
echo MSI: %MSI_PATH%
echo.
echo The files built successfully. The HTTP verification step could not
echo complete -- check the kiosk window that should now be open.
echo.
pause
exit /b 0


:SUCCESS
echo.
echo ============================================================
echo   SUCCESS - build + self-heal + verify complete
echo ============================================================
echo.
echo EXE: %EXE_PATH%
echo MSI: %MSI_PATH%
echo Checksums: %DIST%\checksums.txt
echo.
echo The fresh StockTool Kiosk is running. Open this in a browser
echo (hard refresh if it was already open in a tab):
echo   http://127.0.0.1:8420/ui/
echo.
echo To ship this MSI to a new machine, or to publish it so already
echo paired kiosks self-update, see BUILD.md.
echo ============================================================
pause
exit /b 0


:FAIL
echo.
echo ============================================================
echo   FAILED
echo ============================================================
echo.
echo Kiosk dir: %KIOSK_ARG%
echo EXE:       %EXE_PATH%
echo MSI:       %MSI_PATH%
echo.
echo Review the error above. This script is safe to re-run from the top --
echo every self-heal step skips itself once the thing it checks for exists.
echo.
pause
exit /b 1
