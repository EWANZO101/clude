@echo off
setlocal EnableExtensions
cd /d "%~dp0"

set "INSTALLER=%~dp0"
set "ROOT=%~dp0.."
set "WXS=%INSTALLER%Product.wxs"
set "ICON=%INSTALLER%icon.ico"
set "NSSM=%INSTALLER%nssm.exe"
set "EXE=%ROOT%\dist\StockToolKiosk.exe"
set "MSI=%ROOT%\dist\StockToolKiosk.msi"

title StockTool Kiosk - Fix Icon + Build MSI

echo ============================================================
echo   StockTool Kiosk - Missing Icon Repair + MSI Build
echo ============================================================
echo.

echo [1/6] Checking project...

if not exist "%WXS%" (
    echo ERROR: Product.wxs missing.
    goto FAIL
)

if not exist "%NSSM%" (
    echo ERROR: nssm.exe missing.
    goto FAIL
)

if not exist "%EXE%" (
    echo ERROR: StockToolKiosk.exe missing.
    goto FAIL
)

echo   OK: Product.wxs
echo   OK: nssm.exe
echo   OK: StockToolKiosk.exe
echo.

echo [2/6] Checking icon.ico...

if exist "%ICON%" (
    echo   OK:
    echo   %ICON%
    goto ICON_READY
)

echo   icon.ico is missing.
echo   Searching project for an existing .ico file...
echo.

set "FOUND_ICON="

for /f "delims=" %%I in ('powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$root='%ROOT%'; Get-ChildItem -LiteralPath $root -Recurse -Filter *.ico -File -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '\\(node_modules|\.git|venv)\\' } | Select-Object -First 1 -ExpandProperty FullName"') do (
    set "FOUND_ICON=%%I"
)

if defined FOUND_ICON (
    echo   Found:
    echo   %FOUND_ICON%
    echo.
    echo   Copying to:
    echo   %ICON%
    copy /Y "%FOUND_ICON%" "%ICON%" >nul

    if errorlevel 1 (
        echo ERROR: Could not copy icon.
        goto FAIL
    )

    echo   Icon installed.
    goto ICON_READY
)

echo.
echo   No .ico file was found anywhere in the project.
echo.
echo   Checking common icon locations...

if exist "%ROOT%\icon.ico" (
    copy /Y "%ROOT%\icon.ico" "%ICON%" >nul
    echo   Copied:
    echo   %ROOT%\icon.ico
    goto ICON_READY
)

if exist "%ROOT%\assets\icon.ico" (
    copy /Y "%ROOT%\assets\icon.ico" "%ICON%" >nul
    echo   Copied:
    echo   %ROOT%\assets\icon.ico
    goto ICON_READY
)

if exist "%ROOT%\resources\icon.ico" (
    copy /Y "%ROOT%\resources\icon.ico" "%ICON%" >nul
    echo   Copied:
    echo   %ROOT%\resources\icon.ico
    goto ICON_READY
)

echo.
echo ERROR: No icon.ico could be found.
echo.
echo Product.wxs requires:
echo   %ICON%
echo.
goto FAIL


:ICON_READY

echo.
echo [3/6] Verifying icon...

if not exist "%ICON%" (
    echo ERROR: icon.ico still does not exist.
    goto FAIL
)

for %%A in ("%ICON%") do echo   Icon size: %%~zA bytes

echo.

echo [4/6] Checking WiX...

wix --version

if errorlevel 1 (
    echo ERROR: WiX unavailable.
    goto FAIL
)

echo.

echo [5/6] Building MSI...

echo.
echo wix build "Product.wxs" -arch x64 -ext WixToolset.UI.wixext -d "ProductVersion=2.2.0" -d "NssmSrc=%NSSM%" -o "%MSI%"
echo.

wix build "Product.wxs" -arch x64 -ext WixToolset.UI.wixext -d "ProductVersion=2.2.0" -d "NssmSrc=%NSSM%" -o "%MSI%"

set "WIX_EXIT=%ERRORLEVEL%"

echo.

if not "%WIX_EXIT%"=="0" (
    echo ============================================================
    echo   WIX BUILD FAILED
    echo ============================================================
    echo.
    echo Exit code: %WIX_EXIT%
    goto FAIL
)

echo [6/6] Verifying MSI...

if not exist "%MSI%" (
    echo ERROR: MSI was not created.
    goto FAIL
)

for %%A in ("%MSI%") do echo   MSI size: %%~zA bytes

echo.
echo ============================================================
echo   SUCCESS - MSI BUILD COMPLETE
echo ============================================================
echo.
echo MSI:
echo   %MSI%
echo.
echo Icon:
echo   %ICON%
echo.
echo ============================================================

pause
exit /b 0


:FAIL

echo.
echo ============================================================
echo   BUILD FAILED
echo ============================================================
echo.
echo Product.wxs:
echo   %WXS%
echo.
echo Icon expected:
echo   %ICON%
echo.
echo MSI:
echo   %MSI%
echo.
echo ============================================================

pause
exit /b 1