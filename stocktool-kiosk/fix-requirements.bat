@echo off
REM fix-requirements.bat -- strips corrupted trailing data from requirements.txt
REM Run this from inside the codecheck project folder (same folder as requirements.txt).

setlocal
cd /d "%~dp0"

if not exist "requirements.txt" (
    echo ERROR: requirements.txt not found in this folder.
    pause
    exit /b 1
)

> requirements.txt.fixed (
    echo Flask==3.0.3
    echo Flask-SQLAlchemy==3.1.1
    echo waitress==3.0.0
    echo python-barcode==0.16.1
    echo reportlab==4.2.5
    echo pyinstaller^>=6.15.0
    echo requests
)

move /y requirements.txt requirements.txt.bak >nul
move /y requirements.txt.fixed requirements.txt >nul

echo [FIXED] requirements.txt rewritten. Old copy saved as requirements.txt.bak
echo.
pause
