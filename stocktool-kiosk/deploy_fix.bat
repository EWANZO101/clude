@echo off
setlocal enabledelayedexpansion
title StockTool - Apply All Fixes (Verified)

echo ============================================================
echo  StockTool Kiosk - Apply All Fixes
echo ============================================================
echo.
echo This will replace your current index.html with a fixed
echo version. It verifies file integrity at every step and backs
echo up your existing file before changing anything.
echo.

REM --- The fixed file must sit next to this .bat file ---
set "SRC=%~dp0index.html"

if not exist "%SRC%" (
    echo ERROR: index.html was not found next to this .bat file.
    echo Keep deploy_fix.bat and index.html in the same folder and
    echo run this again.
    echo.
    pause
    exit /b 1
)

REM --- Known-good SHA-256 of the fixed index.html this script ships ---
REM --- with. If the file next to this script doesn't match, it was  ---
REM --- edited, corrupted, or swapped after download -- stop rather  ---
REM --- than deploy something unverified.                            ---
set "EXPECTED_SRC_HASH=0E5282056BEA1D07FD573B8618EC62C1D60542AB1FBDF91783CA4499CC090E35"

echo Verifying the fixed file hasn't been altered since it was built...
set "SRC_HASH="
for /f "skip=1 tokens=1" %%H in ('certutil -hashfile "%SRC%" SHA256') do (
    if not defined SRC_HASH set "SRC_HASH=%%H"
)
set "SRC_HASH_UPPER=%SRC_HASH%"
if /I not "%SRC_HASH_UPPER%"=="%EXPECTED_SRC_HASH%" (
    echo.
    echo ERROR: index.html does not match the expected fixed version.
    echo   Expected: %EXPECTED_SRC_HASH%
    echo   Found:    %SRC_HASH_UPPER%
    echo.
    echo This means the file was modified, corrupted, or is not the
    echo file provided. Nothing was changed. Re-download index.html
    echo and try again.
    echo.
    pause
    exit /b 1
)
echo   OK - matches expected hash.
echo.

REM --- Where your server serves the UI from. Edit this line if it's ---
REM --- somewhere else on your machine.                              ---
set "TARGET=C:\StockTool\ui\index.html"

if not exist "%TARGET%" (
    echo Could not find:
    echo   %TARGET%
    echo.
    set /p TARGET="Enter the full path to your StockTool index.html: "
)

if not exist "%TARGET%" (
    echo.
    echo ERROR: "%TARGET%" was not found either. Nothing was changed.
    echo.
    pause
    exit /b 1
)

echo.
echo Target file:
echo   %TARGET%
echo.
set /p CONFIRM="This will overwrite that file. Continue? (Y/N): "
if /I not "%CONFIRM%"=="Y" (
    echo Cancelled. Nothing was changed.
    echo.
    pause
    exit /b 0
)
echo.

REM --- Clear any read-only flag a previous run of this script may   ---
REM --- have set, so we're able to write to these paths again.       ---
attrib -R "%TARGET%" >nul 2>&1

REM --- Hash the CURRENT file before touching it, so the backup can  ---
REM --- be verified as an exact copy, not a partial/corrupted one.   ---
set "ORIGINAL_HASH="
for /f "skip=1 tokens=1" %%H in ('certutil -hashfile "%TARGET%" SHA256') do (
    if not defined ORIGINAL_HASH set "ORIGINAL_HASH=%%H"
)

set "BACKUP=%TARGET%.bak"
attrib -R "%BACKUP%" >nul 2>&1
echo Backing up your current file to:
echo   %BACKUP%
copy /y "%TARGET%" "%BACKUP%" >nul
if errorlevel 1 (
    echo ERROR: Could not create a backup. Nothing was changed.
    echo If this path is under Program Files or similar, try
    echo right-clicking this script and choosing "Run as administrator".
    echo.
    pause
    exit /b 1
)

set "BACKUP_HASH="
for /f "skip=1 tokens=1" %%H in ('certutil -hashfile "%BACKUP%" SHA256') do (
    if not defined BACKUP_HASH set "BACKUP_HASH=%%H"
)
if /I not "%BACKUP_HASH%"=="%ORIGINAL_HASH%" (
    echo ERROR: Backup verification failed -- the backup copy doesn't
    echo match the original file. Nothing further was changed.
    echo.
    pause
    exit /b 1
)
echo   Backup verified OK.
echo.

echo Deploying the fixed file...
copy /y "%SRC%" "%TARGET%" >nul
if errorlevel 1 (
    echo ERROR: Could not copy the fixed file into place.
    echo Your original file is unchanged and safely backed up at:
    echo   %BACKUP%
    echo.
    pause
    exit /b 1
)

set "NEW_HASH="
for /f "skip=1 tokens=1" %%H in ('certutil -hashfile "%TARGET%" SHA256') do (
    if not defined NEW_HASH set "NEW_HASH=%%H"
)
if /I not "%NEW_HASH%"=="%SRC_HASH_UPPER%" (
    echo ERROR: The deployed file doesn't match what should have been
    echo copied -- it may have been corrupted in transit. Restoring
    echo your original file from backup...
    copy /y "%BACKUP%" "%TARGET%" >nul
    echo Restored. Nothing was ultimately changed. Please try again.
    echo.
    pause
    exit /b 1
)
echo   Deployment verified OK.
echo.

REM --- Mark both files read-only: makes the live file and its backup ---
REM --- resistant to casual or malicious local editing from the kiosk ---
REM --- itself. To edit either again later, clear this first with:    ---
REM --- attrib -R "path\to\file"                                      ---
attrib +R "%TARGET%"
attrib +R "%BACKUP%"

echo ============================================================
echo  Done. Fixes applied and verified:
echo ============================================================
echo   - Fixed Tailwind CDN crash from an invalid "font-inherit" class
echo   - Fixed circular "@apply hidden" utility crash
echo     (both of these were breaking ALL page styling)
echo   - Restored the original dark indigo theme
echo   - Added auto-logout after inactivity:
echo       * countdown shown in the sidebar
echo       * "security check" re-scan prompt before logging out
echo       * admin-configurable timeout (Users tab)
echo   - Fixed "Recent Activity -> View all" linking to the wrong tab
echo   - Fixed a stored XSS hole in the Dashboard "Recent Checkouts" panel
echo   - Fixed a DOM XSS / session-token theft risk in "Print barcode"
echo   - Escaped DB Tools table names (defense in depth)
echo.
echo The live file and its backup are now marked read-only.
echo Your previous file is safely preserved at:
echo   %BACKUP%
echo.
echo Now reload the kiosk page (F5) to see the changes.
echo.
pause
