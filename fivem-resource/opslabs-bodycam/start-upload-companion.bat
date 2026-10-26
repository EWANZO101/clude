@echo off
REM Xon Sight media upload companion - double-click this to start it.
REM Before using: edit PORTAL_URL and TOKEN below to match your own community
REM (find them on your portal's /integration page, or /admin/communities).
REM Leave this window open while your server is running - closing it stops uploads.

set PORTAL_URL=https://xonsight.opslabsystems.cloud
set TOKEN=PASTE-YOUR-COMMUNITY-TOKEN-HERE

cd /d "%~dp0"
echo Installing the one Python package this needs (quick, only happens once)...
pip install requests
echo.
echo Starting the upload companion for %PORTAL_URL% - leave this window open.
echo Press Ctrl+C to stop it.
echo.
python "tools\upload-companion.py" --media-dir "%~dp0media" --portal-url %PORTAL_URL% --token %TOKEN%
pause
