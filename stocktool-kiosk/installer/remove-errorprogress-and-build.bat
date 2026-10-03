@echo off
setlocal EnableExtensions
cd /d "%~dp0"

set "WXS=%~dp0Product.wxs"
set "ROOT=%~dp0.."
set "NSSM=%~dp0nssm.exe"
set "MSI=%ROOT%\dist\StockToolKiosk.msi"

title StockTool Kiosk - Remove Bad WiX UI Reference

echo ============================================================
echo   StockTool Kiosk - Remove ErrorProgressText + Build
echo ============================================================
echo.

echo [1/4] Backing up Product.wxs...

copy /Y "%WXS%" "%WXS%.before-errorprogress-removal" >nul

echo   OK
echo.

echo [2/4] Removing ALL WixUI_ErrorProgressText references...

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$p='%WXS%'; $lines=[IO.File]::ReadAllLines($p); $out=$lines | Where-Object { $_ -notmatch 'WixUI_ErrorProgressText' }; [IO.File]::WriteAllLines($p,$out,(New-Object Text.UTF8Encoding($false)))"

if errorlevel 1 (
    echo ERROR: Could not modify Product.wxs.
    goto FAIL
)

echo   Done.
echo.

echo [3/4] Confirming removal...

findstr /N /C:"WixUI_ErrorProgressText" "%WXS%"

if not errorlevel 1 (
    echo.
    echo ERROR: WixUI_ErrorProgressText still exists.
    goto FAIL
)

echo   Confirmed: reference removed.
echo.

echo [4/4] Building MSI...

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
echo   SUCCESS - MSI CREATED
echo ============================================================
echo.
echo %MSI%
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
echo %WXS%
echo.
echo Backup:
echo %WXS%.before-errorprogress-removal
echo.
pause
exit /b 1