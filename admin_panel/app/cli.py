import json

import click
import os
import shutil
import sys
import uuid

from app.extensions import db
from app.models import (
    User, UpdatePackage, log_action, Instance, InstanceEquipmentItem,
    InstanceItemType, InstanceInventoryItem,
)
from app.update_validation import register_package_from_zip

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tools.build_kiosk_release import build_kiosk_release_zip  # noqa: E402


def register_cli(app):
    @app.cli.command("create-superuser")
    @click.argument("email")
    @click.argument("full_name")
    @click.password_option()
    @click.option("--platform-admin", is_flag=True, help="Grant OpsLab platform-admin access (release uploads, etc).")
    def create_superuser(email, full_name, password, platform_admin):
        """Create a pre-verified user (no company) — useful for the first login."""
        email = email.strip().lower()
        if User.query.filter_by(email=email).first():
            click.echo("A user with that email already exists.")
            return
        user = User(email=email, full_name=full_name, email_verified=True, is_platform_admin=platform_admin)
        user.set_password(password)
        db.session.add(user)
        db.session.commit()
        click.echo(f"Created user {email}." + (" (platform admin)" if platform_admin else ""))

    @app.cli.command("upload-release")
    @click.argument("zip_path", type=click.Path(exists=True, dir_okay=False))
    @click.argument("version")
    @click.option("--notes", default=None, help="Release notes (optional).")
    @click.option("--uploaded-by", default=None,
                  help="Email of the platform-admin user to record as uploader. "
                       "Defaults to the first platform admin found.")
    def upload_release(zip_path, version, notes, uploaded_by):
        """Uploads and validates an update package ZIP exactly like the web
        /admin/releases/upload form does (same validation, same DB row) —
        for scripted/CI use where a browser login isn't available. Run from
        inside the admin_panel repo root with the venv activated:
            flask upload-release /path/to/kiosk-app-v1.0.0.zip 1.0.0
        """
        if UpdatePackage.query.filter_by(version=version).first() is not None:
            click.echo(f"Error: a package with version '{version}' already exists.", err=True)
            raise SystemExit(1)

        if uploaded_by:
            user = User.query.filter_by(email=uploaded_by.strip().lower()).first()
            if user is None:
                click.echo(f"Error: no user found with email '{uploaded_by}'.", err=True)
                raise SystemExit(1)
        else:
            user = User.query.filter_by(is_platform_admin=True).first()
            if user is None:
                click.echo("Error: no platform-admin user exists yet — create one first with "
                           "'flask create-superuser ... --platform-admin', or pass --uploaded-by.", err=True)
                raise SystemExit(1)

        upload_dir = app.config["UPDATE_PACKAGE_DIR"]
        os.makedirs(upload_dir, exist_ok=True)
        safe_name = f"{version}-{uuid.uuid4().hex[:8]}.zip"
        dest_path = os.path.join(upload_dir, safe_name)
        shutil.copyfile(zip_path, dest_path)

        ok, val_errors, package = register_package_from_zip(dest_path, version, notes, user.id)
        db.session.add(package)
        log_action(None, user, "package_uploaded", f"v{version} ({'validated' if ok else 'invalid'}, via CLI)")
        db.session.commit()

        if ok:
            click.echo(f"Uploaded and validated: v{version} (supports: {package.supported_os}) — "
                       f"ready to push to matching instances.")
        else:
            click.echo(f"Uploaded but FAILED validation: v{version}", err=True)
            for e in val_errors:
                click.echo(f"  - {e}", err=True)
            raise SystemExit(1)

    @app.cli.command("build-kiosk-release")
    @click.argument("version")
    @click.option("--notes", default=None, help="Release notes (optional).")
    @click.option("--uploaded-by", default=None,
                  help="Email of the platform-admin user to record as uploader. "
                       "Defaults to the first platform admin found.")
    def build_kiosk_release(version, notes, uploaded_by):
        """Builds a release zip straight from kiosk_app/ (see
        tools/build_kiosk_release.py) and registers it exactly like
        'upload-release' would — the sanctioned way to cut a Kiosk App
        release, since it can never package the wrong application the way a
        hand-picked zip upload can (see the v1.0.2 incident):
            flask build-kiosk-release 1.0.3 --notes "Barcode printing"
        """
        if UpdatePackage.query.filter_by(version=version).first() is not None:
            click.echo(f"Error: a package with version '{version}' already exists.", err=True)
            raise SystemExit(1)

        if uploaded_by:
            user = User.query.filter_by(email=uploaded_by.strip().lower()).first()
            if user is None:
                click.echo(f"Error: no user found with email '{uploaded_by}'.", err=True)
                raise SystemExit(1)
        else:
            user = User.query.filter_by(is_platform_admin=True).first()
            if user is None:
                click.echo("Error: no platform-admin user exists yet — create one first with "
                           "'flask create-superuser ... --platform-admin', or pass --uploaded-by.", err=True)
                raise SystemExit(1)

        upload_dir = app.config["UPDATE_PACKAGE_DIR"]
        os.makedirs(upload_dir, exist_ok=True)
        safe_name = f"{version}-{uuid.uuid4().hex[:8]}.zip"
        dest_path = os.path.join(upload_dir, safe_name)
        build_kiosk_release_zip(version, dest_path)

        ok, val_errors, package = register_package_from_zip(dest_path, version, notes, user.id)
        db.session.add(package)
        log_action(None, user, "package_uploaded", f"v{version} ({'validated' if ok else 'invalid'}, built from kiosk_app/)")
        db.session.commit()

        if ok:
            click.echo(f"Built and validated: v{version} (supports: {package.supported_os}) — "
                       f"ready to push to matching instances.")
        else:
            click.echo(f"Built but FAILED validation: v{version}", err=True)
            for e in val_errors:
                click.echo(f"  - {e}", err=True)
            raise SystemExit(1)

    @app.cli.command("migrate-equipment-to-inventory")
    @click.argument("instance_id")
    @click.option("--apply", is_flag=True, help="Actually write changes. Without this, only reports what would happen.")
    def migrate_equipment_to_inventory(instance_id, apply):
        """Track 2 Phase D (see /root/.claude/plans/sprightly-meandering-whisper.md)
        — one-time copy of one instance's existing InstanceEquipmentItem
        rows into the new InstanceItemType/InstanceInventoryItem tables.
        Mirrors kiosk_app's own `flask migrate-to-generic-inventory`
        exactly: purely additive and idempotent (matched by public_id) —
        InstanceEquipmentItem and everything built on it stay completely
        untouched. instance_id is the Instance's public_id."""
        instance = Instance.query.filter_by(public_id=instance_id).first()
        if instance is None:
            click.echo(f"No instance with public_id {instance_id!r}.", err=True)
            raise SystemExit(1)

        for key, name in (("item", "Item"), ("tool", "Tool")):
            existing = InstanceItemType.query.filter_by(instance_id=instance.id, key=key).first()
            if existing is None and apply:
                db.session.add(InstanceItemType(instance_id=instance.id, key=key, name=name, is_builtin=True))
        if apply:
            db.session.flush()

        created, skipped = 0, 0
        rows = InstanceEquipmentItem.query.filter_by(instance_id=instance.id).all()
        for row in rows:
            existing = InstanceInventoryItem.query.filter_by(instance_id=instance.id, public_id=row.public_id).first()
            if existing is not None:
                skipped += 1
                continue
            created += 1
            if apply:
                db.session.add(InstanceInventoryItem(
                    instance_id=instance.id, public_id=row.public_id, item_type_key=row.kind, name=row.name,
                    sku=row.sku, serial_number=row.serial_number,
                    status=row.status if row.kind == "item" else (row.tool_status or "available"),
                    quantity_value=float(row.quantity) if row.quantity is not None else None,
                    quantity_unit="ea" if row.quantity is not None else None,
                    custom_fields=json.dumps({
                        "description": row.description, "category": row.category,
                        "unit_cost": row.unit_cost, "purchase_price": row.purchase_price,
                    }),
                    barcode_code=row.barcode_code,
                    checked_out_by_name=row.checked_out_by_name, current_project=row.current_project,
                    deleted_at=row.deleted_at, created_at=row.created_at, updated_at=row.updated_at,
                    added_by_id=row.added_by_id,
                ))

        if apply:
            db.session.commit()
            click.echo(f"Migrated {created} row(s) for {instance.display_name()} ({skipped} already present, skipped).")
        else:
            click.echo(f"Dry run: would migrate {created} row(s) for {instance.display_name()} "
                       f"({skipped} already present). Re-run with --apply to write.")
