@echo off
REM apply-remote-update.bat -- drops in the 3 files needed for the
REM kiosk to self-update over the network from stocktoolsetup.opslabsystems.cloud.
REM Run from the project ROOT (same folder as main.py, build.spec).
REM After it finishes, run make-msi.bat to rebuild the exe + msi.

setlocal DisableDelayedExpansion
cd /d "%~dp0"

if not exist "main.py" (
    echo ERROR: main.py not found in this folder.
    echo Run apply-remote-update.bat from the project root.
    pause
    exit /b 1
)

set "TMPDIR=%TEMP%\stocktool_update_deploy"
if exist "%TMPDIR%" rmdir /s /q "%TMPDIR%" >nul 2>&1
mkdir "%TMPDIR%"

if exist "server_supervisor.py" (
    echo Backing up existing server_supervisor.py...
    copy /Y "server_supervisor.py" "server_supervisor.py.bak" >nul
)

echo Writing update_checker.py ...
if exist "%TMPDIR%\update_checker.b64" del "%TMPDIR%\update_checker.b64" >nul 2>&1
echo IiIiCkxpZ2h0d2VpZ2h0IHJlbW90ZS11cGRhdGUgY2hlY2tlciAtLSB0YWxrcyBPTkxZIHRvCnN0>>"%TMPDIR%\update_checker.b64"
echo b2NrdG9vbHNldHVwLm9wc2xhYnN5c3RlbXMuY2xvdWQncyAvYXBpL3VwZGF0ZXMvbGF0ZXN0IGFu>>"%TMPDIR%\update_checker.b64"
echo ZAovYXBpL3VwZGF0ZXMvZG93bmxvYWQsIHVzaW5nIHRoZSBzYW1lIGluc3RhbGxhdGlvbl90b2tl>>"%TMPDIR%\update_checker.b64"
echo biBhbHJlYWR5CnNhdmVkIGZyb20gcGFpcmluZyAoc2VlIGFwcC9jbG91ZF9zZXR1cC5weSkgLS0g>>"%TMPDIR%\update_checker.b64"
echo bm8gc2VwYXJhdGUKcmVnaXN0cmF0aW9uLCBoZWFydGJlYXQsIG9yIGZ1bGwgaXRlbS90b29sIGRh>>"%TMPDIR%\update_checker.b64"
echo dGEtc3luYyBpbnZvbHZlZC4KCkRlbGliZXJhdGVseSBkb2VzIG5vdCByZXVzZSBhcHAvc3luY19l>>"%TMPDIR%\update_checker.b64"
echo bmdpbmUucHkncyBTeW5jRW5naW5lLCB3aGljaCBpcwpidWlsdCBhZ2FpbnN0IHRoZSBtdWNoIGxh>>"%TMPDIR%\update_checker.b64"
echo cmdlciAobmV2ZXItYnVpbHQpIGZ1bGwgY2xvdWQtc3luYyBBUEkgLS0KdGhpcyBvbmx5IG5lZWRz>>"%TMPDIR%\update_checker.b64"
echo IHVwZGF0ZS1jaGVja2luZywgYW5kIHVwZGF0ZXIucHkgLyBhcHAvdXBkYXRlX25vdGlmaWVyLnB5>>"%TMPDIR%\update_checker.b64"
echo CmFscmVhZHkgZG8gMTAwJSBvZiB0aGUgYWN0dWFsIGRvd25sb2FkL3ZlcmlmeS9hcHBseSB3b3Jr>>"%TMPDIR%\update_checker.b64"
echo IHJlZ2FyZGxlc3Mgb2YKd2hlcmUgdGhlIHJlbGVhc2UgbWV0YWRhdGEgY29tZXMgZnJvbS4KIiIi>>"%TMPDIR%\update_checker.b64"
echo CmltcG9ydCBsb2dnaW5nCgppbXBvcnQgcmVxdWVzdHMKCmxvZyA9IGxvZ2dpbmcuZ2V0TG9nZ2Vy>>"%TMPDIR%\update_checker.b64"
echo KCJ1cGRhdGVfY2hlY2tlciIpCgoKY2xhc3MgVXBkYXRlQ2hlY2tlcjoKICAgIGRlZiBfX2luaXRf>>"%TMPDIR%\update_checker.b64"
echo XyhzZWxmLCBhcHApOgogICAgICAgIHNlbGYuYXBwID0gYXBwCgogICAgZGVmIGNoZWNrX2Zvcl91>>"%TMPDIR%\update_checker.b64"
echo cGRhdGUoc2VsZik6CiAgICAgICAgZnJvbSBhcHAuc2V0dGluZ3MgaW1wb3J0IGxvYWRfc2V0dGlu>>"%TMPDIR%\update_checker.b64"
echo Z3MKICAgICAgICBzZXR0aW5ncyA9IGxvYWRfc2V0dGluZ3Moc2VsZi5hcHAuY29uZmlnWyJEQVRB>>"%TMPDIR%\update_checker.b64"
echo X0RJUiJdKQogICAgICAgIGJhc2UgPSBzZXR0aW5ncy5nZXQoInNldHVwX2FwaV9iYXNlIiwgImh0>>"%TMPDIR%\update_checker.b64"
echo dHBzOi8vc3RvY2t0b29sc2V0dXAub3BzbGFic3lzdGVtcy5jbG91ZCIpLnJzdHJpcCgiLyIpCiAg>>"%TMPDIR%\update_checker.b64"
echo ICAgICAgdG9rZW4gPSBzZXR0aW5ncy5nZXQoInNldHVwX2luc3RhbGxhdGlvbl90b2tlbiIpCiAg>>"%TMPDIR%\update_checker.b64"
echo ICAgICAgaWYgbm90IHRva2VuOgogICAgICAgICAgICByZXR1cm4gTm9uZSAgIyBub3QgcGFpcmVk>>"%TMPDIR%\update_checker.b64"
echo IHdpdGggc3RvY2t0b29sc2V0dXAgeWV0IC0tIG5vdGhpbmcgdG8gY2hlY2sgYWdhaW5zdAoKICAg>>"%TMPDIR%\update_checker.b64"
echo ICAgICB0cnk6CiAgICAgICAgICAgIHJlc3AgPSByZXF1ZXN0cy5nZXQoCiAgICAgICAgICAgICAg>>"%TMPDIR%\update_checker.b64"
echo ICBmIntiYXNlfS9hcGkvdXBkYXRlcy9sYXRlc3QiLAogICAgICAgICAgICAgICAgaGVhZGVycz17>>"%TMPDIR%\update_checker.b64"
echo IkF1dGhvcml6YXRpb24iOiBmIkJlYXJlciB7dG9rZW59In0sCiAgICAgICAgICAgICAgICB0aW1l>>"%TMPDIR%\update_checker.b64"
echo b3V0PTEwLAogICAgICAgICAgICApCiAgICAgICAgICAgIGlmIHJlc3Auc3RhdHVzX2NvZGUgPT0g>>"%TMPDIR%\update_checker.b64"
echo NDA0OgogICAgICAgICAgICAgICAgcmV0dXJuIE5vbmUgICMgbm8gcmVsZWFzZSBwdWJsaXNoZWQg>>"%TMPDIR%\update_checker.b64"
echo eWV0IC0tIG5vdCBhbiBlcnJvcgogICAgICAgICAgICByZXNwLnJhaXNlX2Zvcl9zdGF0dXMoKQog>>"%TMPDIR%\update_checker.b64"
echo ICAgICAgICAgICByZXR1cm4gcmVzcC5qc29uKCkKICAgICAgICBleGNlcHQgRXhjZXB0aW9uOgog>>"%TMPDIR%\update_checker.b64"
echo ICAgICAgICAgICBsb2cuZXhjZXB0aW9uKCJVcGRhdGUgY2hlY2sgZmFpbGVkIikKICAgICAgICAg>>"%TMPDIR%\update_checker.b64"
echo ICAgcmV0dXJuIE5vbmUK>>"%TMPDIR%\update_checker.b64"
certutil -decode "%TMPDIR%\update_checker.b64" "update_checker.py"
if not "%errorlevel%"=="0" (
    echo ERROR: failed to write update_checker.py -- see certutil output above.
    pause
    exit /b 1
)

