"""add out of hours bookings

Revision ID: 32925cbc8dca
Revises: 3c9108a5b114
Create Date: 2026-08-12 22:58:04.262214

"""
from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision = '32925cbc8dca'
down_revision = '3c9108a5b114'
branch_labels = None
depends_on = None


def upgrade():
    # NOT NULL boolean columns start nullable so this works against tables
    # that may already have rows — backfilled to False below, then
    # tightened to NOT NULL once every row has a value.
    with op.batch_alter_table('bookings', schema=None) as batch_op:
        batch_op.add_column(sa.Column('is_out_of_hours', sa.Boolean(), nullable=True))
        batch_op.add_column(sa.Column('out_of_hours_fee_shown', sa.String(length=30), nullable=True))

    with op.batch_alter_table('settings', schema=None) as batch_op:
        batch_op.add_column(sa.Column('allow_out_of_hours_bookings', sa.Boolean(), nullable=True))
        batch_op.add_column(sa.Column('out_of_hours_booking_fee', sa.String(length=30), nullable=True))

    connection = op.get_bind()
    connection.execute(sa.text("UPDATE bookings SET is_out_of_hours = 0 WHERE is_out_of_hours IS NULL"))
    connection.execute(
        sa.text("UPDATE settings SET allow_out_of_hours_bookings = 0 WHERE allow_out_of_hours_bookings IS NULL")
    )

    with op.batch_alter_table('bookings', schema=None) as batch_op:
        batch_op.alter_column('is_out_of_hours', existing_type=sa.Boolean(), nullable=False)

    with op.batch_alter_table('settings', schema=None) as batch_op:
        batch_op.alter_column('allow_out_of_hours_bookings', existing_type=sa.Boolean(), nullable=False)


def downgrade():
    with op.batch_alter_table('settings', schema=None) as batch_op:
        batch_op.drop_column('out_of_hours_booking_fee')
        batch_op.drop_column('allow_out_of_hours_bookings')

    with op.batch_alter_table('bookings', schema=None) as batch_op:
        batch_op.drop_column('out_of_hours_fee_shown')
        batch_op.drop_column('is_out_of_hours')
