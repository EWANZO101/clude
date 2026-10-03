"""add generic inventory type system (Track 2 Phase A) — instance_item_types,
instance_item_type_fields, instance_inventory_items,
instance_inventory_item_events, instance_nav_entries

Revision ID: b3e7d19a4c58
Revises: a4c7f92e1d63
Create Date: 2026-09-09 17:20:00.000000

Chained after a4c7f92e1d63, applied directly against the running SQLite
file and stamped — same convention as every other migration this session
(see f2a6c3e91d47's own docstring for why this repo's history doesn't go
through a clean `flask db upgrade` from the true tip). Purely additive:
InstanceEquipmentItem/InstanceRole and every route/template built on them
are untouched — see /root/.claude/plans/sprightly-meandering-whisper.md,
Track 2 Phase A.
"""
from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision = 'b3e7d19a4c58'
down_revision = 'a4c7f92e1d63'
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        'instance_item_types',
        sa.Column('id', sa.Integer(), nullable=False),
        sa.Column('instance_id', sa.Integer(), nullable=False),
        sa.Column('key', sa.String(length=64), nullable=False),
        sa.Column('name', sa.String(length=255), nullable=False),
        sa.Column('description', sa.Text(), nullable=True),
        sa.Column('is_builtin', sa.Boolean(), nullable=False),
        sa.Column('created_at', sa.DateTime(), nullable=False),
        sa.Column('updated_at', sa.DateTime(), nullable=False),
        sa.Column('deleted_at', sa.DateTime(), nullable=True),
        sa.ForeignKeyConstraint(['instance_id'], ['instances.id'], name=op.f('fk_instance_item_types_instance_id_instances')),
        sa.PrimaryKeyConstraint('id', name=op.f('pk_instance_item_types')),
        sa.UniqueConstraint('instance_id', 'key', name='uq_instance_item_type_key'),
    )

    op.create_table(
        'instance_item_type_fields',
        sa.Column('id', sa.Integer(), nullable=False),
        sa.Column('instance_item_type_id', sa.Integer(), nullable=False),
        sa.Column('key', sa.String(length=64), nullable=False),
        sa.Column('label', sa.String(length=255), nullable=False),
        sa.Column('field_type', sa.String(length=32), nullable=False),
        sa.Column('options_json', sa.Text(), nullable=True),
        sa.Column('required', sa.Boolean(), nullable=False),
        sa.Column('sort_order', sa.Integer(), nullable=False),
        sa.Column('updated_at', sa.DateTime(), nullable=False),
        sa.Column('deleted_at', sa.DateTime(), nullable=True),
        sa.ForeignKeyConstraint(
            ['instance_item_type_id'], ['instance_item_types.id'],
            name=op.f('fk_instance_item_type_fields_instance_item_type_id_instance_item_types'),
        ),
        sa.PrimaryKeyConstraint('id', name=op.f('pk_instance_item_type_fields')),
    )

    op.create_table(
        'instance_inventory_items',
        sa.Column('id', sa.Integer(), nullable=False),
        sa.Column('public_id', sa.String(length=36), nullable=False),
        sa.Column('instance_id', sa.Integer(), nullable=False),
        sa.Column('item_type_key', sa.String(length=64), nullable=False),
        sa.Column('name', sa.String(length=255), nullable=False),
        sa.Column('sku', sa.String(length=64), nullable=True),
        sa.Column('serial_number', sa.String(length=128), nullable=True),
        sa.Column('status', sa.String(length=16), nullable=False),
        sa.Column('quantity_value', sa.Float(), nullable=True),
        sa.Column('quantity_unit', sa.String(length=16), nullable=True),
        sa.Column('custom_fields', sa.Text(), nullable=True),
        sa.Column('barcode_code', sa.String(length=32), nullable=True),
        sa.Column('checked_out_by_name', sa.String(length=255), nullable=True),
        sa.Column('current_project', sa.String(length=255), nullable=True),
        sa.Column('deleted_at', sa.DateTime(), nullable=True),
        sa.Column('created_at', sa.DateTime(), nullable=False),
        sa.Column('updated_at', sa.DateTime(), nullable=False),
        sa.Column('added_by_id', sa.Integer(), nullable=True),
        sa.ForeignKeyConstraint(['instance_id'], ['instances.id'], name=op.f('fk_instance_inventory_items_instance_id_instances')),
        sa.ForeignKeyConstraint(['added_by_id'], ['users.id'], name=op.f('fk_instance_inventory_items_added_by_id_users')),
        sa.PrimaryKeyConstraint('id', name=op.f('pk_instance_inventory_items')),
        sa.UniqueConstraint('public_id', name='uq_instance_inventory_items_public_id'),
    )

    op.create_table(
        'instance_inventory_item_events',
        sa.Column('id', sa.Integer(), nullable=False),
        sa.Column('item_id', sa.Integer(), nullable=False),
        sa.Column('event_type', sa.String(length=32), nullable=False),
        sa.Column('actor', sa.String(length=255), nullable=True),
        sa.Column('project', sa.String(length=255), nullable=True),
        sa.Column('occurred_at', sa.DateTime(), nullable=False),
        sa.Column('resolved_at', sa.DateTime(), nullable=True),
        sa.Column('outcome', sa.String(length=32), nullable=True),
        sa.Column('detail', sa.Text(), nullable=True),
        sa.ForeignKeyConstraint(
            ['item_id'], ['instance_inventory_items.id'],
            name=op.f('fk_instance_inventory_item_events_item_id_instance_inventory_items'),
        ),
        sa.PrimaryKeyConstraint('id', name=op.f('pk_instance_inventory_item_events')),
    )

    op.create_table(
        'instance_nav_entries',
        sa.Column('id', sa.Integer(), nullable=False),
        sa.Column('instance_id', sa.Integer(), nullable=False),
        sa.Column('key', sa.String(length=80), nullable=False),
        sa.Column('label', sa.String(length=255), nullable=False),
        sa.Column('section', sa.String(length=64), nullable=False),
        sa.Column('is_builtin', sa.Boolean(), nullable=False),
        sa.Column('sort_order', sa.Integer(), nullable=False),
        sa.Column('updated_at', sa.DateTime(), nullable=False),
        sa.ForeignKeyConstraint(['instance_id'], ['instances.id'], name=op.f('fk_instance_nav_entries_instance_id_instances')),
        sa.PrimaryKeyConstraint('id', name=op.f('pk_instance_nav_entries')),
        sa.UniqueConstraint('instance_id', 'key', name='uq_instance_nav_entry_key'),
    )


def downgrade():
    op.drop_table('instance_nav_entries')
    op.drop_table('instance_inventory_item_events')
    op.drop_table('instance_inventory_items')
    op.drop_table('instance_item_type_fields')
    op.drop_table('instance_item_types')
