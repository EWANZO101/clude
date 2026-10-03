"""add Client Portal (client_users, client_instance_access, client_action_log, users.is_service_account)

Revision ID: a8d3f6b21e0c
Revises: f2a6c3e91d47
Create Date: 2026-09-08 22:09:00.000000

Applied directly against the running SQLite file (see
backups/pre_client_portal_*.db for the pre-change snapshot) the same way as
f2a6c3e91d47 — see that migration's docstring for why this repo's history
isn't run through `flask db upgrade` in the ordinary way right now.
"""
from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision = 'a8d3f6b21e0c'
down_revision = 'f2a6c3e91d47'
branch_labels = None
depends_on = None


def upgrade():
    with op.batch_alter_table('users', schema=None) as batch_op:
        batch_op.add_column(sa.Column(
            'is_service_account', sa.Boolean(), nullable=False, server_default=sa.false(),
        ))

    op.create_table(
        'client_users',
        sa.Column('id', sa.Integer(), nullable=False),
        sa.Column('public_id', sa.String(length=36), nullable=False),
        sa.Column('email', sa.String(length=255), nullable=False),
        sa.Column('full_name', sa.String(length=255), nullable=False),
        sa.Column('password_hash', sa.String(length=255), nullable=False),
        sa.Column('is_active', sa.Boolean(), nullable=False),
        sa.Column('created_at', sa.DateTime(), nullable=False),
        sa.Column('last_login_at', sa.DateTime(), nullable=True),
        sa.PrimaryKeyConstraint('id', name=op.f('pk_client_users')),
        sa.UniqueConstraint('public_id', name=op.f('uq_client_users_public_id')),
        sa.UniqueConstraint('email', name=op.f('uq_client_users_email')),
    )

    op.create_table(
        'client_instance_access',
        sa.Column('id', sa.Integer(), nullable=False),
        sa.Column('client_user_id', sa.Integer(), nullable=False),
        sa.Column('instance_id', sa.Integer(), nullable=False),
        sa.Column('granted_by_id', sa.Integer(), nullable=False),
        sa.Column('created_at', sa.DateTime(), nullable=False),
        sa.ForeignKeyConstraint(['client_user_id'], ['client_users.id'], name=op.f('fk_client_instance_access_client_user_id_client_users')),
        sa.ForeignKeyConstraint(['instance_id'], ['instances.id'], name=op.f('fk_client_instance_access_instance_id_instances')),
        sa.ForeignKeyConstraint(['granted_by_id'], ['users.id'], name=op.f('fk_client_instance_access_granted_by_id_users')),
        sa.PrimaryKeyConstraint('id', name=op.f('pk_client_instance_access')),
        sa.UniqueConstraint('client_user_id', 'instance_id', name=op.f('uq_client_instance_access_client_user_id')),
    )

    op.create_table(
        'client_action_log',
        sa.Column('id', sa.Integer(), nullable=False),
        sa.Column('client_user_id', sa.Integer(), nullable=False),
        sa.Column('instance_id', sa.Integer(), nullable=True),
        sa.Column('action', sa.String(length=64), nullable=False),
        sa.Column('detail', sa.Text(), nullable=True),
        sa.Column('created_at', sa.DateTime(), nullable=False),
        sa.ForeignKeyConstraint(['client_user_id'], ['client_users.id'], name=op.f('fk_client_action_log_client_user_id_client_users')),
        sa.ForeignKeyConstraint(['instance_id'], ['instances.id'], name=op.f('fk_client_action_log_instance_id_instances')),
        sa.PrimaryKeyConstraint('id', name=op.f('pk_client_action_log')),
    )


def downgrade():
    op.drop_table('client_action_log')
    op.drop_table('client_instance_access')
    op.drop_table('client_users')
    with op.batch_alter_table('users', schema=None) as batch_op:
        batch_op.drop_column('is_service_account')
