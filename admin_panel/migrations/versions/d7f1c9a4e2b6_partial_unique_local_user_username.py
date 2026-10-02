"""make instance_local_users username uniqueness partial (exclude removed rows)

Revision ID: d7f1c9a4e2b6
Revises: c4e91b7a3f52
Create Date: 2026-09-08 23:20:00.000000

Bug fix: the plain unique index added in c4e91b7a3f52 kept a removed
(soft-deleted) local user's username permanently reserved, since a
tombstoned row still physically exists — "remove Jamie, add a new Jamie"
would silently collide against the row nobody can see anymore. Only rows
that are still actually visible (deleted_at IS NULL) should compete for a
username; see the matching deleted_at.is_(None) filter added to every
clash-check query in instances.py/agent_api.py alongside this migration.

Applied directly against the running SQLite file (see
backups/pre_partial_username_index_*.db for the pre-change snapshot),
same as the migrations before it — see f2a6c3e91d47's docstring.
"""
from alembic import op


# revision identifiers, used by Alembic.
revision = 'd7f1c9a4e2b6'
down_revision = 'c4e91b7a3f52'
branch_labels = None
depends_on = None


def upgrade():
    op.drop_index('uq_instance_local_user_username', table_name='instance_local_users')
    op.create_index(
        'uq_instance_local_user_username', 'instance_local_users', ['instance_id', 'username'],
        unique=True, sqlite_where='deleted_at IS NULL',
    )


def downgrade():
    op.drop_index('uq_instance_local_user_username', table_name='instance_local_users')
    op.create_index(
        'uq_instance_local_user_username', 'instance_local_users', ['instance_id', 'username'],
        unique=True,
    )
