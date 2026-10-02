"""add enrollment_tokens.license_duration_days (token-as-license-term)

Revision ID: c2f7a4e83b91
Revises: e8b4c1f92a7d
Create Date: 2026-09-09 15:40:00.000000

Chained after e8b4c1f92a7d, applied directly against the running SQLite
file and stamped — same convention as that migration (see its own
docstring for why this repo's history doesn't go through a clean
`flask db upgrade` from the true tip).
"""
from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision = 'c2f7a4e83b91'
down_revision = 'e8b4c1f92a7d'
branch_labels = None
depends_on = None


def upgrade():
    with op.batch_alter_table('enrollment_tokens', schema=None) as batch_op:
        batch_op.add_column(sa.Column('license_duration_days', sa.Integer(), nullable=True))


def downgrade():
    with op.batch_alter_table('enrollment_tokens', schema=None) as batch_op:
        batch_op.drop_column('license_duration_days')
