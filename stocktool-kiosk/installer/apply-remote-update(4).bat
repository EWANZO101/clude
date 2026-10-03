@echo off
REM apply-remote-update.bat -- launcher for apply-remote-update.ps1
REM (the actual logic lives there -- PowerShell handles the base64
REM decode and file writes far more reliably than cmd.exe tricks did).
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0apply-remote-update.ps1"
