@echo off
setlocal enabledelayedexpansion
REM Xon Sight bodycam diagnostic - run this from inside opslabs-bodycam\tools\
REM (next to upload-companion.py), or copy it up one folder next to
REM config_server.lua and run it from there instead.
REM
REM Needs curl (built into Windows 10/11 and the txAdmin Windows build - if
REM "curl is not recognized", you're on an old Windows build; install curl
REM from https://curl.se/windows/ and put curl.exe next to this script).
REM
REM Checks, in order:
REM   1. what config_server.lua actually has set right now (Url/Token/Key/PublicUrl)
REM   2. can we even reach the portal
REM   3. does the token/key actually authenticate
REM   4. is the resource saving recordings to disk at all
REM   5. does a REAL upload of your newest recording succeed
REM That last one proves or disproves the upload path itself, independent of
REM whatever PublicUrl/video-link mess is on screen in the evidence list.

cd /d "%~dp0"
if exist "..\config_server.lua" (
    cd /d "%~dp0\.."
) else if exist "config_server.lua" (
    rem already in the resource folder
) else (
    echo [ERROR] Can't find config_server.lua next to this script or one folder up.
    echo Put dbug.bat either in opslabs-bodycam\tools\ or in opslabs-bodycam\ itself.
    pause
    exit /b 1
)

set CFG=config_server.lua
echo ============================================================
echo  Xon Sight bodycam diagnostic
echo  working in: %cd%
echo ============================================================
echo.

where curl >nul 2>nul
if errorlevel 1 (
    echo [ERROR] curl.exe not found on PATH. Install it from https://curl.se/windows/
    pause
    exit /b 1
)

REM --- best-effort parse of config_server.lua -----------------------------
REM (simple line-based parsing - if your file has these fields split across
REM  multiple lines or commented out above the real one, read the values it
REM  prints below and sanity-check them against the file yourself)
set "URL="
set "TOKEN="
set "KEY="
set "PUBLICURL="

for /f "tokens=2 delims='" %%A in ('findstr /r /c:"^[^-]*[ 	]Url *= *'" "%CFG%"') do if not defined URL set "URL=%%A"
for /f "tokens=2 delims='" %%A in ('findstr /r /c:"^[^-]*Token *= *'" "%CFG%"') do if not defined TOKEN set "TOKEN=%%A"
for /f "tokens=2 delims='" %%A in ('findstr /r /c:"^[^-]*Key *= *'" "%CFG%"') do if not defined KEY set "KEY=%%A"
for /f "tokens=2 delims='" %%A in ('findstr /r /c:"^[^-]*PublicUrl *= *'" "%CFG%"') do if not defined PUBLICURL set "PUBLICURL=%%A"

echo Config found:
echo   XonSight.Url        = %URL%
if defined TOKEN (echo   XonSight.Token       = ****%TOKEN:~-6%) else (echo   XonSight.Token       = ^(blank^))
if defined KEY (echo   XonSight.Key         = %KEY%) else (echo   XonSight.Key         = ^(blank^))
echo   Storage.PublicUrl    = %PUBLICURL%
echo.

if not defined URL (
    echo [ERROR] ServerConfig.XonSight.Url is blank or couldn't be parsed - nothing will upload. Set it first.
    pause
    exit /b 1
)
if not defined TOKEN if not defined KEY (
    echo [ERROR] Neither Token nor Key is set - every request will get refused with 401. Set one.
    pause
    exit /b 1
)

REM one auth header, matching XonSight's own priority (Token wins over Key)
if defined TOKEN (
    set "AUTHHEADER=X-XonSight-Token: %TOKEN%"
) else (
    set "AUTHHEADER=X-XonSight-Key: %KEY%"
)

REM --- sanity-check PublicUrl against known mistakes ----------------------
if defined PUBLICURL (
    if /i "%PUBLICURL%"=="%URL%" (
        echo [WARN] Storage.PublicUrl is the exact same as XonSight.Url - that's your
        echo        portal's own bare address, not a web server you run. The resource's
        echo        own startup check should already be ignoring this and uploading to
        echo        the portal instead - check your FXServer console for a line
        echo        starting "[opslabs-bodycam] ServerConfig.Storage.PublicUrl is set to
        echo        the Xon Sight portal's bare address" to confirm it kicked in.
    )
    echo %PUBLICURL% | findstr /c:".webm" >nul
    if not errorlevel 1 (
        echo [WARN] Storage.PublicUrl contains ".webm" - that looks like an old evidence
        echo        video link got pasted in here by mistake instead of a real base URL.
        echo        Every new recording's link will be built on top of that broken value.
    )
    echo.
)

REM --- 1. can we reach the portal at all -----------------------------------
echo [1/4] Reaching %URL% ...
curl -s -o nul -w "      HTTP %%{http_code}\n" --max-time 10 "%URL%/"
echo.

REM --- 2. does the token/key authenticate -----------------------------------
echo [2/4] Checking auth against /api/xonsight/features ...
curl -s -o "%TEMP%\xs_features.json" -w "      HTTP %%{http_code}\n" --max-time 10 -H "%AUTHHEADER%" "%URL%/api/xonsight/features"
echo       (200 = token/key accepted, 401 = wrong, anything else = unexpected - see below)
type "%TEMP%\xs_features.json"
echo.
echo.

REM --- 3. is the resource actually saving recordings to disk ----------------
echo [3/4] Looking for recordings in .\media ...
if not exist "media\*.webm" (
    echo [ERROR] No .webm files in media\ at all - the problem is upstream of any
    echo         upload/link config: the bodycam isn't producing recordings here yet.
    echo         Check F10/`/bodycam` actually starts a recording in-game, and watch
    echo         the FXServer console for errors from opslabs-bodycam while it does.
    echo.
    goto :skipupload
)
for /f %%A in ('dir /b /o-d media\*.webm ^| find /c /v ""') do set COUNT=%%A
echo       %COUNT% recording(s) found. Newest 3:
dir /b /o-d media\*.webm | more +0 | findstr /n "^" | findstr /r "^[1-3]:"
echo.

for /f "tokens=1" %%A in ('dir /b /o-d media\*.webm') do (
    set "NEWEST=%%A"
    goto :gotnewest
)
:gotnewest

REM --- 4. real test upload of the newest recording ---------------------------
echo [4/4] Test-uploading newest recording (%NEWEST%) to the portal ...
curl -s -o "%TEMP%\xs_upload.json" -w "      HTTP %%{http_code}\n" --max-time 60 ^
    -H "%AUTHHEADER%" ^
    -F "filename=%NEWEST%" ^
    -F "file=@media\%NEWEST%;type=video/webm" ^
    "%URL%/api/xonsight/media/upload"
echo       200 = upload path itself works fine (your issue is purely the link/
echo             PublicUrl config) · 401 = bad token/key · anything else, see below:
type "%TEMP%\xs_upload.json"
echo.

:skipupload
echo ============================================================
echo  Done. If step 4 said HTTP 200, the simplest fix is to set
echo  Storage.PublicUrl = '' (blank) in config_server.lua and restart -
echo  new recordings will upload straight to the portal from then on.
echo ============================================================
pause
