"""add instance_commands.started_at (real in-progress signal)

Revision ID: 9a1f2c7d4e6b
Revises: 43263d930ff3
Create Date: 2026-09-08 15:10:00.000000

Part of the Kiosk Process status recode: previously the Admin Panel had no
way to know when the Agent actually started executing a queued command,
only when it was queued (created_at) and when it finished (acked_at). The
UI's "live" status was therefore guessing progress from a single click
timestamp, including guessing confidently even while the Agent hadn't
picked the command up yet at all. This column is set by the new
start_command endpoint (agent_api.py), called by agent/commands.py the
moment it picks a command off the queue, before executing it — giving the
UI a real second anchor point instead of an estimate.
"""
from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision = '9a1f2c7d4e6b'
down_revision = '43263d930ff3'
branch_labels = None
depends_on = None


def upgrade():
    with op.batch_alter_table('instance_commands', schema=None) as batch_op:
        batch_op.add_column(sa.Column('started_at', sa.DateTime(), nullable=True))


def downgrade():
    with op.batch_alter_table('instance_commands', schema=None) as batch_op:
        batch_op.drop_column('started_at')
