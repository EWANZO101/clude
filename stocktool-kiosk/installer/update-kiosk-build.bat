@echo off
setlocal EnableExtensions EnableDelayedExpansion
title StockTool Kiosk - update build tooling

REM ============================================================
REM update-kiosk-build.bat -- copies this session's fixed build
REM tooling (main.py's confirm_or_rollback wiring, build.spec,
REM build.ps1, installer\Product.wxs, installer\SetupWizard.ps1,
REM installer\build-and-verify.bat, scripts\publish_release.py,
REM BUILD.md) into a live kiosk-v2 checkout.
REM
REM Usage:
REM   update-kiosk-build.bat [SOURCE_DIR] [KIOSK_DIR]
REM
REM SOURCE_DIR defaults to this .bat's own folder, so the normal case
REM is: unzip kiosk-build-tooling.zip, open the extracted kiosk-build
REM folder, double-click this file.
REM
REM KIOSK_DIR defaults to C:\StockTool\kiosk-v2 (matches every other
REM script from this session).
REM ============================================================

set "SOURCE_DIR=%~1"
if "%SOURCE_DIR%"=="" set "SOURCE_DIR=%~dp0"
for %%I in ("%SOURCE_DIR%") do set "SOURCE_DIR=%%~fI"

set "KIOSK_DIR=%~2"
if "%KIOSK_DIR%"=="" set "KIOSK_DIR=C:\StockTool\kiosk-v2"
for %%I in ("%KIOSK_DIR%") do set "KIOSK_DIR=%%~fI"

echo ============================================================
echo   StockTool Kiosk build tooling - update
echo ============================================================
echo.
echo Source: %SOURCE_DIR%
echo Kiosk:  %KIOSK_DIR%
echo.

if not exist "%SOURCE_DIR%\main.py" (
    echo ERROR: "%SOURCE_DIR%\main.py" not found.
    echo Run this from inside the extracted kiosk-build folder, or pass
    echo the source folder explicitly:
    echo   update-kiosk-build.bat C:\path\to\kiosk-build C:\StockTool\kiosk-v2
    goto FAIL
)

if not exist "%KIOSK_DIR%\main.py" (
    echo ERROR: "%KIOSK_DIR%\main.py" not found -- that does not look like
    echo a StockTool Kiosk checkout. Pass the right path as the 2nd argument.
    goto FAIL
)

REM ============================================================
REM 1. BACK UP WHAT IS ABOUT TO BE OVERWRITTEN
REM ============================================================

for /f "delims=" %%T in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd-HHmmss"') do set "STAMP=%%T"
set "BACKUP_DIR=%KIOSK_DIR%\_backup-%STAMP%"

echo [1/4] Backing up files this will overwrite to:
echo   %BACKUP_DIR%
echo.

mkdir "%BACKUP_DIR%" >nul 2>&1
mkdir "%BACKUP_DIR%\installer" >nul 2>&1
mkdir "%BACKUP_DIR%\scripts" >nul 2>&1

if exist "%KIOSK_DIR%\main.py" copy /Y "%KIOSK_DIR%\main.py" "%BACKUP_DIR%\main.py" >nul
if exist "%KIOSK_DIR%\build.spec" copy /Y "%KIOSK_DIR%\build.spec" "%BACKUP_DIR%\build.spec" >nul
if exist "%KIOSK_DIR%\build.ps1" copy /Y "%KIOSK_DIR%\build.ps1" "%BACKUP_DIR%\build.ps1" >nul
if exist "%KIOSK_DIR%\BUILD.md" copy /Y "%KIOSK_DIR%\BUILD.md" "%BACKUP_DIR%\BUILD.md" >nul
if exist "%KIOSK_DIR%\installer\Product.wxs" copy /Y "%KIOSK_DIR%\installer\Product.wxs" "%BACKUP_DIR%\installer\Product.wxs" >nul
if exist "%KIOSK_DIR%\installer\SetupWizard.ps1" copy /Y "%KIOSK_DIR%\installer\SetupWizard.ps1" "%BACKUP_DIR%\installer\SetupWizard.ps1" >nul
if exist "%KIOSK_DIR%\installer\build-and-verify.bat" copy /Y "%KIOSK_DIR%\installer\build-and-verify.bat" "%BACKUP_DIR%\installer\build-and-verify.bat" >nul
if exist "%KIOSK_DIR%\scripts\publish_release.py" copy /Y "%KIOSK_DIR%\scripts\publish_release.py" "%BACKUP_DIR%\scripts\publish_release.py" >nul

