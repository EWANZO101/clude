@echo off
REM apply-todays-updates.bat -- launcher for apply-todays-updates.ps1
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0apply-todays-updates.ps1"
