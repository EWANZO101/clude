# PyInstaller spec for OpsLabAgent.exe
#
# Build ON WINDOWS (PyInstaller does not cross-compile):
#   build_exe.bat
#
# Produces a single onefile exe wrapping
# service_files/windows/opslab_agent_service.py, which supports:
#   OpsLabAgent.exe run       -> foreground console mode (no admin needed)
#   OpsLabAgent.exe install   -> installs as the "OpsLabAgent" Windows service
#   OpsLabAgent.exe start     -> starts the service
#   OpsLabAgent.exe stop      -> stops the service
#   OpsLabAgent.exe remove    -> uninstalls the service
#
# Remote start/stop/restart of the supervised kiosk app, and self-update,
# both happen over the API once the exe/service is running — see agent/
# commands.py and agent/update_manager.py. This spec does not need to
# change when those change; it just bundles the agent/ package.

import os

block_cipher = None
repo_root = os.path.abspath(os.path.join(SPECPATH, ".."))

a = Analysis(
    [os.path.join(repo_root, "service_files", "windows", "opslab_agent_service.py")],
    pathex=[repo_root],
    binaries=[],
    datas=[],
    hiddenimports=[
        "agent",
        "agent.main",
        "agent.config",
        "agent.identity",
        "agent.api_client",
        "agent.heartbeat",
        "agent.config_manager",
        "agent.update_manager",
        "agent.update_validation",
        "agent.package_validation",
        "agent.installer",
        "agent.recovery",
        "agent.process_supervisor",
        "agent.commands",
        "agent.system_info",
        "agent.health_check",
        "win32timezone",
        "win32serviceutil",
        "win32service",
        "win32event",
        "servicemanager",
    ],
    hookspath=[],
    runtime_hooks=[],
    excludes=[],
    win_no_prefer_redirects=False,
    win_private_assemblies=False,
    cipher=block_cipher,
    noarchive=False,
)
pyz = PYZ(a.pure, a.zipped_data, cipher=block_cipher)

exe = EXE(
    pyz,
    a.scripts,
    a.binaries,
    a.zipfiles,
    a.datas,
    [],
    name="OpsLabAgent",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    upx_exclude=[],
    runtime_tmpdir=None,
    console=True,
    onefile=True,
)
