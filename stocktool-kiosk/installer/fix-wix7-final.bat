@echo off
setlocal EnableExtensions
cd /d "%~dp0"

title StockTool Kiosk - WiX 7 Final Repair

set "WXS=%~dp0Product.wxs"
set "NSSM=%~dp0nssm.exe"
set "ROOT=%~dp0.."
set "EXE=%ROOT%\dist\StockToolKiosk.exe"
set "MSI=%ROOT%\dist\StockToolKiosk.msi"
set "BACKUP=%WXS%.before-final-fix"

echo ============================================================
echo   StockTool Kiosk - WiX 7 FINAL Repair + Build
echo ============================================================
echo.
echo Installer:
echo   %~dp0
echo.
echo Root:
echo   %ROOT%
echo.

echo [1/8] Checking files...

if not exist "%WXS%" goto NO_WXS
if not exist "%NSSM%" goto NO_NSSM
if not exist "%EXE%" goto NO_EXE

echo   OK: Product.wxs
echo   OK: nssm.exe
echo   OK: StockToolKiosk.exe
echo.

echo [2/8] Checking WiX...

wix --version
if errorlevel 1 goto NO_WIX

echo.

echo [3/8] Backing up Product.wxs...

copy /Y "%WXS%" "%BACKUP%" >nul

if errorlevel 1 goto BACKUP_FAIL

echo   Backup:
echo   %BACKUP%
echo.

echo [4/8] Repairing Product.wxs...

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$p='%WXS%'; $s=[IO.File]::ReadAllText($p); $s=$s.Replace('xmlns=http://wixtoolset.org/schemas/v4/wxs','xmlns=\"http://wixtoolset.org/schemas/v4/wxs\"'); $s=$s.Replace('xmlns:ui=http://wixtoolset.org/schemas/v4/wxs/ui','xmlns:ui=\"http://wixtoolset.org/schemas/v4/wxs/ui\"'); $s=$s.Replace('<UIRef Id=\"WixUI_InstallDir\" />','<ui:WixUI Id=\"WixUI_InstallDir\" />'); $s=$s.Replace('<UIRef Id=\"WixUI_ErrorProgressText\" />','<ui:WixUI Id=\"WixUI_ErrorProgressText\" />'); [IO.File]::WriteAllText($p,$s,(New-Object Text.UTF8Encoding($false)))"

if errorlevel 1 goto REPAIR_FAIL

echo   Product.wxs repaired.
echo.

echo [5/8] Verifying XML...

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$p='%WXS%'; try { [xml]([IO.File]::ReadAllText($p)) | Out-Null; Write-Host '  XML valid.' } catch { Write-Host '  XML INVALID:'; Write-Host $_.Exception.Message; exit 1 }"

if errorlevel 1 goto XML_FAIL

echo.

echo [6/8] Checking UI references...

findstr /N /C:"WixUI" /C:"UIRef" "%WXS%"

echo.

echo [7/8] Building MSI...

echo.
echo ============================================================
echo   Running WiX
echo ============================================================
echo.

wix build "Product.wxs" -arch x64 -ext WixToolset.UI.wixext -d "ProductVersion=2.2.0" -d "NssmSrc=%NSSM%" -o "%MSI%"

set "WIX_EXIT=%ERRORLEVEL%"

echo.

if not "%WIX_EXIT%"=="0" goto WIX_FAIL

echo [8/8] Verifying MSI...

if not exist "%MSI%" goto MSI_MISSING

for %%A in ("%MSI%") do echo   MSI created: %%~zA bytes

echo.
echo ============================================================
echo   SUCCESS - MSI BUILD COMPLETE
echo ============================================================
echo.
echo MSI:
echo   %MSI%
echo.
echo ============================================================

pause
exit /b 0


:NO_WXS
echo ERROR: Product.wxs not found.
goto FAIL

:NO_NSSM
echo ERROR: nssm.exe not found.
goto FAIL

:NO_EXE
echo ERROR: StockToolKiosk.exe not found:
echo %EXE%
goto FAIL

:NO_WIX
echo ERROR: WiX is not available.
goto FAIL

:BACKUP_FAIL
echo ERROR: Could not back up Product.wxs.
goto FAIL

:REPAIR_FAIL
echo ERROR: Product.wxs repair failed.
goto FAIL

:XML_FAIL
echo ERROR: Product.wxs contains invalid XML.
goto FAIL

:WIX_FAIL
echo ============================================================
echo   WiX BUILD FAILED
echo ============================================================
echo.
echo Exit code: %WIX_EXIT%
goto FAIL

:MSI_MISSING
echo ERROR: WiX returned success but MSI was not created.
goto FAIL

:FAIL
echo.
echo ============================================================
echo   BUILD / REPAIR FAILED
echo ============================================================
echo.
echo Product.wxs:
echo   %WXS%
echo.
echo Backup:
echo   %BACKUP%
echo.
echo MSI:
echo   %MSI%
echo.
pause
exit /b 1