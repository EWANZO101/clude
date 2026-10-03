"""add update_packages.file_listing (Package contents debug view)

Revision ID: f2a6c3e91d47
Revises: c6f1a9e3d7b2
Create Date: 2026-09-08 21:54:00.000000

NOTE: chained after c6f1a9e3d7b2 to match this database's current
alembic_version stamp, not necessarily the true tip of history — this
repo already has two migration heads (c6f1a9e3d7b2 and d1a4e7f92b3c both
branch from b4d8f2a1c6e9) that were never reconciled with a merge
revision, and the live schema already has tables from both branches
applied by some means other than `flask db upgrade`. Applying THIS
column was done directly against the running SQLite file (see
backups/pre_file_listing_column_*.db for the pre-change snapshot), not
via `flask db upgrade` — left unresolved here rather than guessing at a
merge migration for history this migration didn't create.
"""
from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision = 'f2a6c3e91d47'
down_revision = 'c6f1a9e3d7b2'
branch_labels = None
depends_on = None


def upgrade():
    with op.batch_alter_table('update_packages', schema=None) as batch_op:
        batch_op.add_column(sa.Column('file_listing', sa.Text(), nullable=True))


def downgrade():
    with op.batch_alter_table('update_packages', schema=None) as batch_op:
        batch_op.drop_column('file_listing')
