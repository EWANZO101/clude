@echo off
setlocal EnableExtensions EnableDelayedExpansion

title StockTool Kiosk - WiX 7 UI Fix + Build

echo ============================================================
echo   StockTool Kiosk - WiX 7 UI Fix + Build
echo ============================================================
echo.

set "ROOT=%~dp0.."
set "INSTALLER=%~dp0"
set "PRODUCT=%INSTALLER%Product.wxs"
set "VERSION_FILE=%ROOT%\version.py"
set "NSSM=%INSTALLER%nssm.exe"
set "DIST=%ROOT%\dist"
set "MSI=%DIST%\StockToolKiosk.msi"

echo Root:
echo   %ROOT%
echo.
echo Installer:
echo   %INSTALLER%
echo.

echo [1/8] Checking files...

if not exist "%PRODUCT%" (
    echo ERROR: Product.wxs not found:
    echo   %PRODUCT%
    pause
    exit /b 1
)
echo   OK: Product.wxs

if not exist "%VERSION_FILE%" (
    echo ERROR: version.py not found:
    echo   %VERSION_FILE%
    pause
    exit /b 1
)
echo   OK: version.py

if not exist "%NSSM%" (
    echo ERROR: nssm.exe not found:
    echo   %NSSM%
    pause
    exit /b 1
)
echo   OK: nssm.exe

echo.
echo [2/8] Reading application version...

for /f "tokens=2 delims==" %%A in ('findstr /r /c:"__version__ *= *" "%VERSION_FILE%"') do (
    set "PRODUCT_VERSION=%%~A"
)

if not defined PRODUCT_VERSION (
    echo ERROR: Could not read __version__ from version.py
    pause
    exit /b 1
)

echo   ProductVersion: %PRODUCT_VERSION%

echo.
echo [3/8] Checking WiX...

wix --version
if errorlevel 1 (
    echo ERROR: WiX is not available on PATH.
    pause
    exit /b 1
)

echo.
echo [4/8] Checking UI extension...

wix extension list | findstr /i "WixToolset.UI.wixext" >nul 2>&1

if errorlevel 1 (
    echo.
    echo UI extension not found.
    echo Installing WixToolset.UI.wixext...
    echo.

    wix extension add WixToolset.UI.wixext

    if errorlevel 1 (
        echo ERROR: Could not install WixToolset.UI.wixext
        pause
        exit /b 1
    )

    echo.
    echo   OK: WixToolset.UI.wixext installed.
) else (
    echo   OK: WixToolset.UI.wixext available.
)

echo.
echo [5/8] Checking PyInstaller EXE...

if not exist "%DIST%\StockToolKiosk.exe" (
    echo ERROR: PyInstaller EXE not found:
    echo   %DIST%\StockToolKiosk.exe
    echo.
    echo Run the normal build first so the EXE exists.
    pause
    exit /b 1
)

echo   OK:
echo   %DIST%\StockToolKiosk.exe

echo.
echo [6/8] Fixing Product.wxs for WiX 7 UI syntax...

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "$p = '%PRODUCT%';" ^
  "$s = Get-Content $p -Raw;" ^
  "$s = $s -replace 'xmlns=""http://wixtoolset.org/schemas/v4/wxs""', 'xmlns=""http://wixtoolset.org/schemas/v4/wxs"" xmlns:ui=""http://wixtoolset.org/schemas/v4/wxs/ui""';" ^
  "$s = $s -replace '<UIRef Id=""WixUI_InstallDir""\s*/>', '<ui:WixUI Id=""WixUI_InstallDir"" InstallDirectory=""INSTALLFOLDER"" />';" ^
  "$s = $s -replace '<UIRef Id=""WixUI_ErrorProgressText""\s*/>', ''; " ^
  "$s = $s -replace '<WixVariable Id=""WixUIExitDialogOptionalCheckBox"" Value=""1""\s*/>', '<WixVariable Id=""WixUIExitDialogOptionalCheckBox"" Value=""1"" />';" ^
  "Set-Content -Path $p -Value $s -Encoding UTF8;"

if errorlevel 1 (
    echo ERROR: Failed to update Product.wxs.
    pause
    exit /b 1
)

echo   WiX 7 UI syntax applied.

echo.
echo [7/8] Building StockToolKiosk.msi...

if not exist "%DIST%" mkdir "%DIST%"

pushd "%INSTALLER%"

echo.
echo ProductVersion:
echo   %PRODUCT_VERSION%
echo.
echo NSSM:
echo   %NSSM%
echo.
echo Output:
echo   %MSI%
echo.

echo Running:
echo.
echo wix build Product.wxs -arch x64 -ext WixToolset.UI.wixext -d ProductVersion=%PRODUCT_VERSION% -d NssmSrc=%NSSM% -o %MSI%
echo.

wix build "Product.wxs" ^
    -arch x64 ^
    -ext WixToolset.UI.wixext ^
    -d "ProductVersion=%PRODUCT_VERSION%" ^
    -d "NssmSrc=%NSSM%" ^
    -o "%MSI%"

set "WIX_EXIT=%ERRORLEVEL%"

popd

if not "%WIX_EXIT%"=="0" (
    echo.
    echo ============================================================
    echo BUILD FAILED
    echo ============================================================
    echo.
    echo WiX exit code: %WIX_EXIT%
    echo.
    pause
    exit /b %WIX_EXIT%
)

echo.
echo [8/8] Verifying MSI...

if not exist "%MSI%" (
    echo ERROR: WiX reported success but MSI was not found:
    echo   %MSI%
    pause
    exit /b 1
)

for %%A in ("%MSI%") do set "MSI_SIZE=%%~zA"

echo   OK: %MSI%
echo   Size: !MSI_SIZE! bytes

echo.
echo ============================================================
echo BUILD SUCCESSFUL
echo ============================================================
echo.
echo EXE:
echo   %DIST%\StockToolKiosk.exe
echo.
echo MSI:
echo   %MSI%
echo.
echo Version:
echo   %PRODUCT_VERSION%
echo.

pause
exit /b 0