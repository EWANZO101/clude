"""add instances.license_status / license_expires_at (suspend/expiry kill switch)

Revision ID: e8b4c1f92a7d
Revises: f7c3a5e91b8d
Create Date: 2026-09-09 15:32:00.000000

NOTE: chained after f7c3a5e91b8d to match this database's current
alembic_version stamp, not necessarily the true tip of history — this
repo already has two unreconciled migration heads (see f2a6c3e91d47's own
docstring). Applied directly against the running SQLite file (see
backups/pre_instance_licensing_*.db for the pre-change snapshot), then
stamped, same as that migration and a8d3f6b21e0c before it.
"""
from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision = 'e8b4c1f92a7d'
down_revision = 'f7c3a5e91b8d'
branch_labels = None
depends_on = None


def upgrade():
    with op.batch_alter_table('instances', schema=None) as batch_op:
        batch_op.add_column(sa.Column('license_status', sa.String(length=16), nullable=False, server_default='active'))
        batch_op.add_column(sa.Column('license_expires_at', sa.DateTime(), nullable=True))


def downgrade():
    with op.batch_alter_table('instances', schema=None) as batch_op:
        batch_op.drop_column('license_expires_at')
        batch_op.drop_column('license_status')
