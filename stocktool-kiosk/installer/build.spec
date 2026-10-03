# build.spec — PyInstaller onefile build for StockToolKiosk.exe
#
# Run with:  pyinstaller build.spec --clean
# (NOT `pyinstaller main.py` — that would ignore everything below and
# rebuild default options from scratch.)
#
# Output: dist/StockToolKiosk.exe
#
# ONEFILE means every dependency is packed into the single .exe and
# unpacked to a fresh %TEMP%\_MEIxxxxxx folder on every launch — see
# license.py's header comment for why that made license.txt/settings
# storage have to live in %ProgramData% instead of anywhere derived from
# __file__.

import os
import sys
from PyInstaller.utils.hooks import collect_submodules

block_cipher = None

# ── Version info embedded in the .exe's file properties ────────────────
# Read from version.py (the single source of truth — see that file's own
# docstring) rather than hand-maintained here, so the exe's Properties >
# Details tab in Windows Explorer can never drift from what
# StockToolKiosk.exe actually reports to /api/updates/latest at runtime.
sys.path.insert(0, os.path.abspath("."))
from version import __version__ as APP_VERSION

_version_tuple = tuple((list(map(int, APP_VERSION.split("."))) + [0, 0, 0, 0])[:4])

version_file = None
try:
    from PyInstaller.utils.win32.versioninfo import (
        VSVersionInfo, FixedFileInfo, StringFileInfo, StringTable,
        StringStruct, VarFileInfo, VarStruct,
    )
    version_file = VSVersionInfo(
        ffi=FixedFileInfo(
            filevers=_version_tuple, prodvers=_version_tuple,
            mask=0x3F, flags=0x0, OS=0x4, fileType=0x1, subtype=0x0, date=(0, 0),
        ),
        kids=[
            StringFileInfo([StringTable("040904B0", [
                StringStruct("CompanyName", "OpsLab Systems"),
                StringStruct("FileDescription", "StockTool Kiosk"),
                StringStruct("FileVersion", APP_VERSION),
                StringStruct("InternalName", "StockToolKiosk"),
                StringStruct("OriginalFilename", "StockToolKiosk.exe"),
                StringStruct("ProductName", "StockTool Kiosk"),
                StringStruct("ProductVersion", APP_VERSION),
            ])]),
            VarFileInfo([VarStruct("Translation", [1033, 1200])]),
        ],
    )
except Exception:
    # win32 version-info tooling is only available on Windows builds —
    # harmless to skip on a Linux/mac dev machine doing a syntax check.
    version_file = None

_icon_path = "installer/icon.ico"
icon = _icon_path if os.path.isfile(_icon_path) else None

# Flask/Jinja2 + SQLAlchemy dialects are loaded dynamically in places
# PyInstaller's static import scan can miss — explicit collection avoids
# a build that runs fine from source but throws ModuleNotFoundError only
# once frozen.
hidden_imports = (
    collect_submodules("flask")
    + collect_submodules("jinja2")
    + collect_submodules("sqlalchemy.dialects.sqlite")
    + collect_submodules("werkzeug")
    + ["waitress"]
)

datas = [
    ("app/templates", "app/templates"),
    ("app/static", "app/static"),
    ("license.txt", "."),
    ("openapi-cloud-api.yaml", "."),
    ("openapi-kiosk-local-api.yaml", "."),
]

a = Analysis(
    ["main.py"],
    pathex=["."],
    binaries=[],
    datas=datas,
    hiddenimports=hidden_imports,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=["tkinter", "matplotlib", "numpy", "pytest"],
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
    name="StockToolKiosk",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,          # UPX-compressed onefile exes are a common false-positive
    upx_exclude=[],     # trigger for AV/SmartScreen on first-run — not worth the size saving
    runtime_tmpdir=None,
    console=True,       # keeps a console window for run_interactive()/run_service() logging;
                         # run_service() itself doesn't print, but errors before that point still need somewhere to go
    disable_windowed_traceback=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
    icon=icon,
    version=version_file,
)

