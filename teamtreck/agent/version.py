"""
Single source of truth for the agent's version string.

Bump this on every release. The PyInstaller build reads it (via
packaging/pyinstaller/teamtreck-agent.spec -> agent/version.py) to name
build artifacts, and agent/updater.py reads it to decide whether a newer
build is available on the server.
"""
__version__ = "0.18.0"
