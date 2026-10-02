@echo off
setlocal EnableExtensions DisableDelayedExpansion

title StockTool Kiosk - WiX 7 Build

echo ============================================================
echo   StockTool Kiosk - WiX 7 Build
echo ============================================================
echo.

set "INSTALLER=%~dp0"
set "ROOT=%INSTALLER%.."
set "PRODUCT=%INSTALLER%Product.wxs"
set "NSSM=%INSTALLER%nssm.exe"
set "VERSION=%ROOT%\version.py"
set "EXE=%ROOT%\dist\StockToolKiosk.exe"
set "MSI=%ROOT%\dist\StockToolKiosk.msi"

echo Installer:
echo   %INSTALLER%
echo.
echo Root:
echo   %ROOT%
echo.

echo [1/6] Checking files...

if not exist "%PRODUCT%" (
    echo ERROR: Missing Product.wxs
    goto FAIL
)

if not exist "%VERSION%" (
    echo ERROR: Missing version.py
    goto FAIL
)

if not exist "%NSSM%" (
    echo ERROR: Missing installer\nssm.exe
    echo.
    echo Expected:
    echo   %NSSM%
    goto FAIL
)

echo   OK: Product.wxs
echo   OK: version.py
echo   OK: nssm.exe

echo.
echo [2/6] Reading version...

for /f "usebackq delims=" %%V in (`powershell.exe -NoProfile -Command "$x=Get-Content -Raw -LiteralPath '%VERSION%'; if($x -match '__version__\s*=\s*[""'' ]*(\d+\.\d+\.\d+)'){Write-Output $Matches[1]}"`) do set "PRODUCT_VERSION=%%V"

if not defined PRODUCT_VERSION (
    echo ERROR: Could not read __version__ from version.py
    goto FAIL
)

echo   ProductVersion: %PRODUCT_VERSION%

echo.
echo [3/6] Checking WiX...

where wix.exe >nul 2>&1

if errorlevel 1 (
    echo ERROR: wix.exe not found.
    echo.
    echo Install with:
    echo   dotnet tool install --global wix
    goto FAIL
)

wix --version

echo.
echo [4/6] Checking WiX UI extension...

wix extension list | findstr /I "WixToolset.UI.wixext" >nul 2>&1

if errorlevel 1 (
    echo   Installing WixToolset.UI.wixext...
    wix extension add WixToolset.UI.wixext

    if errorlevel 1 (
        echo ERROR: Could not install UI extension.
        goto FAIL
    )
)

echo   OK: WixToolset.UI.wixext

echo.
echo [5/6] Checking PyInstaller EXE...

if not exist "%EXE%" (
    echo   EXE missing. Building...

    if not exist "%ROOT%\venv\Scripts\pyinstaller.exe" (
        echo ERROR: PyInstaller not found.
        goto FAIL
    )

    pushd "%ROOT%"

    "%ROOT%\venv\Scripts\pyinstaller.exe" build.spec

    if errorlevel 1 (
        popd
        echo ERROR: PyInstaller failed.
        goto FAIL
    )

    popd
)

if not exist "%EXE%" (
    echo ERROR: EXE was not created.
    goto FAIL
)

echo   OK:
echo   %EXE%

echo.
echo [6/6] Building MSI...

if not exist "%ROOT%\dist" mkdir "%ROOT%\dist"

echo.
echo ============================================================
echo   EXACT WiX COMMAND
echo ============================================================
echo.
echo wix build "Product.wxs" -arch x64 -ext WixToolset.UI.wixext -d "ProductVersion=%PRODUCT_VERSION%" -d "NssmSrc=%NSSM%" -o "%MSI%"
echo.
echo ============================================================
echo.

pushd "%INSTALLER%"

wix build "Product.wxs" -arch x64 -ext WixToolset.UI.wixext -d "ProductVersion=%PRODUCT_VERSION%" -d "NssmSrc=%NSSM%" -o "%MSI%"

set "RESULT=%ERRORLEVEL%"

popd

if not "%RESULT%"=="0" (
    echo.
    echo ============================================================
    echo   WIX BUILD FAILED
    echo ============================================================
    echo.
    echo Exit code: %RESULT%
    goto FAIL
)

if not exist "%MSI%" (
    echo ERROR: WiX returned success but MSI does not exist.
    goto FAIL
)

echo.
echo ============================================================
echo   SUCCESS
echo ============================================================
echo.
echo MSI:
echo   %MSI%
echo.
echo Version:
echo   %PRODUCT_VERSION%
echo.
echo ============================================================
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
echo   %PRODUCT%
echo.
echo NSSM:
echo   %NSSM%
echo.
echo EXE:
echo   %EXE%
echo.
echo MSI:
echo   %MSI%
echo.
echo ============================================================
echo.

pause
exit /b 1