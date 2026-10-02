"""add company api_key

Revision ID: 14c88cbc5c5b
Revises: c65024854fc4
Create Date: 2026-09-23 18:26:34.915932

"""
from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision = '14c88cbc5c5b'
down_revision = 'c65024854fc4'
branch_labels = None
depends_on = None


def upgrade():
    with op.batch_alter_table('company', schema=None) as batch_op:
        batch_op.add_column(sa.Column('api_key', sa.String(length=64), nullable=True))
        batch_op.create_unique_constraint('uq_company_api_key', ['api_key'])


def downgrade():
    with op.batch_alter_table('company', schema=None) as batch_op:
        batch_op.drop_constraint('uq_company_api_key', type_='unique')
        batch_op.drop_column('api_key')
