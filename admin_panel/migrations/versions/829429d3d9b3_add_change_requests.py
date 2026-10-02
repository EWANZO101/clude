"""add change_requests table (client-submitted update/change requests)

Revision ID: 829429d3d9b3
Revises: b3e7d19a4c58
Create Date: 2026-09-11 18:20:00.000000

Applied directly against the running SQLite file (see
backups/pre_change_requests_*.db for the pre-change snapshot), same as
every migration since f2a6c3e91d47 — see that migration's own docstring
for why this repo's history doesn't go through `flask db upgrade`
normally right now. Chained after b3e7d19a4c58 to match the live
database's current alembic_version stamp.
"""
from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision = '829429d3d9b3'
down_revision = 'b3e7d19a4c58'
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        'change_requests',
        sa.Column('id', sa.Integer(), primary_key=True),
        sa.Column('public_id', sa.String(length=36), nullable=False),
        sa.Column('client_user_id', sa.Integer(), sa.ForeignKey('client_users.id'), nullable=False),
        sa.Column('instance_id', sa.Integer(), sa.ForeignKey('instances.id'), nullable=False),
        sa.Column('title', sa.String(length=200), nullable=False),
        sa.Column('description', sa.Text(), nullable=False),
        sa.Column('status', sa.String(length=16), nullable=False, server_default='open'),
        sa.Column('admin_response', sa.Text(), nullable=True),
        sa.Column('resolved_by_id', sa.Integer(), sa.ForeignKey('users.id'), nullable=True),
        sa.Column('resolved_at', sa.DateTime(), nullable=True),
        sa.Column('created_at', sa.DateTime(), nullable=False),
        sa.Column('updated_at', sa.DateTime(), nullable=False),
        sa.UniqueConstraint('public_id', name='uq_change_requests_public_id'),
    )
    with op.batch_alter_table('change_requests', schema=None) as batch_op:
        batch_op.create_index('ix_change_requests_client_user_id', ['client_user_id'])
        batch_op.create_index('ix_change_requests_instance_id', ['instance_id'])
        batch_op.create_index('ix_change_requests_status', ['status'])


def downgrade():
    op.drop_table('change_requests')
