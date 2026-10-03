@echo off
REM get-nssm-and-build.bat -- ONE-SHOT: finds or downloads nssm.exe,
REM puts it at installer\nssm.exe, then runs make-msi.bat automatically.
REM Run from the project root (same folder as installer\, make-msi.bat).

setlocal DisableDelayedExpansion
cd /d "%~dp0"

if not exist "installer" (
    echo ERROR: installer\ folder not found in this location.
    echo Run this from the project root.
    pause
    exit /b 1
)

if exist "installer\nssm.exe" (
    echo installer\nssm.exe already exists -- skipping fetch.
    goto :BUILD
)

echo Searching this PC for an existing nssm.exe ...
set "FOUND="
for /f "delims=" %%F in ('dir C:\ /s /b nssm.exe 2^>nul') do (
    if not defined FOUND set "FOUND=%%F"
)

if defined FOUND (
    echo Found: %FOUND%
    copy /Y "%FOUND%" "installer\nssm.exe" >nul
    echo Copied to installer\nssm.exe
    goto :BUILD
)

echo No existing nssm.exe found on this PC -- downloading it ...
set "TMPDIR=%TEMP%\nssm_fetch"
if exist "%TMPDIR%" rmdir /s /q "%TMPDIR%" >nul 2>&1
mkdir "%TMPDIR%"

powershell -NoProfile -Command "try { Invoke-WebRequest -Uri 'https://nssm.cc/release/nssm-2.24.zip' -OutFile '%TMPDIR%\nssm.zip' -UseBasicParsing } catch { Write-Host $_; exit 1 }"
if not exist "%TMPDIR%\nssm.zip" (
    echo ERROR: download failed. This PC may not have internet access.
    echo Manually download from https://nssm.cc/download, extract win64\nssm.exe,
    echo and copy it to installer\nssm.exe -- then re-run this script.
    pause
    exit /b 1
)

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
    echo ERROR: could not find nssm.exe inside the downloaded zip.
    pause
    exit /b 1
)

copy /Y "%NSSMEXE%" "installer\nssm.exe" >nul
rmdir /s /q "%TMPDIR%" >nul 2>&1
echo Downloaded and placed installer\nssm.exe

:BUILD
echo.
echo ============================================================
echo   nssm.exe ready. Building...
echo ============================================================
if exist "make-msi.bat" (
    call make-msi.bat
) else (
    echo WARNING: make-msi.bat not found -- run it manually.
    pause
)
