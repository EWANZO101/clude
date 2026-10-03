"""add instance_equipment_items (items & tools attached to a kiosk)

Revision ID: 7c2e91a4f3b8
Revises: 3f8b6c1a9d02
Create Date: 2026-09-08 16:30:00.000000
"""
from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision = '7c2e91a4f3b8'
down_revision = '3f8b6c1a9d02'
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        'instance_equipment_items',
        sa.Column('id', sa.Integer(), nullable=False),
        sa.Column('public_id', sa.String(length=36), nullable=False),
        sa.Column('instance_id', sa.Integer(), nullable=False),
        sa.Column('kind', sa.String(length=8), nullable=False),
        sa.Column('name', sa.String(length=255), nullable=False),
        sa.Column('description', sa.Text(), nullable=True),
        sa.Column('serial_number', sa.String(length=128), nullable=True),
        sa.Column('status', sa.String(length=16), nullable=False),
        sa.Column('created_at', sa.DateTime(), nullable=False),
        sa.Column('updated_at', sa.DateTime(), nullable=False),
        sa.Column('added_by_id', sa.Integer(), nullable=True),
        sa.ForeignKeyConstraint(
            ['instance_id'], ['instances.id'],
            name=op.f('fk_instance_equipment_items_instance_id_instances'),
        ),
        sa.ForeignKeyConstraint(
            ['added_by_id'], ['users.id'],
            name=op.f('fk_instance_equipment_items_added_by_id_users'),
        ),
        sa.PrimaryKeyConstraint('id', name=op.f('pk_instance_equipment_items')),
        sa.UniqueConstraint('public_id', name=op.f('uq_instance_equipment_items_public_id')),
    )


def downgrade():
    op.drop_table('instance_equipment_items')
