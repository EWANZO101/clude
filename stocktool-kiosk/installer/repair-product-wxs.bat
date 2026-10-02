@echo off
setlocal EnableExtensions DisableDelayedExpansion

title StockTool Kiosk - Repair Product.wxs

set "PRODUCT=%~dp0Product.wxs"

echo ============================================================
echo   StockTool Kiosk - Repair Product.wxs
echo ============================================================
echo.

if not exist "%PRODUCT%" (
    echo ERROR: Product.wxs not found:
    echo %PRODUCT%
    pause
    exit /b 1
)

echo [1/5] Backing up current Product.wxs...

copy /Y "%PRODUCT%" "%PRODUCT%.before-final-repair" >nul

if errorlevel 1 (
    echo ERROR: Could not create backup.
    pause
    exit /b 1
)

echo   OK

echo.
echo [2/5] Repairing XML namespace quotes...

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
 "$p='%PRODUCT%';" ^
 "$s=Get-Content -LiteralPath $p -Raw;" ^
 "$s=$s -replace 'xmlns=http://wixtoolset.org/schemas/v4/wxs', 'xmlns=""http://wixtoolset.org/schemas/v4/wxs""';" ^
 "$s=$s -replace 'xmlns:ui=http://wixtoolset.org/schemas/v4/wxs/ui', 'xmlns:ui=""http://wixtoolset.org/schemas/v4/wxs/ui""';" ^
 "Set-Content -LiteralPath $p -Value $s -Encoding UTF8"

if errorlevel 1 (
    echo ERROR: Namespace repair failed.
    goto FAIL
)

echo   OK

echo.
echo [3/5] Verifying first lines...

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
 "Get-Content -LiteralPath '%PRODUCT%' | Select-Object -First 5"

echo.
echo [4/5] Testing XML parsing...

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
 "$x=New-Object System.Xml.XmlDocument; $x.Load('%PRODUCT%'); Write-Host '  XML is valid.'"

if errorlevel 1 (
    echo ERROR: Product.wxs is still invalid XML.
    goto FAIL
)

echo.
echo [5/5] Repair complete.

echo.
echo ============================================================
echo   PRODUCT.WXS REPAIR SUCCESSFUL
echo ============================================================
echo.
echo Now run:
echo.
echo   .\repair-and-build-all.bat
echo.
echo ============================================================
echo.

pause
exit /b 0

:FAIL

echo.
echo ============================================================
echo   REPAIR FAILED
echo ============================================================
echo.
echo Backup:
echo   %PRODUCT%.before-final-repair
echo.

pause
exit /b 1