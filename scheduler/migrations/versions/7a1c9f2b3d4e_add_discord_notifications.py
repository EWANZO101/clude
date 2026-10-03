"""Add Discord bot notification fields

Revision ID: 7a1c9f2b3d4e
Revises: 32925cbc8dca
Create Date: 2026-08-14 00:00:00.000000

"""
from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision = '7a1c9f2b3d4e'
down_revision = '32925cbc8dca'
branch_labels = None
depends_on = None


def upgrade():
    with op.batch_alter_table('settings', schema=None) as batch_op:
        batch_op.add_column(sa.Column('discord_user_id', sa.String(length=32), nullable=True))
        batch_op.add_column(sa.Column('notify_discord_new_booking', sa.Boolean(), nullable=False, server_default=sa.true()))
        batch_op.add_column(sa.Column('notify_discord_cancellation', sa.Boolean(), nullable=False, server_default=sa.true()))
        batch_op.add_column(sa.Column('notify_discord_reminders', sa.Boolean(), nullable=False, server_default=sa.true()))
        batch_op.add_column(sa.Column('discord_test_requested_at', sa.DateTime(), nullable=True))
        batch_op.add_column(sa.Column('discord_spam_ping_enabled', sa.Boolean(), nullable=False, server_default=sa.true()))

    with op.batch_alter_table('bookings', schema=None) as batch_op:
        batch_op.add_column(sa.Column('discord_new_notified', sa.Boolean(), nullable=False, server_default=sa.false()))
        batch_op.add_column(sa.Column('discord_cancel_notified', sa.Boolean(), nullable=False, server_default=sa.false()))
        batch_op.add_column(sa.Column('discord_day_reminder_sent', sa.Boolean(), nullable=False, server_default=sa.false()))
        batch_op.add_column(sa.Column('discord_hour_reminder_sent', sa.Boolean(), nullable=False, server_default=sa.false()))
        batch_op.add_column(sa.Column('discord_15min_reminder_sent', sa.Boolean(), nullable=False, server_default=sa.false()))
        batch_op.add_column(sa.Column('discord_ping_active', sa.Boolean(), nullable=False, server_default=sa.false()))
        batch_op.add_column(sa.Column('discord_ping_count', sa.Integer(), nullable=False, server_default='0'))
        batch_op.add_column(sa.Column('discord_ping_last_sent_at', sa.DateTime(), nullable=True))
        batch_op.add_column(sa.Column('discord_ping_last_message_id', sa.String(length=32), nullable=True))


def downgrade():
    with op.batch_alter_table('bookings', schema=None) as batch_op:
        batch_op.drop_column('discord_ping_last_message_id')
        batch_op.drop_column('discord_ping_last_sent_at')
        batch_op.drop_column('discord_ping_count')
        batch_op.drop_column('discord_ping_active')
        batch_op.drop_column('discord_15min_reminder_sent')
        batch_op.drop_column('discord_hour_reminder_sent')
        batch_op.drop_column('discord_day_reminder_sent')
        batch_op.drop_column('discord_cancel_notified')
        batch_op.drop_column('discord_new_notified')

    with op.batch_alter_table('settings', schema=None) as batch_op:
        batch_op.drop_column('discord_spam_ping_enabled')
        batch_op.drop_column('discord_test_requested_at')
        batch_op.drop_column('notify_discord_reminders')
        batch_op.drop_column('notify_discord_cancellation')
        batch_op.drop_column('notify_discord_new_booking')
        batch_op.drop_column('discord_user_id')
