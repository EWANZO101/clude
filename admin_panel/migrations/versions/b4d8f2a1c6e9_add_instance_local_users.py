"""add instance_local_users (local kiosk terminal operators) + pin history

Revision ID: b4d8f2a1c6e9
Revises: 7c2e91a4f3b8
Create Date: 2026-09-08 17:00:00.000000

Local kiosk users are the people who operate a specific physical kiosk
day-to-day — distinct from the web dashboard's User/CompanyMembership
accounts. PIN handling mirrors User's own (same hashing, same no-reuse
rule via history), just scoped per-instance and not live-enforced by any
real device yet.
"""
from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision = 'b4d8f2a1c6e9'
down_revision = '7c2e91a4f3b8'
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        'instance_local_users',
        sa.Column('id', sa.Integer(), nullable=False),
        sa.Column('public_id', sa.String(length=36), nullable=False),
        sa.Column('instance_id', sa.Integer(), nullable=False),
        sa.Column('name', sa.String(length=255), nullable=False),
        sa.Column('status', sa.String(length=16), nullable=False),
        sa.Column('pin_hash', sa.String(length=255), nullable=True),
        sa.Column('pin_set_at', sa.DateTime(), nullable=True),
        sa.Column('created_at', sa.DateTime(), nullable=False),
        sa.Column('updated_at', sa.DateTime(), nullable=False),
        sa.Column('added_by_id', sa.Integer(), nullable=True),
        sa.ForeignKeyConstraint(
            ['instance_id'], ['instances.id'],
            name=op.f('fk_instance_local_users_instance_id_instances'),
        ),
        sa.ForeignKeyConstraint(
            ['added_by_id'], ['users.id'],
            name=op.f('fk_instance_local_users_added_by_id_users'),
        ),
        sa.PrimaryKeyConstraint('id', name=op.f('pk_instance_local_users')),
        sa.UniqueConstraint('public_id', name=op.f('uq_instance_local_users_public_id')),
    )
    op.create_table(
        'instance_local_user_pin_history',
        sa.Column('id', sa.Integer(), nullable=False),
        sa.Column('local_user_id', sa.Integer(), nullable=False),
        sa.Column('pin_hash', sa.String(length=255), nullable=False),
        sa.Column('created_at', sa.DateTime(), nullable=False),
        sa.ForeignKeyConstraint(
            ['local_user_id'], ['instance_local_users.id'],
            name=op.f('fk_instance_local_user_pin_history_local_user_id_instance_local_users'),
        ),
        sa.PrimaryKeyConstraint('id', name=op.f('pk_instance_local_user_pin_history')),
    )


def downgrade():
    op.drop_table('instance_local_user_pin_history')
    op.drop_table('instance_local_users')
