"""add PIN security (user pin fields, pin history, company expiry policy)

Revision ID: 3f8b6c1a9d02
Revises: 9a1f2c7d4e6b
Create Date: 2026-09-08 16:00:00.000000

Adds:
  - users.pin_hash / pin_set_at / pin_must_change
  - companies.pin_expiry_days (default 90 — 3 months, per spec)
  - a new user_pin_history table (append-only, used only to enforce
    "can't reuse a previous PIN")

pin_must_change defaults to true (server_default '1') so every EXISTING
account is gated into PIN setup on its next request too, exactly like a
brand-new signup — not silently grandfathered in just because it predates
this migration.
"""
from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision = '3f8b6c1a9d02'
down_revision = '9a1f2c7d4e6b'
branch_labels = None
depends_on = None


def upgrade():
    with op.batch_alter_table('users', schema=None) as batch_op:
        batch_op.add_column(sa.Column('pin_hash', sa.String(length=255), nullable=True))
        batch_op.add_column(sa.Column('pin_set_at', sa.DateTime(), nullable=True))
        batch_op.add_column(sa.Column(
            'pin_must_change', sa.Boolean(), nullable=False, server_default=sa.true()
        ))

    with op.batch_alter_table('companies', schema=None) as batch_op:
        batch_op.add_column(sa.Column(
            'pin_expiry_days', sa.Integer(), nullable=False, server_default='90'
        ))

    op.create_table(
        'user_pin_history',
        sa.Column('id', sa.Integer(), nullable=False),
        sa.Column('user_id', sa.Integer(), nullable=False),
        sa.Column('pin_hash', sa.String(length=255), nullable=False),
        sa.Column('created_at', sa.DateTime(), nullable=False),
        sa.ForeignKeyConstraint(
            ['user_id'], ['users.id'],
            name=op.f('fk_user_pin_history_user_id_users'),
        ),
        sa.PrimaryKeyConstraint('id', name=op.f('pk_user_pin_history')),
    )


def downgrade():
    op.drop_table('user_pin_history')

    with op.batch_alter_table('companies', schema=None) as batch_op:
        batch_op.drop_column('pin_expiry_days')

    with op.batch_alter_table('users', schema=None) as batch_op:
        batch_op.drop_column('pin_must_change')
        batch_op.drop_column('pin_set_at')
        batch_op.drop_column('pin_hash')
