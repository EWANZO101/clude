@echo off
REM Builds OpsLabAgent.exe from the admin_panel repo root.
REM Run this ON WINDOWS (PyInstaller does not cross-compile from Linux/macOS).
REM
REM Usage (from repo root, e.g. C:\admin_panel>):
REM     exe_build\build_exe.bat
REM
REM Output: exe_build\dist\OpsLabAgent.exe

setlocal
cd /d "%~dp0\.."

if not exist agent\main.py (
    echo Error: run this from the admin_panel repo root ^(agent\main.py not found^).
    exit /b 1
)

echo ==^> Creating build venv...
python -m venv exe_build\venv
call exe_build\venv\Scripts\activate.bat

echo ==^> Installing dependencies...
pip install --upgrade pip >nul
pip install requests pywin32 pyinstaller
python exe_build\venv\Scripts\pywin32_postinstall.py -install >nul 2>&1

echo ==^> Building OpsLabAgent.exe...
pyinstaller --clean --noconfirm --distpath exe_build\dist --workpath exe_build\build exe_build\OpsLabAgent.spec

echo.
echo Done: exe_build\dist\OpsLabAgent.exe
echo.
echo First run (console, no install needed):
echo     set OPSLAB_ADMIN_URL=https://your-admin-panel
echo     set OPSLAB_REGISTRATION_TOKEN=your-token
echo     exe_build\dist\OpsLabAgent.exe run
echo.
echo Install as a service (elevated prompt):
echo     exe_build\dist\OpsLabAgent.exe install
echo     exe_build\dist\OpsLabAgent.exe start
echo.
echo Stop / uninstall:
echo     exe_build\dist\OpsLabAgent.exe stop
echo     exe_build\dist\OpsLabAgent.exe remove
endlocal
