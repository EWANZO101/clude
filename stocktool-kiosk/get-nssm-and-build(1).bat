@echo off
REM get-nssm-and-build.bat -- ONE-SHOT: finds or downloads nssm.exe,
REM puts it at installer\nssm.exe, verifies it's actually there, then
REM runs make-msi.bat. Every step prints what it's doing -- nothing
REM hidden this time.

setlocal DisableDelayedExpansion
cd /d "%~dp0"
echo Working folder: %CD%

if not exist "installer" (
    echo ERROR: installer\ folder not found in this location.
    pause
    exit /b 1
)

if exist "installer\nssm.exe" (
    echo installer\nssm.exe already exists.
    dir "installer\nssm.exe"
    goto :BUILD
)

echo.
echo Searching C:\ for an existing nssm.exe -- this can take a minute...
set "FOUND="
for /f "delims=" %%F in ('dir C:\ /s /b nssm.exe 2^>nul') do (
    if not defined FOUND (
        set "FOUND=%%F"
        echo Found: %%F
    )
)

if defined FOUND (
    echo Copying "%FOUND%" to installer\nssm.exe ...
    copy /Y "%FOUND%" "installer\nssm.exe"
    goto :VERIFY
)

echo No existing nssm.exe found on this PC. Downloading from nssm.cc ...
set "TMPDIR=%TEMP%\nssm_fetch"
if exist "%TMPDIR%" rmdir /s /q "%TMPDIR%"
mkdir "%TMPDIR%"

powershell -NoProfile -Command "Invoke-WebRequest -Uri 'https://nssm.cc/release/nssm-2.24.zip' -OutFile '%TMPDIR%\nssm.zip' -UseBasicParsing"
echo.
echo Download step finished. Checking result:
dir "%TMPDIR%\nssm.zip"
if not exist "%TMPDIR%\nssm.zip" (
    echo.
    echo ERROR: download did not produce a file. This PC likely has no
    echo internet access, or it's blocked by a firewall/proxy.
    echo Manually download from https://nssm.cc/download on a machine
    echo that DOES have internet, copy the win64\nssm.exe from the zip
    echo onto a USB drive, and place it at:
    echo   %CD%\installer\nssm.exe
    echo Then run make-msi.bat directly.
    pause
    exit /b 1
)

echo Extracting...
powershell -NoProfile -Command "Expand-Archive -Path '%TMPDIR%\nssm.zip' -DestinationPath '%TMPDIR%\extracted' -Force"
echo.
echo Contents of extracted zip:
dir "%TMPDIR%\extracted" /s /b

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
    echo ERROR: nssm.exe not found anywhere inside the downloaded zip.
    echo See the directory listing above -- the zip's internal layout
    echo may have changed. Copy the right nssm.exe manually to:
    echo   %CD%\installer\nssm.exe
    pause
    exit /b 1
)

echo Copying "%NSSMEXE%" to installer\nssm.exe ...
copy /Y "%NSSMEXE%" "installer\nssm.exe"

:VERIFY
echo.
echo Verifying installer\nssm.exe exists:
if exist "installer\nssm.exe" (
    dir "installer\nssm.exe"
) else (
    echo ERROR: installer\nssm.exe STILL does not exist after the copy.
    echo Something is blocking the copy ^(permissions, antivirus^).
    echo Copy the file manually and re-run.
    pause
    exit /b 1
)

:BUILD
echo.
echo ============================================================
echo   nssm.exe confirmed at installer\nssm.exe. Building...
echo ============================================================
if exist "make-msi.bat" (
    call make-msi.bat
) else (
    echo WARNING: make-msi.bat not found -- run it manually.
    pause
)
