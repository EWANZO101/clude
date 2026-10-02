"""Multi-recipient Discord pings + dashboard action support

Revision ID: f4d9b2c7a1e6
Revises: e2f6a8c1b3d5
Create Date: 2026-08-14 15:00:00.000000

"""
from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision = 'f4d9b2c7a1e6'
down_revision = 'e2f6a8c1b3d5'
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        'discord_recipients',
        sa.Column('id', sa.Integer(), nullable=False),
        sa.Column('user_id', sa.Integer(), nullable=False),
        sa.Column('discord_user_id', sa.String(length=32), nullable=False),
        sa.Column('label', sa.String(length=80), nullable=True),
        sa.Column('created_at', sa.DateTime(), nullable=True),
        sa.ForeignKeyConstraint(['user_id'], ['users.id'], ),
        sa.PrimaryKeyConstraint('id'),
        sa.UniqueConstraint('user_id', 'discord_user_id', name='uq_discord_recipient'),
    )
    with op.batch_alter_table('discord_recipients', schema=None) as batch_op:
        batch_op.create_index(batch_op.f('ix_discord_recipients_user_id'), ['user_id'], unique=False)

    op.create_table(
        'booking_ping_states',
        sa.Column('id', sa.Integer(), nullable=False),
        sa.Column('booking_id', sa.Integer(), nullable=False),
        sa.Column('discord_user_id', sa.String(length=32), nullable=False),
        sa.Column('active', sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column('count', sa.Integer(), nullable=False, server_default='0'),
        sa.Column('last_sent_at', sa.DateTime(), nullable=True),
        sa.Column('last_message_id', sa.String(length=32), nullable=True),
        sa.ForeignKeyConstraint(['booking_id'], ['bookings.id'], ),
        sa.PrimaryKeyConstraint('id'),
        sa.UniqueConstraint('booking_id', 'discord_user_id', name='uq_booking_ping_recipient'),
    )
    with op.batch_alter_table('booking_ping_states', schema=None) as batch_op:
        batch_op.create_index(batch_op.f('ix_booking_ping_states_booking_id'), ['booking_id'], unique=False)

    # Old single-recipient ping tracking on Booking is superseded by
    # booking_ping_states above — nothing currently running depends on
    # these values surviving, so they're dropped rather than migrated.
    with op.batch_alter_table('bookings', schema=None) as batch_op:
        batch_op.drop_column('discord_ping_last_message_id')
        batch_op.drop_column('discord_ping_last_sent_at')
        batch_op.drop_column('discord_ping_count')
        batch_op.drop_column('discord_ping_active')


def downgrade():
    with op.batch_alter_table('bookings', schema=None) as batch_op:
        batch_op.add_column(sa.Column('discord_ping_active', sa.Boolean(), nullable=False, server_default=sa.false()))
        batch_op.add_column(sa.Column('discord_ping_count', sa.Integer(), nullable=False, server_default='0'))
        batch_op.add_column(sa.Column('discord_ping_last_sent_at', sa.DateTime(), nullable=True))
        batch_op.add_column(sa.Column('discord_ping_last_message_id', sa.String(length=32), nullable=True))

    with op.batch_alter_table('booking_ping_states', schema=None) as batch_op:
        batch_op.drop_index(batch_op.f('ix_booking_ping_states_booking_id'))
    op.drop_table('booking_ping_states')

    with op.batch_alter_table('discord_recipients', schema=None) as batch_op:
        batch_op.drop_index(batch_op.f('ix_discord_recipients_user_id'))
    op.drop_table('discord_recipients')
