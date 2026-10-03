"""invitation invited_by_user_id nullable with ON DELETE SET NULL

Revision ID: 3870c47e8c04
Revises: 79a886e3dbdb
Create Date: 2026-09-23 17:46:29.652359

"""
from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision = '3870c47e8c04'
down_revision = '79a886e3dbdb'
branch_labels = None
depends_on = None


def upgrade():
    # Removing a user who previously sent invites must not be blocked by (or
    # cascade-delete) the invitations they sent — SET NULL instead.
    # (The spurious company.owner_user_id FK re-add that autogenerate produced here
    # was dropped — that constraint already exists from the initial migration and
    # this revision doesn't touch it.)
    with op.batch_alter_table('invitation', schema=None) as batch_op:
        batch_op.alter_column('invited_by_user_id',
               existing_type=sa.INTEGER(),
               nullable=True)
        batch_op.drop_constraint('invitation_invited_by_user_id_fkey', type_='foreignkey')
        batch_op.create_foreign_key('invitation_invited_by_user_id_fkey', 'user',
                                     ['invited_by_user_id'], ['id'], ondelete='SET NULL')


def downgrade():
    with op.batch_alter_table('invitation', schema=None) as batch_op:
        batch_op.drop_constraint('invitation_invited_by_user_id_fkey', type_='foreignkey')
        batch_op.create_foreign_key('invitation_invited_by_user_id_fkey', 'user',
                                     ['invited_by_user_id'], ['id'])
        batch_op.alter_column('invited_by_user_id',
               existing_type=sa.INTEGER(),
               nullable=False)
