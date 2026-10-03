"""add instance_roles (cached kiosk Role/RolePermission/RoleSidebarPermission state)

Revision ID: f9a2d5c81e64
Revises: c2f7a4e83b91
Create Date: 2026-09-09 16:10:00.000000

Chained after c2f7a4e83b91, applied directly against the running SQLite
file and stamped — same convention as every other migration this session
(see f2a6c3e91d47's own docstring for why this repo's history doesn't go
through a clean `flask db upgrade` from the true tip).
"""
from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision = 'f9a2d5c81e64'
down_revision = 'c2f7a4e83b91'
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        'instance_roles',
        sa.Column('id', sa.Integer(), nullable=False),
        sa.Column('instance_id', sa.Integer(), nullable=False),
        sa.Column('name', sa.String(length=32), nullable=False),
        sa.Column('is_builtin', sa.Boolean(), nullable=False),
        sa.Column('user_count', sa.Integer(), nullable=False),
        sa.Column('login_enabled', sa.Boolean(), nullable=False),
        sa.Column('sidebar_json', sa.Text(), nullable=True),
        sa.Column('updated_at', sa.DateTime(), nullable=False),
        sa.ForeignKeyConstraint(['instance_id'], ['instances.id'], name=op.f('fk_instance_roles_instance_id_instances')),
        sa.PrimaryKeyConstraint('id', name=op.f('pk_instance_roles')),
        sa.UniqueConstraint('instance_id', 'name', name='uq_instance_role_name'),
    )


def downgrade():
    op.drop_table('instance_roles')
