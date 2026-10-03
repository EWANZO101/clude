@echo off
REM make-msi.bat -- rebuilds StockToolKiosk.exe + StockToolKiosk.msi.
REM Automatically finds or downloads installer\nssm.exe if it's
REM missing, so this never fails on that step again.

setlocal EnableDelayedExpansion
cd /d "%~dp0"

if not exist "build.ps1" (
    echo ERROR: build.ps1 not found in this folder.
    pause
    exit /b 1
)

if exist "installer\nssm.exe" goto :NSSM_READY

echo installer\nssm.exe is missing -- fetching it automatically...
echo.
echo Searching C:\ for an existing nssm.exe -- this can take a minute...

set "FOUND="
for /f "delims=" %%F in ('dir C:\ /s /b nssm.exe 2^>nul') do (
    if not defined FOUND set "FOUND=%%F"
)

if not defined FOUND goto :DOWNLOAD_NSSM

echo Found existing copy: !FOUND!
copy /Y "!FOUND!" "installer\nssm.exe" >nul
goto :VERIFY_NSSM

:DOWNLOAD_NSSM
echo No existing copy found on this PC -- downloading from nssm.cc ...
set "TMPDIR=%TEMP%\nssm_fetch"
if exist "%TMPDIR%" rmdir /s /q "%TMPDIR%" >nul 2>&1
mkdir "%TMPDIR%"

powershell -NoProfile -Command "try { Invoke-WebRequest -Uri 'https://nssm.cc/release/nssm-2.24.zip' -OutFile '%TMPDIR%\nssm.zip' -UseBasicParsing } catch { exit 1 }"

if not exist "%TMPDIR%\nssm.zip" (
    echo.
    echo ERROR: download failed -- this PC likely has no internet access,
    echo or it's blocked by a firewall/proxy.
    echo.
    echo Manually download from https://nssm.cc/download on any PC with
    echo internet, take win64\nssm.exe from the zip on a USB drive, and
    echo place it at:
    echo   %CD%\installer\nssm.exe
    echo Then run make-msi.bat again.
    pause
    exit /b 1
)

echo Extracting...
powershell -NoProfile -Command "Expand-Archive -Path '%TMPDIR%\nssm.zip' -DestinationPath '%TMPDIR%\extracted' -Force"

set "NSSMEXE="
for /f "delims=" %%F in ('dir "%TMPDIR%\extracted" /s /b nssm.exe 2^>nul ^| findstr /i win64') do (
    if not defined NSSMEXE set "NSSMEXE=%%F"
)
if not defined NSSMEXE (
    for /f "delims=" %%F in ('dir "%TMPDIR%\extracted" /s /b nssm.exe 2^>nul') do (
        if not defined NSSMEXE set "NSSMEXE=%%F"
    )
)

if not defined NSSMEXE (
    echo ERROR: nssm.exe not found inside the downloaded zip.
    echo Copy it manually to: %CD%\installer\nssm.exe
    pause
    exit /b 1
)

echo Copying !NSSMEXE! to installer\nssm.exe ...
copy /Y "!NSSMEXE!" "installer\nssm.exe" >nul
rmdir /s /q "%TMPDIR%" >nul 2>&1

:VERIFY_NSSM
if not exist "installer\nssm.exe" (
    echo.
    echo ERROR: installer\nssm.exe still does not exist after the copy.
    echo Something is blocking the write ^(permissions, antivirus^).
    echo Copy the file manually and re-run.
    pause
    exit /b 1
)
echo installer\nssm.exe ready.

:NSSM_READY
echo.
echo Stopping any running StockToolKiosk.exe ...
taskkill /IM StockToolKiosk.exe /F >nul 2>&1

echo.
echo Building exe + msi ...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "build.ps1" -NssmPath "%CD%\installer\nssm.exe"
set "BUILD_EXIT=%errorlevel%"

echo.
if not "%BUILD_EXIT%"=="0" (
    echo ============================================================
    echo   BUILD FAILED -- see error above
    echo ============================================================
    pause
    exit /b 1
)

echo ============================================================
echo   BUILD OK
echo ============================================================
echo   EXE: dist\StockToolKiosk.exe
echo   MSI: installer\StockToolKiosk.msi
echo ============================================================
pause