echo Writing update_check_loop.py ...
if exist "%TMPDIR%\update_check_loop.b64" del "%TMPDIR%\update_check_loop.b64" >nul 2>&1
echo IiIiClBlcmlvZGljIGJhY2tncm91bmQgbG9vcDogY2hlY2tzIHN0b2NrdG9vbHNldHVwLm9wc2xh>>"%TMPDIR%\update_check_loop.b64"
echo YnN5c3RlbXMuY2xvdWQKZm9yIGEgbmV3ZXIgcHVibGlzaGVkIGJ1aWxkICh2aWEgdXBkYXRlX2No>>"%TMPDIR%\update_check_loop.b64"
echo ZWNrZXIucHkpIGFuZCwgaWYgdmVyaWZpZWQsCmhhbmRzIG9mZiB0byB1cGRhdGVyLnB5IC8gYXBw>>"%TMPDIR%\update_check_loop.b64"
echo L3VwZGF0ZV9ub3RpZmllci5weSB0byBhcHBseSBpdCB3aXRoIGEKd2FybmluZyBjb3VudGRvd24g>>"%TMPDIR%\update_check_loop.b64"
echo LS0gdGhlIGV4YWN0IHNhbWUgYXBwbHkgbWVjaGFuaXNtIHN5bmNfbG9vcC5weSdzCl9tYXliZV9h>>"%TMPDIR%\update_check_loop.b64"
echo cHBseV91cGRhdGUgdXNlcyBmb3IgdGhlIChkb3JtYW50KSBmdWxsLXN5bmMgcGF0aCwganVzdCBm>>"%TMPDIR%\update_check_loop.b64"
echo ZWQgYnkKVXBkYXRlQ2hlY2tlciBpbnN0ZWFkIG9mIFN5bmNFbmdpbmUuCgpOby1vcHMgZW50aXJl>>"%TMPDIR%\update_check_loop.b64"
echo bHkgdW50aWwgcGFpcmVkIHdpdGggc3RvY2t0b29sc2V0dXAgLS0gc2FtZQpkb3JtYW50LXVudGls>>"%TMPDIR%\update_check_loop.b64"
echo LWNvbmZpZ3VyZWQgcGF0dGVybiBhcyBiYWNrdXBfbG9vcC5weSBhbmQgcmVsYXlfY2xpZW50LnB5>>"%TMPDIR%\update_check_loop.b64"
echo Ci0tIHNvIGl0J3MgYWx3YXlzIHNhZmUgdG8gc3RhcnQgdW5jb25kaXRpb25hbGx5LgoiIiIKaW1w>>"%TMPDIR%\update_check_loop.b64"
echo b3J0IG9zCmltcG9ydCB0aHJlYWRpbmcKaW1wb3J0IHRpbWUKaW1wb3J0IGxvZ2dpbmcKCmxvZyA9>>"%TMPDIR%\update_check_loop.b64"
echo IGxvZ2dpbmcuZ2V0TG9nZ2VyKCJ1cGRhdGVfY2hlY2tfbG9vcCIpCgpDSEVDS19JTlRFUlZBTF9T>>"%TMPDIR%\update_check_loop.b64"
echo RUNPTkRTID0gMjE2MDAgICMgNmggLS0gbWF0Y2hlcyB0aGUgZXhpc3RpbmcgYmFja3VwIGNhZGVu>>"%TMPDIR%\update_check_loop.b64"
echo Y2UKCgpkZWYgX2NoZWNrX29uY2UoYXBwKToKICAgIGZyb20gdmVyc2lvbiBpbXBvcnQgX192ZXJz>>"%TMPDIR%\update_check_loop.b64"
echo aW9uX18sIGlzX25ld2VyCiAgICBmcm9tIHVwZGF0ZXIgaW1wb3J0IGRvd25sb2FkX3VwZGF0ZSwg>>"%TMPDIR%\update_check_loop.b64"
echo dmVyaWZ5X2NoZWNrc3VtLCBhcHBseV91cGRhdGUsIF9jdXJyZW50X2V4ZV9wYXRoCiAgICBmcm9t>>"%TMPDIR%\update_check_loop.b64"
echo IGFwcC51cGRhdGVfbm90aWZpZXIgaW1wb3J0IHNjaGVkdWxlX3VwZGF0ZSwgZ2V0X3N0YXR1cwog>>"%TMPDIR%\update_check_loop.b64"
echo ICAgZnJvbSB1cGRhdGVfY2hlY2tlciBpbXBvcnQgVXBkYXRlQ2hlY2tlcgoKICAgIGlmIGdldF9z>>"%TMPDIR%\update_check_loop.b64"
echo dGF0dXMoKVsicGVuZGluZyJdOgogICAgICAgIHJldHVybiAgIyBhbHJlYWR5IGNvdW50aW5nIGRv>>"%TMPDIR%\update_check_loop.b64"
echo d24gdG8gYSBwcmV2aW91c2x5LXZlcmlmaWVkIHVwZGF0ZQoKICAgIGNoZWNrZXIgPSBVcGRhdGVD>>"%TMPDIR%\update_check_loop.b64"
echo aGVja2VyKGFwcCkKICAgIHJlbGVhc2UgPSBjaGVja2VyLmNoZWNrX2Zvcl91cGRhdGUoKQogICAg>>"%TMPDIR%\update_check_loop.b64"
echo aWYgbm90IHJlbGVhc2Ugb3Igbm90IGlzX25ld2VyKHJlbGVhc2UuZ2V0KCJ2ZXJzaW9uIiwgIjAi>>"%TMPDIR%\update_check_loop.b64"
echo KSwgX192ZXJzaW9uX18pOgogICAgICAgIHJldHVybgoKICAgIGxvZy5pbmZvKCJVcGRhdGUgYXZh>>"%TMPDIR%\update_check_loop.b64"
echo aWxhYmxlOiAlcyAtPiAlcyIsIF9fdmVyc2lvbl9fLCByZWxlYXNlWyJ2ZXJzaW9uIl0pCiAgICBl>>"%TMPDIR%\update_check_loop.b64"
echo eGVfZGlyID0gb3MucGF0aC5kaXJuYW1lKF9jdXJyZW50X2V4ZV9wYXRoKCkpCiAgICBuZXdfcGF0>>"%TMPDIR%\update_check_loop.b64"
echo aCA9IG9zLnBhdGguam9pbihleGVfZGlyLCAiU3RvY2tUb29sS2lvc2tfbmV3LmV4ZSIpCgogICAg>>"%TMPDIR%\update_check_loop.b64"
echo aWYgbm90IGRvd25sb2FkX3VwZGF0ZShyZWxlYXNlWyJkb3dubG9hZF91cmwiXSwgbmV3X3BhdGgp>>"%TMPDIR%\update_check_loop.b64"
echo OgogICAgICAgIHJldHVybgoKICAgIGlmIG5vdCB2ZXJpZnlfY2hlY2tzdW0obmV3X3BhdGgsIHJl>>"%TMPDIR%\update_check_loop.b64"
echo bGVhc2UuZ2V0KCJjaGVja3N1bV9zaGEyNTYiLCAiIikpOgogICAgICAgIG9zLnJlbW92ZShuZXdf>>"%TMPDIR%\update_check_loop.b64"
echo cGF0aCkKICAgICAgICBsb2cuZXJyb3IoIlVwZGF0ZSAlcyBmYWlsZWQgY2hlY2tzdW0gdmVyaWZp>>"%TMPDIR%\update_check_loop.b64"
echo Y2F0aW9uIC0tIGRpc2NhcmRlZC4iLCByZWxlYXNlWyJ2ZXJzaW9uIl0pCiAgICAgICAgcmV0dXJu>>"%TMPDIR%\update_check_loop.b64"
echo CgogICAgbG9nLmluZm8oIlVwZGF0ZSAlcyB2ZXJpZmllZCAtLSBzY2hlZHVsaW5nIGFwcGx5IHdp>>"%TMPDIR%\update_check_loop.b64"
echo dGggYSB3YXJuaW5nIGNvdW50ZG93bi4iLCByZWxlYXNlWyJ2ZXJzaW9uIl0pCiAgICBzY2hlZHVs>>"%TMPDIR%\update_check_loop.b64"
echo ZV91cGRhdGUobmV3X3BhdGgsIHJlbGVhc2VbInZlcnNpb24iXSwgYXBwbHlfdXBkYXRlKQoKCmRl>>"%TMPDIR%\update_check_loop.b64"
echo ZiBzdGFydF91cGRhdGVfY2hlY2tfbG9vcChhcHApIC0+IHRocmVhZGluZy5UaHJlYWQ6CiAgICBk>>"%TMPDIR%\update_check_loop.b64"
echo ZWYgbG9vcCgpOgogICAgICAgIHdoaWxlIFRydWU6CiAgICAgICAgICAgIHRyeToKICAgICAgICAg>>"%TMPDIR%\update_check_loop.b64"
echo ICAgICAgIF9jaGVja19vbmNlKGFwcCkKICAgICAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAg>>"%TMPDIR%\update_check_loop.b64"
echo ICAgICAgICAgICAgIGxvZy5leGNlcHRpb24oIlVwZGF0ZSBjaGVjayBjeWNsZSBmYWlsZWQgdW5l>>"%TMPDIR%\update_check_loop.b64"
echo eHBlY3RlZGx5IikKICAgICAgICAgICAgdGltZS5zbGVlcChDSEVDS19JTlRFUlZBTF9TRUNPTkRT>>"%TMPDIR%\update_check_loop.b64"
echo KQoKICAgIHQgPSB0aHJlYWRpbmcuVGhyZWFkKHRhcmdldD1sb29wLCBkYWVtb249VHJ1ZSwgbmFt>>"%TMPDIR%\update_check_loop.b64"
echo ZT0iVXBkYXRlQ2hlY2tMb29wIikKICAgIHQuc3RhcnQoKQogICAgcmV0dXJuIHQK>>"%TMPDIR%\update_check_loop.b64"
certutil -decode "%TMPDIR%\update_check_loop.b64" "update_check_loop.py"
if not "%errorlevel%"=="0" (
    echo ERROR: failed to write update_check_loop.py -- see certutil output above.
    pause
    exit /b 1
)

