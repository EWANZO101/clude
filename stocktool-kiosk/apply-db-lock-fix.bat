@echo off
REM apply-db-lock-fix.bat -- launcher for apply-db-lock-fix.ps1
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0apply-db-lock-fix.ps1"
