# -*- mode: python ; coding: utf-8 -*-
#
# PyInstaller spec for StockTool Kiosk (v2).
#
# Build ON WINDOWS (see BUILD_INSTRUCTIONS.md — PyInstaller does not
# cross-compile; it must run on the target OS):
#
#     pyinstaller build.spec
#
# Output: dist/StockToolKiosk.exe — a single file, no installer, no
# separate Python runtime needed on the target machine.

a = Analysis(
    ['main.py'],
    pathex=[],
    binaries=[],
    datas=[
        ('app/templates', 'app/templates'),
        ('app/static', 'app/static'),
    ],
    hiddenimports=[
        'flask_sqlalchemy',
        'sqlalchemy.sql.default_comparator',
    ],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[],
    noarchive=False,
)
pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    a.binaries,
    a.datas,
    [],
    name='StockToolKiosk',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    upx_exclude=[],
    runtime_tmpdir=None,
    console=True,        # keep a console window for now (Part 1) so
                          # crash output / watchdog logs are visible;
                          # switch to console=False + a tray icon once
                          # the watchdog has proven itself in the field
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
    onefile=True,
)