echo Writing server_supervisor.py ...
if exist "%TMPDIR%\server_supervisor.b64" del "%TMPDIR%\server_supervisor.b64" >nul 2>&1
echo IiIiClN0b2NrVG9vbCBLaW9zayAodjIpIOKAlCBjcmFzaC1yZXNpbGllbmNlIHN1cGVydmlzb3Iu>>"%TMPDIR%\server_supervisor.b64"
echo CgpSdW5zIHRoZSBlbWJlZGRlZCBGbGFzayBBUEkgaW4gYSBiYWNrZ3JvdW5kIHRocmVhZCBhbmQg>>"%TMPDIR%\server_supervisor.b64"
echo cmVzdGFydHMgaXQKYXV0b21hdGljYWxseSBpZiBpdCBldmVyIGRpZXMgKHVuY2F1Z2h0IGV4Y2Vw>>"%TMPDIR%\server_supervisor.b64"
echo dGlvbiwgZHJvcHBlZCBwb3J0LCBldGMuKSwKd2l0aG91dCByZXF1aXJpbmcgYSBXaW5kb3dzIFNl>>"%TMPDIR%\server_supervisor.b64"
echo cnZpY2UgaW5zdGFsbCBvciBhZG1pbiByaWdodHMuIFRoaXMgaXMKd2hhdCBtYWluLnB5IGltcG9y>>"%TMPDIR%\server_supervisor.b64"
echo dHMgYW5kIGRyaXZlcy4KCk5PVEUgT04gVEhFIEZJTEVOQU1FOiB0aGlzIHVzZWQgdG8gYmUgd2F0>>"%TMPDIR%\server_supervisor.b64"
echo Y2hkb2cucHksIGJ1dCB0aGF0IGNvbGxpZGVzCndpdGggdGhlIHJlYWwgIndhdGNoZG9nIiBwYWNr>>"%TMPDIR%\server_supervisor.b64"
echo YWdlIG9uIFB5UEkgKGZpbGVzeXN0ZW0tY2hhbmdlIG1vbml0b3JpbmcKLS0gdW5yZWxhdGVkIHRv>>"%TMPDIR%\server_supervisor.b64"
echo IHRoaXMgZmlsZSwgYnV0IGEgY29tbW9uIHRyYW5zaXRpdmUgZGVwZW5kZW5jeSBvZiBkZXYKdG9v>>"%TMPDIR%\server_supervisor.b64"
echo bGluZykuIElmIHRoYXQgcGFja2FnZSBpcyBwcmVzZW50IGluIHRoZSBidWlsZCB2ZW52LCBQeUlu>>"%TMPDIR%\server_supervisor.b64"
echo c3RhbGxlcidzCmltcG9ydCBhbmFseXNpcyBjYW4gZ2V0IGNvbmZ1c2VkIGJ5IHRoZSBuYW1lIGNs>>"%TMPDIR%\server_supervisor.b64"
echo YXNoIGFuZCBzaWxlbnRseSBkcm9wCnRoaXMgZmlsZSBmcm9tIHRoZSBmcm96ZW4gZXhlIGluc3Rl>>"%TMPDIR%\server_supervisor.b64"
echo YWQgb2YgdGhlIHJlYWwgcGFja2FnZSAod2hpY2gKZG9lc24ndCBoYXZlIGEgU3VwZXJ2aXNvciBj>>"%TMPDIR%\server_supervisor.b64"
echo bGFzcyBlaXRoZXIsIHNvIG5laXRoZXIgY2hvaWNlIHdvdWxkIGhhdmUKd29ya2VkKSAtLSBwcm9k>>"%TMPDIR%\server_supervisor.b64"
echo dWNpbmcgIk1vZHVsZU5vdEZvdW5kRXJyb3I6IE5vIG1vZHVsZSBuYW1lZCAnd2F0Y2hkb2cnIgph>>"%TMPDIR%\server_supervisor.b64"
echo dCBydW50aW1lIGRlc3BpdGUgdGhpcyBmaWxlIGNsZWFybHkgZXhpc3RpbmcgcmlnaHQgbmV4dCB0>>"%TMPDIR%\server_supervisor.b64"
echo byBtYWluLnB5LgpSZW5hbWVkIHRvIHNlcnZlcl9zdXBlcnZpc29yLnB5IHRvIG1ha2UgdGhlIGNv>>"%TMPDIR%\server_supervisor.b64"
echo bGxpc2lvbiBpbXBvc3NpYmxlIHJhdGhlcgp0aGFuIGRlcGVuZCBvbiB2ZW52IGNvbnRlbnRzL1B5>>"%TMPDIR%\server_supervisor.b64"
echo SW5zdGFsbGVyJ3MgcmVzb2x1dGlvbiBvcmRlci4KIiIiCmltcG9ydCB0aW1lCmltcG9ydCBsb2dn>>"%TMPDIR%\server_supervisor.b64"
echo aW5nCgpmcm9tIHdhaXRyZXNzIGltcG9ydCBzZXJ2ZQoKbG9nID0gbG9nZ2luZy5nZXRMb2dnZXIo>>"%TMPDIR%\server_supervisor.b64"
echo InNlcnZlcl9zdXBlcnZpc29yIikKClJFU1RBUlRfQkFDS09GRl9TRUNPTkRTID0gMgpNQVhfQ09O>>"%TMPDIR%\server_supervisor.b64"
echo U0VDVVRJVkVfRkFJTFVSRVMgPSAxMCAgIyBnaXZlIHVwIHNwYW1taW5nIHJlc3RhcnRzIGlmIHNv>>"%TMPDIR%\server_supervisor.b64"
echo bWV0aGluZyBpcyBmdW5kYW1lbnRhbGx5IGJyb2tlbgoKCmNsYXNzIFN1cGVydmlzb3I6CiAgICBk>>"%TMPDIR%\server_supervisor.b64"
echo ZWYgX19pbml0X18oc2VsZiwgaG9zdDogc3RyIHwgTm9uZSA9IE5vbmUsIHBvcnQ6IGludCB8IE5v>>"%TMPDIR%\server_supervisor.b64"
echo bmUgPSBOb25lKToKICAgICAgICAjIGhvc3QvcG9ydCBwYXNzZWQgZXhwbGljaXRseSAoZS5nLiBi>>"%TMPDIR%\server_supervisor.b64"
echo eSB0ZXN0cykgb3ZlcnJpZGUgd2hhdGV2ZXIKICAgICAgICAjIHNldHRpbmdzLmpzb24gc2F5czsg>>"%TMPDIR%\server_supervisor.b64"
echo b3RoZXJ3aXNlIHJlc29sdmVkIGZyb20gc2V0dGluZ3MgYXQgZWFjaAogICAgICAgICMgcnVuIHNv>>"%TMPDIR%\server_supervisor.b64"
echo IGEgY29uZmlnIGNoYW5nZSBwaWNrZWQgdXAgYmV0d2VlbiBjcmFzaC1yZXN0YXJ0cyAob3Igdmlh>>"%TMPDIR%\server_supervisor.b64"
echo CiAgICAgICAgIyB0aGUgU2V0dXAgV2l6YXJkIHdoaWxlIHRoZSBzZXJ2aWNlIGlzIHN0b3BwZWQp>>"%TMPDIR%\server_supervisor.b64"
echo IHRha2VzIGVmZmVjdAogICAgICAgICMgd2l0aG91dCByZWJ1aWxkaW5nIHRoZSAuZXhlLgogICAg>>"%TMPDIR%\server_supervisor.b64"
echo ICAgIHNlbGYuX2hvc3Rfb3ZlcnJpZGUgPSBob3N0CiAgICAgICAgc2VsZi5fcG9ydF9vdmVycmlk>>"%TMPDIR%\server_supervisor.b64"
echo ZSA9IHBvcnQKCiAgICBkZWYgX3J1bl9vbmNlKHNlbGYpOgogICAgICAgICIiIkJ1aWxkcyBhbmQg>>"%TMPDIR%\server_supervisor.b64"
echo cnVucyB0aGUgRmxhc2sgYXBwLiBCbG9ja3MgdW50aWwgdGhlIHNlcnZlciB0aHJlYWQKICAgICAg>>"%TMPDIR%\server_supervisor.b64"
echo ICBleGl0cyAoY3Jhc2ggb3Igbm9ybWFsIHNodXRkb3duKS4iIiIKICAgICAgICBmcm9tIGFwcCBp>>"%TMPDIR%\server_supervisor.b64"
echo bXBvcnQgY3JlYXRlX2FwcAogICAgICAgIGZyb20gYXBwLnNldHRpbmdzIGltcG9ydCBsb2FkX3Nl>>"%TMPDIR%\server_supervisor.b64"
echo dHRpbmdzLCByZXNvbHZlX2JpbmRfaG9zdAogICAgICAgIGZyb20gc3luY19sb29wIGltcG9ydCBz>>"%TMPDIR%\server_supervisor.b64"
echo dGFydF9zeW5jX2xvb3AKICAgICAgICBmcm9tIGJhY2t1cF9sb29wIGltcG9ydCBzdGFydF9iYWNr>>"%TMPDIR%\server_supervisor.b64"
echo dXBfbG9vcAogICAgICAgIGZyb20gcmVsYXlfY2xpZW50IGltcG9ydCBzdGFydF9yZWxheV9jbGll>>"%TMPDIR%\server_supervisor.b64"
echo bnQKICAgICAgICBmcm9tIHVwZGF0ZV9jaGVja19sb29wIGltcG9ydCBzdGFydF91cGRhdGVfY2hl>>"%TMPDIR%\server_supervisor.b64"
echo Y2tfbG9vcAoKICAgICAgICBhcHAgPSBjcmVhdGVfYXBwKCkKCiAgICAgICAgc2V0dGluZ3MgPSBs>>"%TMPDIR%\server_supervisor.b64"
echo b2FkX3NldHRpbmdzKGFwcC5jb25maWdbIkRBVEFfRElSIl0pCiAgICAgICAgaG9zdCA9IHNlbGYu>>"%TMPDIR%\server_supervisor.b64"
echo X2hvc3Rfb3ZlcnJpZGUgb3IgcmVzb2x2ZV9iaW5kX2hvc3Qoc2V0dGluZ3MpCiAgICAgICAgcG9y>>"%TMPDIR%\server_supervisor.b64"
echo dCA9IHNlbGYuX3BvcnRfb3ZlcnJpZGUgb3Igc2V0dGluZ3MuZ2V0KCJwb3J0IiwgODQyMCkKICAg>>"%TMPDIR%\server_supervisor.b64"
echo ICAgICBiaW5kX21vZGUgPSBzZXR0aW5ncy5nZXQoImJpbmRfbW9kZSIsICJsb2NhbCIpCgogICAg>>"%TMPDIR%\server_supervisor.b64"
echo ICAgIGlmIGJpbmRfbW9kZSA9PSAicHVibGljIjoKICAgICAgICAgICAgbG9nLndhcm5pbmcoCiAg>>"%TMPDIR%\server_supervisor.b64"
echo ICAgICAgICAgICAgICAiYmluZF9tb2RlPXB1YmxpYyDigJQgbGlzdGVuaW5nIG9uICVzOiVkLCBy>>"%TMPDIR%\server_supervisor.b64"
echo ZWFjaGFibGUgZnJvbSAiCiAgICAgICAgICAgICAgICAib3V0c2lkZSB0aGlzIG1hY2hpbmUuIE1v>>"%TMPDIR%\server_supervisor.b64"
echo c3QgQVBJIHJvdXRlcyBoYXZlIG5vICIKICAgICAgICAgICAgICAgICJhdXRoZW50aWNhdGlvbjsg>>"%TMPDIR%\server_supervisor.b64"
echo bWFrZSBzdXJlIHRoYXQncyBpbnRlbnRpb25hbC4iLAogICAgICAgICAgICAgICAgaG9zdCwgcG9y>>"%TMPDIR%\server_supervisor.b64"
echo dCwKICAgICAgICAgICAgKQogICAgICAgIGVsaWYgYmluZF9tb2RlID09ICJ0dW5uZWwiOgogICAg>>"%TMPDIR%\server_supervisor.b64"
echo ICAgICAgICBsb2cuaW5mbygKICAgICAgICAgICAgICAgICJiaW5kX21vZGU9dHVubmVsIOKAlCBB>>"%TMPDIR%\server_supervisor.b64"
echo UEkgb24gMTI3LjAuMC4xOiVkOyB0aGUgQ2xvdWRmbGFyZWQgIgogICAgICAgICAgICAgICAgIldp>>"%TMPDIR%\server_supervisor.b64"
echo bmRvd3Mgc2VydmljZSAoaWYgaW5zdGFsbGVkKSBpcyB3aGF0IGV4cG9zZXMgaXQgIgogICAgICAg>>"%TMPDIR%\server_supervisor.b64"
echo ICAgICAgICAgImV4dGVybmFsbHkuIiwgcG9ydCwKICAgICAgICAgICAgKQoKICAgICAgICAjIFN5>>"%TMPDIR%\server_supervisor.b64"
echo bmMgZW5naW5lIGlzIGF0dGFjaGVkIHRvIHRoZSBhcHAgY29uZmlnIGJ5IGNyZWF0ZV9hcHAoKSB3>>"%TMPDIR%\server_supervisor.b64"
echo aGVuCiAgICAgICAgIyBjbG91ZCBjcmVkZW50aWFscy9jb25maWcgYXJlIGF2YWlsYWJsZTsgc3lu>>"%TMPDIR%\server_supervisor.b64"
echo YyBsb29wIG5vLW9wcyBzYWZlbHkKICAgICAgICAjIGlmIGl0IGlzbid0LgogICAgICAgIGlmIGFw>>"%TMPDIR%\server_supervisor.b64"
echo cC5jb25maWcuZ2V0KCJTWU5DX0VOR0lORSIpOgogICAgICAgICAgICBzdGFydF9zeW5jX2xvb3Ao>>"%TMPDIR%\server_supervisor.b64"
echo YXBwKQogICAgICAgIGVsc2U6CiAgICAgICAgICAgIGxvZy53YXJuaW5nKCJObyBTWU5DX0VOR0lO>>"%TMPDIR%\server_supervisor.b64"
echo RSBjb25maWd1cmVkIOKAlCBydW5uaW5nIG9mZmxpbmUtb25seSwgbm8gY2xvdWQgc3luYyB0aGlz>>"%TMPDIR%\server_supervisor.b64"
echo IHJ1bi4iKQoKICAgICAgICAjIEJhY2t1cCBsb29wLCByZWxheSBjbGllbnQsIGFuZCB0aGUgdXBk>>"%TMPDIR%\server_supervisor.b64"
echo YXRlLWNoZWNrIGxvb3AgYWxsIG5vLW9wCiAgICAgICAgIyBpbnRlcm5hbGx5IHVudGlsIGFwcC9j>>"%TMPDIR%\server_supervisor.b64"
echo bG91ZF9zZXR1cC5weSBoYXMgcGFpcmVkIHRoaXMga2lvc2suCiAgICAgICAgc3RhcnRfYmFja3Vw>>"%TMPDIR%\server_supervisor.b64"
echo X2xvb3AoYXBwKQogICAgICAgIHN0YXJ0X3JlbGF5X2NsaWVudChhcHApCiAgICAgICAgc3RhcnRf>>"%TMPDIR%\server_supervisor.b64"
echo dXBkYXRlX2NoZWNrX2xvb3AoYXBwKQoKICAgICAgICBzZWxmLmhvc3QsIHNlbGYucG9ydCA9IGhv>>"%TMPDIR%\server_supervisor.b64"
echo c3QsIHBvcnQKCiAgICAgICAgIyB3YWl0cmVzcyBpbnN0ZWFkIG9mIEZsYXNrJ3MgZGV2IHNlcnZl>>"%TMPDIR%\server_supervisor.b64"
echo cjogdGhlIGRldiBzZXJ2ZXIgbG9ncyBhCiAgICAgICAgIyBsb3VkICJkbyBub3QgdXNlIGluIHBy>>"%TMPDIR%\server_supervisor.b64"
echo b2R1Y3Rpb24iIHdhcm5pbmcgYW5kIGlzbid0IG1lYW50IHRvIHRha2UKICAgICAgICAjIHVudHJ1>>"%TMPDIR%\server_supervisor.b64"
echo c3RlZCB0cmFmZmljLCB3aGljaCBtYXR0ZXJzIGFzIHNvb24gYXMgYmluZF9tb2RlIGlzCiAgICAg>>"%TMPDIR%\server_supervisor.b64"
echo ICAgIyAidHVubmVsIiBvciAicHVibGljIiAoaXQncyBoYXJtbGVzcyBidXQgb3ZlcmtpbGwgZm9y>>"%TMPDIR%\server_supervisor.b64"
echo ICJsb2NhbCIpLgogICAgICAgIHNlcnZlKGFwcCwgaG9zdD1ob3N0LCBwb3J0PXBvcnQsIHRocmVh>>"%TMPDIR%\server_supervisor.b64"
echo ZHM9OCkKCiAgICBkZWYgcnVuX2ZvcmV2ZXIoc2VsZik6CiAgICAgICAgY29uc2VjdXRpdmVfZmFp>>"%TMPDIR%\server_supervisor.b64"
echo bHVyZXMgPSAwCiAgICAgICAgd2hpbGUgVHJ1ZToKICAgICAgICAgICAgdHJ5OgogICAgICAgICAg>>"%TMPDIR%\server_supervisor.b64"
echo ICAgICAgc2VsZi5fcnVuX29uY2UoKQogICAgICAgICAgICAgICAgIyBhcHAucnVuKCkgcmV0dXJu>>"%TMPDIR%\server_supervisor.b64"
echo aW5nIG5vcm1hbGx5IG1lYW5zIGEgY2xlYW4gc2h1dGRvd24gd2FzCiAgICAgICAgICAgICAgICAj>>"%TMPDIR%\server_supervisor.b64"
echo IHJlcXVlc3RlZCBzb21ld2hlcmUg4oCUIGRvbid0IHRyZWF0IHRoYXQgYXMgYSBjcmFzaC4KICAg>>"%TMPDIR%\server_supervisor.b64"
echo ICAgICAgICAgICAgIGxvZy5pbmZvKCJTZXJ2ZXIgc3RvcHBlZCBjbGVhbmx5LiIpCiAgICAgICAg>>"%TMPDIR%\server_supervisor.b64"
echo ICAgICAgICByZXR1cm4KICAgICAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICAgICAg>>"%TMPDIR%\server_supervisor.b64"
echo ICAgIGNvbnNlY3V0aXZlX2ZhaWx1cmVzICs9IDEKICAgICAgICAgICAgICAgIGxvZy5leGNlcHRp>>"%TMPDIR%\server_supervisor.b64"
echo b24oCiAgICAgICAgICAgICAgICAgICAgIkVtYmVkZGVkIHNlcnZlciBjcmFzaGVkIChmYWlsdXJl>>"%TMPDIR%\server_supervisor.b64"
echo ICMlZCkg4oCUIHJlc3RhcnRpbmcgaW4gJWRzLiIsCiAgICAgICAgICAgICAgICAgICAgY29uc2Vj>>"%TMPDIR%\server_supervisor.b64"
echo dXRpdmVfZmFpbHVyZXMsIFJFU1RBUlRfQkFDS09GRl9TRUNPTkRTLAogICAgICAgICAgICAgICAg>>"%TMPDIR%\server_supervisor.b64"
echo KQogICAgICAgICAgICAgICAgaWYgY29uc2VjdXRpdmVfZmFpbHVyZXMgPj0gTUFYX0NPTlNFQ1VU>>"%TMPDIR%\server_supervisor.b64"
echo SVZFX0ZBSUxVUkVTOgogICAgICAgICAgICAgICAgICAgIGxvZy5jcml0aWNhbCgKICAgICAgICAg>>"%TMPDIR%\server_supervisor.b64"
echo ICAgICAgICAgICAgICAgIlNlcnZlciBjcmFzaGVkICVkIHRpbWVzIGluIGEgcm93IOKAlCBnaXZp>>"%TMPDIR%\server_supervisor.b64"
echo bmcgdXAgYXV0by1yZXN0YXJ0LiIsCiAgICAgICAgICAgICAgICAgICAgICAgIGNvbnNlY3V0aXZl>>"%TMPDIR%\server_supervisor.b64"
echo X2ZhaWx1cmVzLAogICAgICAgICAgICAgICAgICAgICkKICAgICAgICAgICAgICAgICAgICByYWlz>>"%TMPDIR%\server_supervisor.b64"
echo ZQogICAgICAgICAgICAgICAgdGltZS5zbGVlcChSRVNUQVJUX0JBQ0tPRkZfU0VDT05EUykK>>"%TMPDIR%\server_supervisor.b64"
certutil -decode "%TMPDIR%\server_supervisor.b64" "server_supervisor.py"
if not "%errorlevel%"=="0" (
    echo ERROR: failed to write server_supervisor.py -- see certutil output above.
    pause
    exit /b 1
)

rmdir /s /q "%TMPDIR%" >nul 2>&1

echo.
echo ============================================================
echo   Done. Files written:
echo     update_checker.py       (new)
echo     update_check_loop.py    (new)
echo     server_supervisor.py    (updated -- old copy: server_supervisor.py.bak)
echo ============================================================
echo   Next steps:
echo     1. Run make-msi.bat to rebuild the exe + msi.
echo     2. Run add-update-api.sh on the stocktoolsetup server
echo        (separate script -- adds the /api/updates/* routes).
echo     3. Publish a build: Site admin -^> Releases -^> upload
echo        dist\StockToolKiosk.exe (the raw exe, not the msi) -^>
echo        enter version -^> Push.
echo ============================================================
pause
