"""Add public_token to shared_calendars

Revision ID: e2f6a8c1b3d5
Revises: 7a1c9f2b3d4e
Create Date: 2026-08-14 12:00:00.000000

"""
import secrets

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision = 'e2f6a8c1b3d5'
down_revision = '7a1c9f2b3d4e'
branch_labels = None
depends_on = None


def upgrade():
    # Add nullable first — existing rows have nothing to put here yet.
    with op.batch_alter_table('shared_calendars', schema=None) as batch_op:
        batch_op.add_column(sa.Column('public_token', sa.String(length=32), nullable=True))

    # Backfill every calendar that already exists with its own public
    # link, so nothing already-shared is left without one.
    conn = op.get_bind()
    shared_calendars = sa.table(
        'shared_calendars',
        sa.column('id', sa.Integer),
        sa.column('public_token', sa.String),
    )
    existing_ids = [row[0] for row in conn.execute(sa.select(shared_calendars.c.id))]
    for calendar_id in existing_ids:
        conn.execute(
            shared_calendars.update()
            .where(shared_calendars.c.id == calendar_id)
            .values(public_token=secrets.token_urlsafe(9))
        )

    # Now that every row has one, enforce not-null + uniqueness.
    with op.batch_alter_table('shared_calendars', schema=None) as batch_op:
        batch_op.alter_column('public_token', existing_type=sa.String(length=32), nullable=False)
        batch_op.create_unique_constraint('uq_shared_calendars_public_token', ['public_token'])


def downgrade():
    with op.batch_alter_table('shared_calendars', schema=None) as batch_op:
        batch_op.drop_constraint('uq_shared_calendars_public_token', type_='unique')
        batch_op.drop_column('public_token')
