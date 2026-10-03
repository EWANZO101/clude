"""add instance_backups.contents_summary

Revision ID: 6807f9705c29
Revises: e45ad8717a61
Create Date: 2026-09-11 22:50:00.000000

Applied directly against the running SQLite file (see
backups/pre_backup_contents_summary_*.db for the pre-change snapshot),
same as every migration since f2a6c3e91d47 — see that migration's own
docstring for why this repo's history doesn't go through
`flask db upgrade` normally right now. Chained after e45ad8717a61 to
match the live database's current alembic_version stamp.
"""
from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision = '6807f9705c29'
down_revision = 'e45ad8717a61'
branch_labels = None
depends_on = None


def upgrade():
    with op.batch_alter_table('instance_backups', schema=None) as batch_op:
        batch_op.add_column(sa.Column('contents_summary', sa.Text(), nullable=True))


def downgrade():
    with op.batch_alter_table('instance_backups', schema=None) as batch_op:
        batch_op.drop_column('contents_summary')
