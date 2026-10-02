"""add scan_tokens table (phone/scanner mini-app, no-login barcode lookup)

Revision ID: 008900b88a30
Revises: 829429d3d9b3
Create Date: 2026-09-11 20:05:00.000000

Applied directly against the running SQLite file (see
backups/pre_scan_tokens_*.db for the pre-change snapshot), same as every
migration since f2a6c3e91d47 — see that migration's own docstring for why
this repo's history doesn't go through `flask db upgrade` normally right
now. Chained after 829429d3d9b3 to match the live database's current
alembic_version stamp.
"""
from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision = '008900b88a30'
down_revision = '829429d3d9b3'
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        'scan_tokens',
        sa.Column('id', sa.Integer(), primary_key=True),
        sa.Column('token', sa.String(length=64), nullable=False),
        sa.Column('instance_id', sa.Integer(), sa.ForeignKey('instances.id'), nullable=False),
        sa.Column('label', sa.String(length=255), nullable=True),
        sa.Column('created_by_id', sa.Integer(), sa.ForeignKey('users.id'), nullable=False),
        sa.Column('created_at', sa.DateTime(), nullable=False),
        sa.Column('revoked', sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column('last_used_at', sa.DateTime(), nullable=True),
        sa.Column('use_count', sa.Integer(), nullable=False, server_default='0'),
        sa.UniqueConstraint('token', name='uq_scan_tokens_token'),
    )
    with op.batch_alter_table('scan_tokens', schema=None) as batch_op:
        batch_op.create_index('ix_scan_tokens_instance_id', ['instance_id'])
        batch_op.create_index('ix_scan_tokens_token', ['token'], unique=True)


def downgrade():
    op.drop_table('scan_tokens')
