"""add missing company owner_user_id fk

Revision ID: 22bdde3763b5
Revises: 3870c47e8c04
Create Date: 2026-09-23 17:47:11.646737

"""
from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision = '22bdde3763b5'
down_revision = '3870c47e8c04'
branch_labels = None
depends_on = None


def upgrade():
    # The initial migration's inline `use_alter=True` FK on company.owner_user_id was
    # never actually emitted as a constraint — confirmed missing via `\d company`
    # against the live DB. Add it explicitly, named this time. No deferred/deferrable
    # needed: the app always inserts Company with owner_user_id=NULL, flushes to get
    # the User row created, then sets owner_user_id afterward — never referencing a
    # not-yet-existing user row.
    with op.batch_alter_table('company', schema=None) as batch_op:
        batch_op.create_foreign_key('company_owner_user_id_fkey', 'user',
                                     ['owner_user_id'], ['id'], use_alter=True)


def downgrade():
    with op.batch_alter_table('company', schema=None) as batch_op:
        batch_op.drop_constraint('company_owner_user_id_fkey', type_='foreignkey')
