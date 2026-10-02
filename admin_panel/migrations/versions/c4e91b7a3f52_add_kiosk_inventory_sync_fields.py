"""add Kiosk App inventory sync fields to equipment/local users

Revision ID: c4e91b7a3f52
Revises: a8d3f6b21e0c
Create Date: 2026-09-08 22:45:00.000000

Applied directly against the running SQLite file (see
backups/pre_inventory_sync_*.db for the pre-change snapshot), same as the
two migrations before it — see f2a6c3e91d47's docstring.
"""
from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision = 'c4e91b7a3f52'
down_revision = 'a8d3f6b21e0c'
branch_labels = None
depends_on = None


def upgrade():
    with op.batch_alter_table('instance_equipment_items', schema=None) as batch_op:
        batch_op.add_column(sa.Column('sku', sa.String(length=64), nullable=True))
        batch_op.add_column(sa.Column('quantity', sa.Integer(), nullable=True))
        batch_op.add_column(sa.Column('unit', sa.String(length=32), nullable=True))
        batch_op.add_column(sa.Column('category', sa.String(length=16), nullable=True))
        batch_op.add_column(sa.Column('unit_cost', sa.Float(), nullable=True))
        batch_op.add_column(sa.Column('tool_status', sa.String(length=16), nullable=True))
        batch_op.add_column(sa.Column('checked_out_by_name', sa.String(length=255), nullable=True))
        batch_op.add_column(sa.Column('current_project', sa.String(length=255), nullable=True))
        batch_op.add_column(sa.Column('purchase_price', sa.Float(), nullable=True))
        batch_op.add_column(sa.Column('barcode_code', sa.String(length=32), nullable=True))
        batch_op.add_column(sa.Column('deleted_at', sa.DateTime(), nullable=True))

    with op.batch_alter_table('instance_local_users', schema=None) as batch_op:
        batch_op.add_column(sa.Column('username', sa.String(length=80), nullable=True))
        batch_op.add_column(sa.Column('role', sa.String(length=32), nullable=True, server_default='stock_user'))
        batch_op.add_column(sa.Column('badge_code', sa.String(length=32), nullable=True))
        batch_op.add_column(sa.Column('deleted_at', sa.DateTime(), nullable=True))
        batch_op.create_unique_constraint(
            'uq_instance_local_user_username', ['instance_id', 'username'],
        )


def downgrade():
    with op.batch_alter_table('instance_local_users', schema=None) as batch_op:
        batch_op.drop_constraint('uq_instance_local_user_username', type_='unique')
        batch_op.drop_column('deleted_at')
        batch_op.drop_column('badge_code')
        batch_op.drop_column('role')
        batch_op.drop_column('username')

    with op.batch_alter_table('instance_equipment_items', schema=None) as batch_op:
        batch_op.drop_column('deleted_at')
        batch_op.drop_column('barcode_code')
        batch_op.drop_column('purchase_price')
        batch_op.drop_column('current_project')
        batch_op.drop_column('checked_out_by_name')
        batch_op.drop_column('tool_status')
        batch_op.drop_column('unit_cost')
        batch_op.drop_column('category')
        batch_op.drop_column('unit')
        batch_op.drop_column('quantity')
        batch_op.drop_column('sku')
