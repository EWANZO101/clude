"""
Auto-update mechanism.

IMPORTANT - server-side dependency not yet built:
This calls GET {server_url}/agent/api/latest-version, which is expected to
return JSON like:
    {"version": "0.19.0", "download_url": "https://.../teamtreck-agent-win.exe", "notes": "..."}
That endpoint does NOT exist yet in the main TeamTreck Flask app (this is a
separate project - see TODO.txt). Until it's added server-side, check_for_update()
will always report update_available: False (404/connection errors are treated
as "no update info available", not as an error the user needs to see).

What this module does:
- check_for_update(): compares the running agent's version (agent/version.py)
  against what the server reports, using simple tuple comparison of
  dotted-integer versions (e.g. "0.18.0" < "0.19.0"). Good enough for this
  project's straight-line versioning; does not handle pre-release suffixes
  like "1.0.0-beta".
- download_update(): streams the new binary to a temp file next to the
  current executable and verifies the download completed (size check only -
  no code signing/checksum verification yet, see TODO.txt).
- apply_update(): platform-specific "replace the running binary" step.
    - Windows/Linux: safe to overwrite the exe in place once it's not
      running, since the OS doesn't lock a renamed-away file the same way.
      Implemented as: rename current -> .old, move new into place.
    - macOS: same rename approach, but a .app bundle replacement is more
      involved (Info.plist, code signature) - NOT implemented here. See
      TODO.txt; for now macOS users get "update available" and a link,
      not an automatic swap.
- This module is NOT wired into AgentService.run_forever() yet - it's a
  standalone set of functions the CLI or a future tray icon can call
  (e.g. on startup, or a `teamtreck-agent check-update` command). Wiring
  it into the background loop is a deliberate choice left for the person
  running this to decide (auto-restarting a running agent has UX
  implications - mid-timer restarts, etc. - that deserve a real decision,
  not a default baked in here).
"""
import os
import sys
import shutil
import tempfile
import logging
import requests
from agent.config import load_config
from agent.version import __version__

logger = logging.getLogger('teamtreck-agent.updater')

DEFAULT_TIMEOUT = 8


def _version_tuple(v):
    try:
        return tuple(int(p) for p in v.strip().split('.'))
    except (ValueError, AttributeError):
        return (0,)


def check_for_update():
    """Returns {'update_available': bool, 'current': str, 'latest': str|None,
    'download_url': str|None, 'notes': str|None, 'error': str|None}"""
    cfg = load_config()
    base = cfg['server_url'].rstrip('/')
    result = {
        'update_available': False,
        'current': __version__,
        'latest': None,
        'download_url': None,
        'notes': None,
        'error': None,
    }
    try:
        r = requests.get(
            f'{base}/agent/api/latest-version',
            headers={'Authorization': f"Bearer {cfg['api_token']}"},
            timeout=DEFAULT_TIMEOUT,
        )
        if r.status_code == 404:
            # Expected until the server-side endpoint exists (see module docstring).
            result['error'] = 'server does not support update checks yet'
            return result
        if r.status_code != 200:
            result['error'] = f'unexpected status {r.status_code}'
            return result
        data = r.json()
        latest = data.get('version')
        result['latest'] = latest
        result['download_url'] = data.get('download_url')
        result['notes'] = data.get('notes')
        if latest and _version_tuple(latest) > _version_tuple(__version__):
            result['update_available'] = True
        return result
    except requests.RequestException as e:
        result['error'] = str(e)
        return result


def download_update(download_url, dest_dir=None):
    """Streams the new binary to a temp file. Returns the path, or None on failure."""
    dest_dir = dest_dir or tempfile.gettempdir()
    dest_path = os.path.join(dest_dir, 'teamtreck-agent-update' + _exe_suffix())
    try:
        with requests.get(download_url, stream=True, timeout=60) as r:
            r.raise_for_status()
            expected_size = int(r.headers.get('Content-Length', 0))
            written = 0
            with open(dest_path, 'wb') as f:
                for chunk in r.iter_content(chunk_size=1024 * 256):
                    f.write(chunk)
                    written += len(chunk)
        if expected_size and written != expected_size:
            logger.warning('Downloaded size (%s) does not match Content-Length (%s)', written, expected_size)
            os.remove(dest_path)
            return None
        return dest_path
    except (requests.RequestException, OSError) as e:
        logger.warning('Update download failed: %s', e)
        return None


def apply_update(new_binary_path):
    """Replaces the currently-running executable with new_binary_path.
    Only supported for the frozen (PyInstaller onefile) build - no-op if
    running from source (sys.frozen is unset), since there's no single
    binary to replace in that case."""
    if not getattr(sys, 'frozen', False):
        logger.info('Not a frozen build (running from source) - apply_update is a no-op, pull latest source instead.')
        return False

    current_exe = sys.executable
    if sys.platform == 'darwin':
        logger.warning('macOS .app bundle replacement is not implemented yet - see TODO.txt. '
                        'Download the new build manually from the link provided.')
        return False

    backup_path = current_exe + '.old'
    try:
        if os.path.exists(backup_path):
            os.remove(backup_path)
        os.rename(current_exe, backup_path)
        shutil.move(new_binary_path, current_exe)
        if sys.platform != 'win32':
            os.chmod(current_exe, 0o755)
        logger.info('Update applied. Restart the agent to run the new version.')
        return True
    except OSError as e:
        logger.error('Failed to apply update: %s', e)
        # best-effort rollback
        if os.path.exists(backup_path) and not os.path.exists(current_exe):
            os.rename(backup_path, current_exe)
        return False


def _exe_suffix():
    return '.exe' if sys.platform == 'win32' else ''
