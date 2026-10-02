#!/usr/bin/env python3
"""
Rescue component — required to exist independently of the main application
(spec Section 17), so a broken app update can never take this down with it.

NOTE, stated plainly: the Instance Agent does not currently invoke anything
in rescue/ — today it's a validation requirement only (the Admin Panel and
the Agent both refuse a package that doesn't have one). This script is a
real, working starting point for when the Agent's rollback path is
extended to actually call into it, not a placeholder that does nothing.

What it does today: reports whether the currently-installed app directory
looks structurally intact. Safe to run manually at any time:
    python3 rescue/verify_install.py /opt/opslab-agent/app
"""
import os
import sys

def main():
    app_dir = sys.argv[1] if len(sys.argv) > 1 else "."
    required = ["run.py", "app/__init__.py", "app/models.py"]
    missing = [f for f in required if not os.path.isfile(os.path.join(app_dir, f))]
    if missing:
        print(f"UNHEALTHY: missing {missing} under {app_dir}")
        sys.exit(1)
    print(f"OK: {app_dir} looks structurally intact.")
    sys.exit(0)

if __name__ == "__main__":
    main()
