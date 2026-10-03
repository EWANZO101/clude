"""Add time off requests (approval for share-link add/delete)

Revision ID: b2c3d4e5f6a7
Revises: a1b2c3d4e5f6
Create Date: 2026-08-16 00:00:00.000000

"""
from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision = 'b2c3d4e5f6a7'
down_revision = 'a1b2c3d4e5f6'
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        'time_off_requests',
        sa.Column('id', sa.Integer(), nullable=False),
        sa.Column('user_id', sa.Integer(), nullable=False),
        sa.Column('share_link_id', sa.Integer(), nullable=True),
        sa.Column('source_label', sa.String(length=120), nullable=True),
        sa.Column('action', sa.String(length=10), nullable=False),
        sa.Column('start_datetime', sa.DateTime(), nullable=True),
        sa.Column('end_datetime', sa.DateTime(), nullable=True),
        sa.Column('all_day', sa.Boolean(), nullable=True),
        sa.Column('reason', sa.String(length=255), nullable=True),
        sa.Column('time_off_id', sa.Integer(), nullable=True),
        sa.Column('status', sa.String(length=10), nullable=False),
        sa.Column('created_at', sa.DateTime(), nullable=True),
        sa.Column('decided_at', sa.DateTime(), nullable=True),
        sa.ForeignKeyConstraint(['user_id'], ['users.id'], ),
        sa.ForeignKeyConstraint(['share_link_id'], ['time_off_share_links.id'], ),
        sa.ForeignKeyConstraint(['time_off_id'], ['time_off.id'], ),
        sa.PrimaryKeyConstraint('id'),
    )
    with op.batch_alter_table('time_off_requests', schema=None) as batch_op:
        batch_op.create_index(batch_op.f('ix_time_off_requests_user_id'), ['user_id'], unique=False)
        batch_op.create_index(batch_op.f('ix_time_off_requests_share_link_id'), ['share_link_id'], unique=False)
        batch_op.create_index(batch_op.f('ix_time_off_requests_time_off_id'), ['time_off_id'], unique=False)


def downgrade():
    with op.batch_alter_table('time_off_requests', schema=None) as batch_op:
        batch_op.drop_index(batch_op.f('ix_time_off_requests_time_off_id'))
        batch_op.drop_index(batch_op.f('ix_time_off_requests_share_link_id'))
        batch_op.drop_index(batch_op.f('ix_time_off_requests_user_id'))

    op.drop_table('time_off_requests')
