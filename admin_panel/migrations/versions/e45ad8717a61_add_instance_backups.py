"""add instance backup schedule fields + instance_backups table

Revision ID: e45ad8717a61
Revises: e7cf76d928c6
Create Date: 2026-09-11 22:15:00.000000

Applied directly against the running SQLite file (see
backups/pre_instance_backups_*.db for the pre-change snapshot), same as
every migration since f2a6c3e91d47 — see that migration's own docstring
for why this repo's history doesn't go through `flask db upgrade`
normally right now. Chained after e7cf76d928c6 to match the live
database's current alembic_version stamp.
"""
from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision = 'e45ad8717a61'
down_revision = 'e7cf76d928c6'
branch_labels = None
depends_on = None


def upgrade():
    with op.batch_alter_table('instances', schema=None) as batch_op:
        batch_op.add_column(sa.Column('backup_time', sa.Time(), nullable=True))
        batch_op.add_column(sa.Column('backup_timezone', sa.String(length=64), nullable=True))
        batch_op.add_column(sa.Column('backup_local_daily_enabled', sa.Boolean(), nullable=False, server_default=sa.false()))
        batch_op.add_column(sa.Column('backup_cloud_enabled', sa.Boolean(), nullable=False, server_default=sa.false()))
        batch_op.add_column(sa.Column('last_cloud_backup_at', sa.DateTime(), nullable=True))

    op.create_table(
        'instance_backups',
        sa.Column('id', sa.Integer(), primary_key=True),
        sa.Column('public_id', sa.String(length=36), nullable=False),
        sa.Column('instance_id', sa.Integer(), sa.ForeignKey('instances.id'), nullable=False),
        sa.Column('filename', sa.String(length=255), nullable=False),
        sa.Column('file_path', sa.String(length=1000), nullable=False),
        sa.Column('file_size', sa.Integer(), nullable=False),
        sa.Column('source', sa.String(length=16), nullable=False, server_default='scheduled'),
        sa.Column('created_at', sa.DateTime(), nullable=False),
        sa.UniqueConstraint('public_id', name='uq_instance_backups_public_id'),
    )
    with op.batch_alter_table('instance_backups', schema=None) as batch_op:
        batch_op.create_index('ix_instance_backups_instance_id', ['instance_id'])


def downgrade():
    op.drop_table('instance_backups')
    with op.batch_alter_table('instances', schema=None) as batch_op:
        batch_op.drop_column('last_cloud_backup_at')
        batch_op.drop_column('backup_cloud_enabled')
        batch_op.drop_column('backup_local_daily_enabled')
        batch_op.drop_column('backup_timezone')
        batch_op.drop_column('backup_time')
