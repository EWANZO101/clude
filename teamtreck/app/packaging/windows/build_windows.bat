@echo off
REM Build the Windows onefile binary. Run from the project root:
REM   packaging\windows\build_windows.bat
REM Output: dist\teamtreck-agent.exe
REM
REM NOT RUN OR VERIFIED IN THIS SANDBOX - there's no Windows machine here.
REM The .spec file this calls was validated with a real Linux build (see
REM BUILD_STATUS.txt); the Windows-specific bits (pywin32, the .exe icon,
REM Inno Setup packaging) still need a first real run on Windows.

cd /d "%~dp0..\.."

python -m venv .build-venv
call .build-venv\Scripts\activate.bat
pip install -r requirements.txt
pip install pywin32
pip install pyinstaller

rmdir /s /q build 2>nul
rmdir /s /q dist 2>nul
pyinstaller packaging\pyinstaller\teamtreck-agent.spec --distpath dist --workpath build --noconfirm

echo.
echo Built: dist\teamtreck-agent.exe
echo Test it with: dist\teamtreck-agent.exe --version
