"""remember last-applied kiosk configure fields on Instance

Revision ID: f7c3a5e91b8d
Revises: d7f1c9a4e2b6
Create Date: 2026-09-09 09:04:00.000000

Real incident (2026-09-09): the "Configure what starts the kiosk process"
form has never pre-filled the current values (only placeholders), and
submitting it with the start command left blank silently stops the kiosk
process (see instances.py::kiosk_configure / agent/commands.py::
_apply_configure) -- a real live instance's kiosk process nearly got
stopped by accident while only trying to turn on inventory sync, since
there was no way to know or re-enter the command already running there.
Storing what the Admin Panel itself last requested lets the form pre-fill
instead of always rendering blank. Applied directly against the running
SQLite file (see backups/pre_kiosk_configure_safety_*.db for the
pre-change snapshot), same as the migrations before it -- see
f2a6c3e91d47's docstring.
"""
from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision = 'f7c3a5e91b8d'
down_revision = 'd7f1c9a4e2b6'
branch_labels = None
depends_on = None


def upgrade():
    with op.batch_alter_table('instances', schema=None) as batch_op:
        batch_op.add_column(sa.Column('last_kiosk_start_command', sa.String(length=1000), nullable=True))
        batch_op.add_column(sa.Column('last_kiosk_working_dir', sa.String(length=500), nullable=True))
        batch_op.add_column(sa.Column('last_kiosk_health_check_url', sa.String(length=500), nullable=True))
        batch_op.add_column(sa.Column('last_kiosk_health_check_command', sa.String(length=500), nullable=True))
        batch_op.add_column(sa.Column('last_kiosk_inventory_sync_url', sa.String(length=500), nullable=True))


def downgrade():
    with op.batch_alter_table('instances', schema=None) as batch_op:
        batch_op.drop_column('last_kiosk_inventory_sync_url')
        batch_op.drop_column('last_kiosk_health_check_command')
        batch_op.drop_column('last_kiosk_health_check_url')
        batch_op.drop_column('last_kiosk_working_dir')
        batch_op.drop_column('last_kiosk_start_command')
