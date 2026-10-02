#!/usr/bin/env python3
"""Entry point: python migrate.py [command] — defaults to `migrate`."""
import sys

if sys.version_info < (3, 10):
    sys.exit("OpsLab Migrate requires Python 3.10+ (3.12 recommended)")

from migratekit.cli import app

if __name__ == "__main__":
    if len(sys.argv) == 1:
        sys.argv.append("migrate")
    app()
