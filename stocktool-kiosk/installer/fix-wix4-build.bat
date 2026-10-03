@echo off
setlocal EnableExtensions EnableDelayedExpansion

title StockTool Kiosk - WiX 7 Build

echo.
echo ============================================================
echo   StockTool Kiosk - WiX 7 Build
echo ============================================================
echo.

REM ------------------------------------------------------------
REM Paths
REM ------------------------------------------------------------

set "ROOT=%~dp0.."
for %%I in ("%ROOT%") do set "ROOT=%%~fI"

set "INSTALLER=%ROOT%\installer"
set "PRODUCT=%INSTALLER%\Product.wxs"
set "VERSION_FILE=%ROOT%\version.py"
set "NSSM=%INSTALLER%\nssm.exe"
set "EXE=%ROOT%\dist\StockToolKiosk.exe"
set "MSI=%ROOT%\dist\StockToolKiosk.msi"

echo Root:
echo   %ROOT%
echo.
echo Installer:
echo   %INSTALLER%
echo.

REM ------------------------------------------------------------
REM 1. Check files
REM ------------------------------------------------------------

echo [1/8] Checking files...

if not exist "%PRODUCT%" (
    echo.
    echo ERROR: Product.wxs not found:
    echo   %PRODUCT%
    goto :FAIL
)

echo   OK: Product.wxs

if not exist "%VERSION_FILE%" (
    echo.
    echo ERROR: version.py not found:
    echo   %VERSION_FILE%
    goto :FAIL
)

echo   OK: version.py

if not exist "%NSSM%" (
    echo.
    echo ERROR: nssm.exe not found:
    echo   %NSSM%
    goto :FAIL
)

echo   OK: nssm.exe

REM ------------------------------------------------------------
REM 2. Read version
REM ------------------------------------------------------------

echo.
echo [2/8] Reading application version...

set "PRODUCT_VERSION="

for /f "tokens=2 delims==" %%A in ('findstr /r /c:"__version__[ ]*=" "%VERSION_FILE%"') do (
    set "PRODUCT_VERSION=%%~A"
)

set "PRODUCT_VERSION=%PRODUCT_VERSION:"=%"
set "PRODUCT_VERSION=%PRODUCT_VERSION: =%"

if not defined PRODUCT_VERSION (
    echo.
    echo ERROR: Could not read __version__ from:
    echo   %VERSION_FILE%
    goto :FAIL
)

echo   ProductVersion: %PRODUCT_VERSION%

REM ------------------------------------------------------------
REM 3. Check WiX
REM ------------------------------------------------------------

echo.
echo [3/8] Checking WiX...

where wix >nul 2>&1

if errorlevel 1 (
    echo.
    echo ERROR: wix.exe was not found on PATH.
    goto :FAIL
)

wix --version

REM ------------------------------------------------------------
REM 4. Check UI extension
REM ------------------------------------------------------------

echo.
echo [4/8] Checking WiX UI extension...

wix extension list | findstr /i "WixToolset.UI.wixext" >nul

if errorlevel 1 (
    echo.
    echo UI extension is not installed.
    echo.
    echo Installing WixToolset.UI.wixext...
    echo.

    wix extension add WixToolset.UI.wixext

    if errorlevel 1 (
        echo.
        echo ERROR: Could not install WixToolset.UI.wixext.
        echo.
        goto :FAIL
    )
)

echo   OK: WixToolset.UI.wixext

REM ------------------------------------------------------------
REM 5. Check EXE
REM ------------------------------------------------------------

echo.
echo [5/8] Checking PyInstaller EXE...

if not exist "%EXE%" (
    echo.
    echo EXE not found:
    echo   %EXE%
    echo.
    echo Building it now...
    echo.

    pushd "%ROOT%"

    if not exist "venv\Scripts\pyinstaller.exe" (
        echo ERROR: PyInstaller not found.
        popd
        goto :FAIL
    )

    call "venv\Scripts\pyinstaller.exe" build.spec

    if errorlevel 1 (
        echo.
        echo ERROR: PyInstaller build failed.
        popd
        goto :FAIL
    )

    popd
)

if not exist "%EXE%" (
    echo.
    echo ERROR: EXE does not exist:
    echo   %EXE%
    goto :FAIL
)

echo   OK:
echo   %EXE%

REM ------------------------------------------------------------
REM 6. Check WiX namespace
REM ------------------------------------------------------------

echo.
echo [6/8] Checking Product.wxs WiX namespace...

findstr /c:"http://wixtoolset.org/schemas/v4/wxs" "%PRODUCT%" >nul

if errorlevel 1 (
    echo.
    echo ERROR: Product.wxs is not using WiX 4 namespace.
    echo.
    goto :FAIL
)

echo   OK: WiX 4 namespace detected.

REM ------------------------------------------------------------
REM 7. Build MSI
REM ------------------------------------------------------------

echo.
echo [7/8] Building StockToolKiosk.msi...
echo.
echo   ProductVersion:
echo     %PRODUCT_VERSION%
echo.
echo   NSSM:
echo     %NSSM%
echo.
echo   Output:
echo     %MSI%
echo.

if exist "%MSI%" (
    del /f /q "%MSI%" >nul 2>&1
)

pushd "%INSTALLER%"

echo Running:
echo.
echo wix build Product.wxs -arch x64 -ext WixToolset.UI.wixext -d ProductVersion=%PRODUCT_VERSION% -d NssmSrc=%NSSM% -o %MSI%
echo.

wix build ^
    "Product.wxs" ^
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
    goto :FAIL
)

REM ------------------------------------------------------------
REM 8. Verify MSI
REM ------------------------------------------------------------

echo.
echo [8/8] Verifying output...

if not exist "%MSI%" (
    echo.
    echo ERROR: MSI was not created:
    echo   %MSI%
    goto :FAIL
)

for %%A in ("%MSI%") do (
    echo   OK: %%~fA
    echo   Size: %%~zA bytes
)

echo.
echo ============================================================
echo BUILD SUCCESSFUL
echo ============================================================
echo.
echo EXE:
echo   %EXE%
echo.
echo MSI:
echo   %MSI%
echo.
echo Version:
echo   %PRODUCT_VERSION%
echo.
echo ============================================================
echo.

exit /b 0


:FAIL

echo.
echo ============================================================
echo BUILD FAILED
echo ============================================================
echo.
echo Fix the error above and run this file again.
echo.

exit /b 1