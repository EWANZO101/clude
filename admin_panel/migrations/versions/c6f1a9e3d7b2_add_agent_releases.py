"""add agent_releases (versioned, validated Agent publishes)

Revision ID: c6f1a9e3d7b2
Revises: b4d8f2a1c6e9
Create Date: 2026-09-08 18:00:00.000000
"""
from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision = 'c6f1a9e3d7b2'
down_revision = 'b4d8f2a1c6e9'
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        'agent_releases',
        sa.Column('id', sa.Integer(), nullable=False),
        sa.Column('public_id', sa.String(length=36), nullable=False),
        sa.Column('version', sa.String(length=32), nullable=False),
        sa.Column('release_notes', sa.Text(), nullable=True),
        sa.Column('file_path', sa.String(length=512), nullable=False),
        sa.Column('file_size', sa.Integer(), nullable=False),
        sa.Column('checksum_sha256', sa.String(length=64), nullable=False),
        sa.Column('published_by_id', sa.Integer(), nullable=False),
        sa.Column('published_at', sa.DateTime(), nullable=False),
        sa.ForeignKeyConstraint(
            ['published_by_id'], ['users.id'],
            name=op.f('fk_agent_releases_published_by_id_users'),
        ),
        sa.PrimaryKeyConstraint('id', name=op.f('pk_agent_releases')),
        sa.UniqueConstraint('public_id', name=op.f('uq_agent_releases_public_id')),
        sa.UniqueConstraint('version', name=op.f('uq_agent_releases_version')),
    )


def downgrade():
    op.drop_table('agent_releases')
