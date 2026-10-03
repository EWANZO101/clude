"""Add time off share links and calendarmaker public PIN

Revision ID: a1b2c3d4e5f6
Revises: f4d9b2c7a1e6
Create Date: 2026-08-16 00:00:00.000000

"""
from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision = 'a1b2c3d4e5f6'
down_revision = 'f4d9b2c7a1e6'
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        'time_off_share_links',
        sa.Column('id', sa.Integer(), nullable=False),
        sa.Column('user_id', sa.Integer(), nullable=False),
        sa.Column('token', sa.String(length=32), nullable=False),
        sa.Column('label', sa.String(length=120), nullable=True),
        sa.Column('pin_hash', sa.String(length=255), nullable=True),
        sa.Column('created_at', sa.DateTime(), nullable=True),
        sa.Column('last_used_at', sa.DateTime(), nullable=True),
        sa.ForeignKeyConstraint(['user_id'], ['users.id'], ),
        sa.PrimaryKeyConstraint('id'),
        sa.UniqueConstraint('token'),
    )
    with op.batch_alter_table('time_off_share_links', schema=None) as batch_op:
        batch_op.create_index(batch_op.f('ix_time_off_share_links_user_id'), ['user_id'], unique=False)
        batch_op.create_index(batch_op.f('ix_time_off_share_links_token'), ['token'], unique=True)

    with op.batch_alter_table('shared_calendars', schema=None) as batch_op:
        batch_op.add_column(sa.Column('public_pin_hash', sa.String(length=255), nullable=True))


def downgrade():
    with op.batch_alter_table('shared_calendars', schema=None) as batch_op:
        batch_op.drop_column('public_pin_hash')

    with op.batch_alter_table('time_off_share_links', schema=None) as batch_op:
        batch_op.drop_index(batch_op.f('ix_time_off_share_links_token'))
        batch_op.drop_index(batch_op.f('ix_time_off_share_links_user_id'))

    op.drop_table('time_off_share_links')
