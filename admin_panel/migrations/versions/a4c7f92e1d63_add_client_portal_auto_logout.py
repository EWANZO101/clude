"""add platform_settings.client_portal_auto_logout_minutes

Revision ID: a4c7f92e1d63
Revises: f9a2d5c81e64
Create Date: 2026-09-09 16:45:00.000000

Chained after f9a2d5c81e64, applied directly against the running SQLite
file and stamped — same convention as every other migration this session
(see f2a6c3e91d47's own docstring for why this repo's history doesn't go
through a clean `flask db upgrade` from the true tip).
"""
from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision = 'a4c7f92e1d63'
down_revision = 'f9a2d5c81e64'
branch_labels = None
depends_on = None


def upgrade():
    with op.batch_alter_table('platform_settings', schema=None) as batch_op:
        batch_op.add_column(sa.Column('client_portal_auto_logout_minutes', sa.Integer(), nullable=False, server_default='2'))


def downgrade():
    with op.batch_alter_table('platform_settings', schema=None) as batch_op:
        batch_op.drop_column('client_portal_auto_logout_minutes')
