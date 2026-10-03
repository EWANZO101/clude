@echo off
setlocal EnableExtensions
cd /d "%~dp0"

set "WXS=%~dp0Product.wxs"
set "ROOT=%~dp0.."
set "NSSM=%~dp0nssm.exe"
set "EXE=%ROOT%\dist\StockToolKiosk.exe"
set "MSI=%ROOT%\dist\StockToolKiosk.msi"

title StockTool Kiosk - WiX 7 UI Final Fix

echo ============================================================
echo   StockTool Kiosk - WiX 7 UI Final Fix + Build
echo ============================================================
echo.

echo [1/5] Checking Product.wxs...

if not exist "%WXS%" (
    echo ERROR: Product.wxs not found.
    goto FAIL
)

echo   OK
echo.

echo [2/5] Backing up current Product.wxs...

copy /Y "%WXS%" "%WXS%.before-ui-final-fix" >nul

if errorlevel 1 (
    echo ERROR: Backup failed.
    goto FAIL
)

echo   Backup:
echo   %WXS%.before-ui-final-fix
echo.

echo [3/5] Removing unsupported WixUI_ErrorProgressText reference...

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$p='%WXS%'; $s=[IO.File]::ReadAllText($p); $s=[regex]::Replace($s,'\s*<ui:WixUI\s+Id=""WixUI_ErrorProgressText""\s*/>',''); [IO.File]::WriteAllText($p,$s,(New-Object Text.UTF8Encoding($false)))"

if errorlevel 1 (
    echo ERROR: Could not modify Product.wxs.
    goto FAIL
)

echo   Removed.
echo.

echo [4/5] Verifying remaining UI references...

findstr /N /C:"WixUI" "%WXS%"

echo.

echo [5/5] Building MSI...

echo.
echo wix build "Product.wxs" -arch x64 -ext WixToolset.UI.wixext -d "ProductVersion=2.2.0" -d "NssmSrc=%NSSM%" -o "%MSI%"
echo.

wix build "Product.wxs" -arch x64 -ext WixToolset.UI.wixext -d "ProductVersion=2.2.0" -d "NssmSrc=%NSSM%" -o "%MSI%"

set "EXITCODE=%ERRORLEVEL%"

echo.

if not "%EXITCODE%"=="0" (
    echo ============================================================
    echo   WIX BUILD FAILED
    echo ============================================================
    echo.
    echo Exit code: %EXITCODE%
    goto FAIL
)

if not exist "%MSI%" (
    echo ERROR: MSI was not created.
    goto FAIL
)

echo ============================================================
echo   SUCCESS
echo ============================================================
echo.
echo MSI:
echo   %MSI%
echo.

for %%A in ("%MSI%") do echo Size: %%~zA bytes

echo.
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
echo Backup:
echo   %WXS%.before-ui-final-fix
echo.
echo MSI:
echo   %MSI%
echo.

pause
exit /b 1