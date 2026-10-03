@echo off
setlocal EnableExtensions DisableDelayedExpansion

title StockTool Kiosk - Automatic WiX 7 Repair and Build

echo ============================================================
echo   StockTool Kiosk - Automatic WiX 7 Repair + MSI Build
echo ============================================================
echo.

REM ============================================================
REM PATHS
REM ============================================================

set "INSTALLER=%~dp0"
for %%I in ("%INSTALLER%..") do set "ROOT=%%~fI"

set "PRODUCT=%INSTALLER%Product.wxs"
set "BACKUP=%INSTALLER%Product.wxs.wix3-backup"
set "VERSIONFILE=%ROOT%\version.py"
set "NSSM=%INSTALLER%nssm.exe"
set "EXE=%ROOT%\dist\StockToolKiosk.exe"
set "DIST=%ROOT%\dist"
set "MSI=%DIST%\StockToolKiosk.msi"

echo Root:
echo   %ROOT%
echo.
echo Installer:
echo   %INSTALLER%
echo.

REM ============================================================
REM 1. CHECK FILES
REM ============================================================

echo [1/8] Checking project files...

if not exist "%PRODUCT%" (
    echo ERROR: Product.wxs not found:
    echo   %PRODUCT%
    goto :FAIL
)

echo   OK: Product.wxs

if not exist "%VERSIONFILE%" (
    echo ERROR: version.py not found:
    echo   %VERSIONFILE%
    goto :FAIL
)

echo   OK: version.py

if not exist "%NSSM%" (
    echo ERROR: nssm.exe not found:
    echo   %NSSM%
    echo.
    echo Put win64 nssm.exe here:
    echo   %NSSM%
    goto :FAIL
)

echo   OK: nssm.exe

REM ============================================================
REM 2. READ VERSION USING POWERSHELL
REM ============================================================

echo.
echo [2/8] Reading application version...

for /f "usebackq delims=" %%V in (`powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$t=Get-Content -LiteralPath '%VERSIONFILE%' -Raw; if($t -match '__version__\s*=\s*["''](\d+\.\d+\.\d+)["'']'){ $Matches[1] }"`) do (
    set "PRODUCT_VERSION=%%V"
)

if not defined PRODUCT_VERSION (
    echo ERROR: Could not read __version__ from:
    echo   %VERSIONFILE%
    echo.
    echo Expected something like:
    echo   __version__ = "2.2.0"
    goto :FAIL
)

echo   ProductVersion: %PRODUCT_VERSION%

REM ============================================================
REM 3. CHECK WIX
REM ============================================================

echo.
echo [3/8] Checking WiX...

where wix.exe >nul 2>&1

if errorlevel 1 (
    echo ERROR: wix.exe was not found on PATH.
    echo.
    echo Install WiX with:
    echo   dotnet tool install --global wix
    goto :FAIL
)

for /f "delims=" %%W in ('wix --version') do (
    echo   %%W
    goto :WIX_OK
)

:WIX_OK

REM ============================================================
REM 4. CHECK UI EXTENSION
REM ============================================================

echo.
echo [4/8] Checking WiX UI extension...

wix extension list | findstr /I "WixToolset.UI.wixext" >nul 2>&1

if errorlevel 1 (
    echo   UI extension not detected.
    echo   Attempting installation...

    wix extension add WixToolset.UI.wixext

    if errorlevel 1 (
        echo ERROR: Could not install WixToolset.UI.wixext.
        goto :FAIL
    )

    echo   UI extension installed.
) else (
    echo   OK: WixToolset.UI.wixext
)

REM ============================================================
REM 5. CHECK EXE
REM ============================================================

echo.
echo [5/8] Checking PyInstaller EXE...

if not exist "%EXE%" (
    echo   EXE not found. Building with PyInstaller...

    if not exist "%ROOT%\venv\Scripts\pyinstaller.exe" (
        echo ERROR: PyInstaller not found:
        echo   %ROOT%\venv\Scripts\pyinstaller.exe
        goto :FAIL
    )

    pushd "%ROOT%"

    "%ROOT%\venv\Scripts\pyinstaller.exe" build.spec

    if errorlevel 1 (
        popd
        echo ERROR: PyInstaller build failed.
        goto :FAIL
    )

    popd
)

if not exist "%EXE%" (
    echo ERROR: StockToolKiosk.exe still does not exist:
    echo   %EXE%
    goto :FAIL
)

echo   OK:
echo   %EXE%

REM ============================================================
REM 6. CHECK / REPAIR WIX NAMESPACE
REM ============================================================

echo.
echo [6/8] Checking Product.wxs WiX namespace...

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
    "$p='%PRODUCT%'; $s=Get-Content -LiteralPath $p -Raw; if($s -match 'http://schemas\.microsoft\.com/wix/2006/wi'){ $s=$s -replace 'http://schemas\.microsoft\.com/wix/2006/wi','http://wixtoolset.org/schemas/v4/wxs'; Set-Content -LiteralPath $p -Value $s -Encoding UTF8; Write-Host '  WiX 3 namespace converted to WiX 4/7.' } elseif($s -match 'http://wixtoolset\.org/schemas/v4/wxs'){ Write-Host '  OK: WiX 4 namespace detected.' } else { Write-Host '  WARNING: Could not identify WiX namespace.' }"

if errorlevel 1 (
    echo ERROR: Product.wxs namespace repair failed.
    goto :FAIL
)

REM ============================================================
REM 7. BUILD MSI
REM ============================================================

echo.
echo [7/8] Building StockToolKiosk.msi...
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

if not exist "%DIST%" mkdir "%DIST%"

echo Running:
echo.
echo wix build Product.wxs -arch x64 -ext WixToolset.UI.wixext -d "ProductVersion=%PRODUCT_VERSION%" -d "NssmSrc=%NSSM%" -o "%MSI%"
echo.

pushd "%INSTALLER%"

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
    echo   WiX BUILD FAILED
    echo ============================================================
    echo.
    echo Exit code: %WIX_EXIT%
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
    goto :FAIL
)

REM ============================================================
REM 8. VERIFY MSI
REM ============================================================

echo.
echo [8/8] Verifying MSI...

if not exist "%MSI%" (
    echo ERROR: WiX reported success but MSI was not created.
    goto :FAIL
)

for %%F in ("%MSI%") do set "MSI_SIZE=%%~zF"

echo   OK: MSI created.
echo   Size: %MSI_SIZE% bytes
echo.
echo ============================================================
echo   BUILD SUCCESSFUL
echo ============================================================
echo.
echo EXE:
echo   %EXE%
echo.
echo MSI:
echo   %MSI%
echo.
echo ProductVersion:
echo   %PRODUCT_VERSION%
echo.
echo ============================================================
echo.

pause
exit /b 0


:FAIL

echo.
echo ============================================================
echo   BUILD / REPAIR FAILED
echo ============================================================
echo.
echo Product.wxs:
echo   %PRODUCT%
echo.
echo Backup:
echo   %BACKUP%
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