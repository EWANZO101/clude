"""
publish_unpublished_layouts.py -- one-off fix for installs that ran
migrate.py BEFORE the auto-publish fix (see scripts/migrate.py's
_ensure_default_layout, and CHANGES.md). Those installs have a
"Default Kiosk" layout sitting in draft-only forever, invisible to every
kiosk, because nothing ever called .publish() on it.

Deliberately scoped to is_default=True layouts ONLY -- not every
unpublished layout. Since Builder Mode now also covers admin pages
(Items/Tools/Projects/Categories/Barcode Scan surfaces), a non-default
layout with no published_components is very likely someone's in-progress
draft they haven't finished editing yet, not a bug -- this must never
auto-publish that. is_default=True is the one case where "still
unpublished" is unambiguously the bug this script exists to fix.

Safe to run more than once -- once a layout is published, it's no
longer unpublished, so re-running is a no-op for it.

Usage (from stocktool-api, with the venv active):
    python scripts/publish_unpublished_layouts.py
    python scripts/publish_unpublished_layouts.py --dry-run   # just list, don't publish
"""
import argparse
import sys
import os

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from app import create_app
from app.extensions import db
from app.models.layout import DashboardLayout


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true", help="List what would be published, without doing it")
    args = parser.parse_args()

    app = create_app()
    with app.app_context():
        unpublished = DashboardLayout.query.filter(
            DashboardLayout.published_components.is_(None),
            DashboardLayout.is_default.is_(True),
        ).all()

        if not unpublished:
            print("Nothing to do -- no default layout is stuck in draft-only.")
            return

        for layout in unpublished:
            print(f"{'Would publish' if args.dry_run else 'Publishing'}: "
                  f"'{layout.name}' (id={layout.id}, surface={layout.surface}, "
                  f"target_device={layout.target_device or 'all kiosks'})")
            if not args.dry_run:
                layout.publish()

        if not args.dry_run:
            db.session.commit()
            print(f"\nDone -- published {len(unpublished)} layout(s).")
        else:
            print(f"\n(dry run -- {len(unpublished)} layout(s) would have been published)")


if __name__ == "__main__":
    sys.exit(main())
