import json

import click

from app.extensions import db
from app.models import (
    LocalUser, Role, Item, Tool, WireSpool, WireIssuanceEvent, ToolCheckoutEvent, ToolMaintenanceEvent,
    InventoryItem, InventoryItemEvent, ItemType,
)


def register_cli(app):
    @app.cli.command("create-user")
    @click.argument("username")
    @click.option("--role", default="admin")
    @click.option("--badge-code", default=None)
    @click.option("--password", default=None, help="Optional — if omitted, badge/username alone logs in.")
    def create_user(username, role, badge_code, password):
        """Creates/updates a LocalUser directly (mirrors the original
        StockTool Kiosk's --create-user CLI mode, used by the Setup Wizard
        to create the first admin account before anyone can log in via the
        UI). Accepts any role that exists — the four built-in roles, or a
        custom role created later via the Admin Panel (Part 6) — since
        this needs to keep working for a from-scratch install (no custom
        roles exist yet) as well as a site that's already customized its
        roles."""
        valid_roles = Role.all_role_names()
        if role not in valid_roles:
            click.echo(f"Unknown role '{role}'. Valid roles: {', '.join(valid_roles)}")
            raise SystemExit(1)

        user = LocalUser.query.filter_by(username=username).first()
        if user is None:
            user = LocalUser(username=username)
            db.session.add(user)
        user.role = role
        if badge_code:
            user.badge_code = badge_code
        if password:
            user.set_password(password)
        db.session.commit()
        click.echo(f"User '{username}' ready (role={role}, badge={user.badge_code}).")

    @app.cli.command("migrate-to-generic-inventory")
    @click.option("--apply", is_flag=True, help="Actually write changes. Without this, only reports what would happen.")
    def migrate_to_generic_inventory(apply):
        """Track 2 Phase D (see /root/.claude/plans/sprightly-meandering-whisper.md)
        — one-time copy of every existing Item/Tool/WireSpool row (plus
        their event histories) into the new generic InventoryItem/
        InventoryItemEvent tables. Purely additive and idempotent: the old
        Item/Tool/WireSpool tables, their routes/templates, and the sync
        fields that carry them are completely untouched — nothing is
        deleted here, and running this twice just skips rows already
        copied (matched by public_id / a deterministic derived id for
        rows with no public_id of their own). This is deliberately NOT
        the "old system's removal" step — that's a separate, later
        decision once the new system has been verified live, not
        something this command does on its own."""
        created, skipped = 0, 0

        def _existing(public_id):
            return InventoryItem.query.filter_by(public_id=public_id).first() is not None

        for item in Item.query.all():
            if _existing(item.public_id):
                skipped += 1
                continue
            created += 1
            if apply:
                db.session.add(InventoryItem(
                    public_id=item.public_id, item_type_key="item", name=item.name,
                    sku=item.sku, status="active" if item.deleted_at is None else "inactive",
                    quantity_value=float(item.quantity), quantity_unit="ea",
                    custom_fields=json.dumps({
                        "description": item.description, "category": item.category,
                        "unit_cost": item.unit_cost, "normal_interval_days": item.normal_interval_days,
                    }),
                    barcode_code=None,  # barcode_code is unique + FK'd; the original Item keeps owning it
                    deleted_at=item.deleted_at, created_at=item.created_at, updated_at=item.updated_at,
                ))

        for tool in Tool.query.all():
            if _existing(tool.public_id):
                skipped += 1
                continue
            created += 1
            if apply:
                new_item = InventoryItem(
                    public_id=tool.public_id, item_type_key="tool", name=tool.name,
                    status=tool.status if tool.deleted_at is None else "inactive",
                    checked_out_by_name=tool.checked_out_by_name, current_project=tool.current_project,
                    custom_fields=json.dumps({
                        "description": tool.description, "category": tool.category,
                        "purchase_price": tool.purchase_price, "maintenance_level": tool.maintenance_level,
                    }),
                    barcode_code=None,
                    deleted_at=tool.deleted_at, created_at=tool.created_at, updated_at=tool.updated_at,
                )
                db.session.add(new_item)
                db.session.flush()
                for ev in tool.checkout_events:
                    db.session.add(InventoryItemEvent(
                        item_id=new_item.id, event_type="issue", actor=ev.checked_out_by_name,
                        project=ev.project, occurred_at=ev.checked_out_at, resolved_at=ev.checked_in_at,
                        outcome="checkin" if ev.checked_in_at else None,
                        detail=(f"duration_seconds={ev.duration_seconds}" if ev.duration_seconds else None),
                    ))
                for ev in tool.maintenance_events:
                    db.session.add(InventoryItemEvent(
                        item_id=new_item.id, event_type="maintenance_start", project=None,
                        occurred_at=ev.started_at, resolved_at=ev.ended_at,
                        outcome="maintenance_end" if ev.ended_at else None,
                        detail=ev.reason or (f"cost={ev.cost}" if ev.cost else None),
                    ))

        for spool in WireSpool.query.all():
            spool_public_id = f"wire-spool-{spool.id}"  # WireSpool has no public_id of its own
            if _existing(spool_public_id):
                skipped += 1
                continue
            created += 1
            if apply:
                new_item = InventoryItem(
                    public_id=spool_public_id, item_type_key="welding_wire", name=spool.wire_label(),
                    status=spool.status, current_project=spool.current_project,
                    checked_out_by_name=spool.issued_to,
                    quantity_value=spool.weight_lbs, quantity_unit="lb" if spool.weight_lbs is not None else None,
                    custom_fields=json.dumps({
                        "wire_type": spool.wire_type, "diameter": spool.diameter, "unit_cost": spool.unit_cost,
                        "batch_label": spool.batch.label if spool.batch else None, "scrap_reason": spool.scrap_reason,
                    }),
                    barcode_code=None,
                    created_at=spool.received_at, updated_at=spool.received_at,
                )
                db.session.add(new_item)
                db.session.flush()
                for ev in spool.issuance_events:
                    db.session.add(InventoryItemEvent(
                        item_id=new_item.id, event_type="issue", actor=ev.issued_to, project=ev.project,
                        occurred_at=ev.issued_at, resolved_at=ev.resolved_at, outcome=ev.outcome,
                    ))

        if apply:
            db.session.commit()
            click.echo(f"Migrated {created} row(s) into inventory_items ({skipped} already present, skipped).")
        else:
            click.echo(f"Dry run: would migrate {created} row(s) ({skipped} already present). Re-run with --apply to write.")
