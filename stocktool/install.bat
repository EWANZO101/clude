@echo off
setlocal EnableDelayedExpansion
title StockTool Installer
color 0A

echo.
echo  ================================================
echo   StockTool - Installation
echo  ================================================
echo.

:: Find Python: try py launcher first, then python, then python3
set PYTHON_CMD=

py --version >nul 2>&1
if not errorlevel 1 (
    set PYTHON_CMD=py
    goto :python_found
)

python --version >nul 2>&1
if not errorlevel 1 (
    set PYTHON_CMD=python
    goto :python_found
)

python3 --version >nul 2>&1
if not errorlevel 1 (
    set PYTHON_CMD=python3
    goto :python_found
)

echo  [ERROR] Python not found.
echo.
echo  Please install Python 3.10 or later:
echo    https://www.python.org/downloads/
echo.
echo  IMPORTANT: During install, tick "Add Python to PATH"
echo  then run this installer again.
echo.
pause
exit /b 1

:python_found
for /f "tokens=2" %%v in ('!PYTHON_CMD! --version 2^>^&1') do set PYVER=%%v
echo  [OK] Python !PYVER! found (!PYTHON_CMD!)
echo.

:: Check version >= 3.10
for /f "tokens=1,2 delims=." %%a in ("!PYVER!") do (
    set PY_MAJOR=%%a
    set PY_MINOR=%%b
)
if !PY_MAJOR! LSS 3 (
    echo  [ERROR] Python 3.10+ required. Found !PYVER!
    pause
    exit /b 1
)
if !PY_MAJOR! EQU 3 if !PY_MINOR! LSS 10 (
    echo  [ERROR] Python 3.10+ required. Found !PYVER!
    pause
    exit /b 1
)

:: Check / install pip
!PYTHON_CMD! -m pip --version >nul 2>&1
if errorlevel 1 (
    echo  pip not found - attempting to install...
    !PYTHON_CMD! -m ensurepip --upgrade
    if errorlevel 1 (
        echo  [ERROR] Could not install pip. Reinstall Python and try again.
        pause
        exit /b 1
    )
)
echo  [OK] pip ready
echo.

:: Virtual environment
if not exist "venv\" (
    echo  Creating virtual environment...
    !PYTHON_CMD! -m venv venv
    if errorlevel 1 (
        echo  [ERROR] Failed to create virtual environment.
        pause
        exit /b 1
    )
    echo  [OK] Virtual environment created
) else (
    echo  [OK] Virtual environment already exists
)
echo.

:: Activate and install dependencies
echo  Installing dependencies (this may take a minute)...
call venv\Scripts\activate.bat
pip install -q --upgrade pip
pip install -q -r requirements.txt
if errorlevel 1 (
    echo.
    echo  [ERROR] Dependency install failed.
    echo  Check your internet connection and try again.
    pause
    exit /b 1
)
echo  [OK] Dependencies installed
echo.

:: Required directories
if not exist "instance\" mkdir instance
if not exist "app\static\qr\" mkdir app\static\qr

:: Generate .env if missing
if not exist ".env" (
    echo  Generating secret keys...
    for /f %%k in ('python -c "import secrets; print(secrets.token_hex(32))"') do set SK=%%k
    for /f %%k in ('python -c "import secrets; print(secrets.token_hex(32))"') do set JK=%%k
    (
        echo SECRET_KEY=!SK!
        echo JWT_SECRET_KEY=!JK!
        echo HOST=0.0.0.0
        echo PORT=5000
    ) > .env
    echo  [OK] .env created with secure random keys
) else (
    echo  [OK] .env already exists
)
echo.

:: Load .env
for /f "usebackq tokens=1,2 delims==" %%a in (".env") do set %%a=%%b

:: Database init + admin setup
echo  Setting up database...
python scripts\init_db.py
if errorlevel 1 (
    echo.
    echo  [ERROR] Database setup failed.
    pause
    exit /b 1
)
echo.
echo  [OK] Database ready
echo.

:: Write start.bat
(
    echo @echo off
    echo title StockTool
    echo color 0A
    echo cd /d "%%~dp0"
    echo call venv\Scripts\activate.bat
    echo for /f "usebackq tokens=1,2 delims==" %%%%a in ^(".env"^) do set %%%%a=%%%%b
    echo echo.
    echo echo  StockTool is running
    echo echo  Open your browser: http://localhost:5000
    echo echo  Press Ctrl+C to stop.
    echo echo.
    echo python run.py
    echo pause
) > start.bat

:: Write stop.bat
(
    echo @echo off
    echo echo Stopping StockTool...
    echo taskkill /f /im python.exe /fi "WINDOWTITLE eq StockTool" 2^>nul
    echo echo Done.
    echo pause
) > stop.bat

echo  [OK] start.bat and stop.bat created
echo.
echo  ================================================
echo   Installation complete!
echo  ================================================
echo.
echo   To start StockTool:  double-click start.bat
echo   Browser URL:         http://localhost:5000
echo.
echo   Remote access via Cloudflare Tunnel:
echo     cloudflared tunnel --url http://localhost:5000
echo.
echo   Direct network access:
echo     http://YOUR-SERVER-IP:5000
echo.
pause