echo   Done.
echo.

REM ============================================================
REM 2. COPY THE UPDATED FILES IN
REM    NOTE: this never touches dist\, .build-venv\, installer\nssm.exe,
REM    installer\icon.ico, or anything under instance\/ProgramData --
REM    only the specific files this session changed.
REM ============================================================

echo [2/4] Copying updated files...
echo.

if not exist "%KIOSK_DIR%\installer" mkdir "%KIOSK_DIR%\installer" >nul 2>&1
if not exist "%KIOSK_DIR%\scripts" mkdir "%KIOSK_DIR%\scripts" >nul 2>&1

set "COPY_FAILED=0"

copy /Y "%SOURCE_DIR%\main.py" "%KIOSK_DIR%\main.py" >nul || set "COPY_FAILED=1"
copy /Y "%SOURCE_DIR%\build.spec" "%KIOSK_DIR%\build.spec" >nul || set "COPY_FAILED=1"
copy /Y "%SOURCE_DIR%\build.ps1" "%KIOSK_DIR%\build.ps1" >nul || set "COPY_FAILED=1"
copy /Y "%SOURCE_DIR%\BUILD.md" "%KIOSK_DIR%\BUILD.md" >nul || set "COPY_FAILED=1"
copy /Y "%SOURCE_DIR%\installer\Product.wxs" "%KIOSK_DIR%\installer\Product.wxs" >nul || set "COPY_FAILED=1"
copy /Y "%SOURCE_DIR%\installer\SetupWizard.ps1" "%KIOSK_DIR%\installer\SetupWizard.ps1" >nul || set "COPY_FAILED=1"
copy /Y "%SOURCE_DIR%\installer\build-and-verify.bat" "%KIOSK_DIR%\installer\build-and-verify.bat" >nul || set "COPY_FAILED=1"
copy /Y "%SOURCE_DIR%\scripts\publish_release.py" "%KIOSK_DIR%\scripts\publish_release.py" >nul || set "COPY_FAILED=1"

if "%COPY_FAILED%"=="1" (
    echo ERROR: one or more files failed to copy -- check the source files
    echo listed above all actually exist under: %SOURCE_DIR%
    goto FAIL
)

echo   OK: main.py
echo   OK: build.spec
echo   OK: build.ps1
echo   OK: BUILD.md
echo   OK: installer\Product.wxs
echo   OK: installer\SetupWizard.ps1
echo   OK: installer\build-and-verify.bat
echo   OK: scripts\publish_release.py
echo.

REM ============================================================
REM 3. SANITY-CHECK THE COPIED FILES AREN'T EMPTY/TRUNCATED
REM ============================================================

echo [3/4] Verifying copied files are not empty...
echo.

set "VERIFY_FAILED=0"
for %%F in (
    "main.py"
    "build.spec"
    "build.ps1"
    "installer\Product.wxs"
    "installer\SetupWizard.ps1"
    "installer\build-and-verify.bat"
    "scripts\publish_release.py"
) do (
    if not exist "%KIOSK_DIR%\%%~F" (
        echo   MISSING: %%~F
        set "VERIFY_FAILED=1"
    ) else (
        for %%S in ("%KIOSK_DIR%\%%~F") do (
            if %%~zS==0 (
                echo   EMPTY: %%~F
                set "VERIFY_FAILED=1"
            ) else (
                echo   OK: %%~F  ^(%%~zS bytes^)
            )
        )
    )
)

if "%VERIFY_FAILED%"=="1" goto FAIL
echo.

REM ============================================================
REM 4. DONE
REM ============================================================

echo [4/4] Done.
echo.
echo ============================================================
echo   UPDATE COMPLETE
echo ============================================================
echo.
echo Backup of the files this replaced:
echo   %BACKUP_DIR%
echo.
echo Next step -- build and verify:
echo   %KIOSK_DIR%\installer\build-and-verify.bat %KIOSK_DIR%
echo.
pause
exit /b 0

:FAIL
echo.
echo ============================================================
echo   FAILED
echo ============================================================
echo.
echo Review the error above. Nothing under %KIOSK_DIR% was left half
echo -copied for the files that succeeded before the failure -- re-run
echo this script once the issue above is fixed, it is safe to re-run.
echo.
pause
exit /b 1
