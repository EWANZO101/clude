"""add platform_settings and agent_error_reports

Revision ID: d1a4e7f92b3c
Revises: b4d8f2a1c6e9
Create Date: 2026-09-08 20:55:00.000000

Both PlatformSetting and AgentErrorReport have existed in app/models.py for
some time, but neither ever got a migration committed to actually create
their table -- the same class of gap already fixed once in
5b6d0cfe37f3_sync_schema_with_named_constraints.py for
remote_access_tokens.public_id/status. A genuinely fresh database has no
way to end up with these tables otherwise (confirmed by cross-checking
every model's __tablename__ against every op.create_table(...) call across
the whole migrations/versions/ directory -- these two were the only ones
still missing).

platform_settings is a singleton (PlatformSetting.get() lazily inserts row
id=1 on first use), so it's created empty here rather than pre-seeded.
"""
from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision = 'd1a4e7f92b3c'
down_revision = 'b4d8f2a1c6e9'
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        'platform_settings',
        sa.Column('id', sa.Integer(), nullable=False),
        sa.Column('signups_enabled', sa.Boolean(), nullable=False),
        sa.PrimaryKeyConstraint('id', name=op.f('pk_platform_settings')),
    )

    op.create_table(
        'agent_error_reports',
        sa.Column('id', sa.Integer(), nullable=False),
        sa.Column('instance_id', sa.Integer(), nullable=False),
        sa.Column('level', sa.String(length=16), nullable=False),
        sa.Column('logger_name', sa.String(length=128), nullable=True),
        sa.Column('message', sa.Text(), nullable=False),
        sa.Column('traceback', sa.Text(), nullable=True),
        sa.Column('suppressed_since_last', sa.Integer(), nullable=False),
        sa.Column('created_at', sa.DateTime(), nullable=False),
        sa.ForeignKeyConstraint(
            ['instance_id'], ['instances.id'],
            name=op.f('fk_agent_error_reports_instance_id_instances'),
        ),
        sa.PrimaryKeyConstraint('id', name=op.f('pk_agent_error_reports')),
    )


def downgrade():
    op.drop_table('agent_error_reports')
    op.drop_table('platform_settings')
