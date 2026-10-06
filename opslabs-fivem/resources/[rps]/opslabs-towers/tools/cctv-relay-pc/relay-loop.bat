@echo off
REM OPS Secure CCTV relay PC: keeps one FiveM game connected to the city so OPS Hub's cameras stay live.
REM The account that plays here must be listed in opslabs-towers config.lua -> Config.Cctv.RelayAccounts:
REM it then starts relaying by itself every time it joins (its character is hidden and frozen).
REM Put a shortcut to this file in shell:startup (Win+R, type shell:startup) so it runs when the PC logs in.

set SERVER=51.89.167.197:30120
set FIVEM=%LocalAppData%\FiveM\FiveM.exe

:loop
tasklist /FI "IMAGENAME eq FiveM_GTAProcess.exe" 2>NUL | find /I "FiveM_GTAProcess" >NUL
if errorlevel 1 (
    tasklist /FI "IMAGENAME eq FiveM.exe" 2>NUL | find /I "FiveM.exe" >NUL
    if errorlevel 1 (
        echo %date% %time% starting FiveM and joining %SERVER%
        start "" "%FIVEM%" +connect %SERVER%
    )
)
REM check again every 2 minutes: a crash or a kick just rejoins
timeout /t 120 /nobreak >NUL
goto loop
