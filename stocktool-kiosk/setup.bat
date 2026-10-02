@echo off
REM setup.bat -- installs dependencies, migrates the database, and
REM makes sure the admin area (an admin login) and welding-wire codes
REM actually exist. Safe to run more than once.
REM
REM Usage: double-click, or run "setup.bat" from a command prompt.

setlocal

cd /d "%~dp0"

set "PYTHON_BIN=python"
where %PYTHON_BIN% >nul 2>nul
if errorlevel 1 (
    set "PYTHON_BIN=py"
    where %PYTHON_BIN% >nul 2>nul
    if errorlevel 1 (
        echo ERROR: Python was not found on PATH. Install Python 3.10+ from python.org and re-run.
        pause
        exit /b 1
    )
)

if not exist ".venv\Scripts\python.exe" (
    echo [SETUP] Creating virtual environment ^(.venv^) ...
    %PYTHON_BIN% -m venv .venv
    if errorlevel 1 (
        echo ERROR: Failed to create virtual environment.
        pause
        exit /b 1
    )
)

call ".venv\Scripts\activate.bat"

echo [SETUP] Installing/upgrading dependencies from requirements.txt ...
python -m pip install --quiet --upgrade pip
python -m pip install --quiet -r requirements.txt
if errorlevel 1 (
    echo ERROR: pip install failed -- see output above.
    pause
    exit /b 1
)

echo.
python setup_check.py
if errorlevel 1 (
    echo.
    echo Setup finished with errors -- see output above.
    pause
    exit /b 1
)

echo.
pause
