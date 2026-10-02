"""
PyInstaller needs a real script file to point at (not `python -m agent.cli`).
This just calls straight into the existing CLI - no logic lives here.
"""
from agent.cli import main

if __name__ == '__main__':
    main()
