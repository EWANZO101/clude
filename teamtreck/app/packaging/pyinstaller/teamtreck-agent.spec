# PyInstaller spec for the TeamTreck desktop agent.
#
# Build from the project root (one level above /packaging), so agent/ is
# importable:
#   pyinstaller packaging/pyinstaller/teamtreck-agent.spec --distpath dist --workpath build --noconfirm
# (the build_*.sh / build_windows.bat scripts do this for you)
#
# Produces a single onefile binary: dist/teamtreck-agent(.exe)
# Entry point is agent/cli.py's main() via the small __main__ shim below,
# since PyInstaller wants a real script file, not a -m module invocation.

import sys
import os

block_cipher = None

# pynput and mss both load platform backends dynamically (importlib), which
# PyInstaller's static analysis can't always see - list them explicitly so
# the right ones get bundled per-OS. Harmless to list all three; the ones
# that don't apply to the build platform just won't be importable at
# runtime on that OS, which is fine since pynput/mss handle that themselves.
hidden_imports = [
    'pynput.keyboard._xorg', 'pynput.keyboard._win32', 'pynput.keyboard._darwin',
    'pynput.mouse._xorg', 'pynput.mouse._win32', 'pynput.mouse._darwin',
    'mss.linux', 'mss.windows', 'mss.darwin',
]

PROJECT_ROOT = os.path.abspath(os.path.join(SPECPATH, '..', '..'))

a = Analysis(
    [os.path.join(PROJECT_ROOT, 'entrypoint.py')],
    pathex=[PROJECT_ROOT],
    binaries=[],
    datas=[],
    hiddenimports=hidden_imports,
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
    name='teamtreck-agent',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    upx_exclude=[],
    runtime_tmpdir=None,
    console=True,          # keep a console/terminal window; this is a CLI tool, not yet a tray app
    disable_windowed_traceback=False,
    target_arch=None,
    codesign_identity=None,   # macOS: set to your Developer ID for a notarizable build, see packaging/macos/build_pkg.sh
    entitlements_file=None,
)
