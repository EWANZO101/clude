"""add isp support reference, out of hours fee

Revision ID: 3c9108a5b114
Revises: c709f4333571
Create Date: 2026-08-12 22:29:01.599222

"""
import secrets

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision = '3c9108a5b114'
down_revision = 'c709f4333571'
branch_labels = None
depends_on = None


def upgrade():
    with op.batch_alter_table('settings', schema=None) as batch_op:
        batch_op.add_column(sa.Column('isp_out_of_hours_fee', sa.String(length=30), nullable=True))

    # reference/submitted_out_of_hours start nullable so this works against
    # a table that may already have rows (from before this migration) —
    # backfilled below, then tightened to NOT NULL once every row has a
    # value.
    with op.batch_alter_table('support_requests', schema=None) as batch_op:
        batch_op.add_column(sa.Column('reference', sa.String(length=12), nullable=True))
        batch_op.add_column(sa.Column('submitted_out_of_hours', sa.Boolean(), nullable=True))
        batch_op.add_column(sa.Column('out_of_hours_fee_shown', sa.String(length=30), nullable=True))

    connection = op.get_bind()
    support_requests = sa.table(
        'support_requests',
        sa.column('id', sa.Integer),
        sa.column('reference', sa.String),
        sa.column('submitted_out_of_hours', sa.Boolean),
    )
    existing_ids = [row[0] for row in connection.execute(sa.select(support_requests.c.id))]
    seen = set()
    for row_id in existing_ids:
        ref = secrets.token_hex(4).upper()
        while ref in seen:
            ref = secrets.token_hex(4).upper()
        seen.add(ref)
        connection.execute(
            support_requests.update()
            .where(support_requests.c.id == row_id)
            .values(reference=ref, submitted_out_of_hours=False)
        )

    with op.batch_alter_table('support_requests', schema=None) as batch_op:
        batch_op.alter_column('reference', existing_type=sa.String(length=12), nullable=False)
        batch_op.alter_column('submitted_out_of_hours', existing_type=sa.Boolean(), nullable=False)
        batch_op.create_index(batch_op.f('ix_support_requests_reference'), ['reference'], unique=True)


def downgrade():
    with op.batch_alter_table('support_requests', schema=None) as batch_op:
        batch_op.drop_index(batch_op.f('ix_support_requests_reference'))
        batch_op.drop_column('out_of_hours_fee_shown')
        batch_op.drop_column('submitted_out_of_hours')
        batch_op.drop_column('reference')

    with op.batch_alter_table('settings', schema=None) as batch_op:
        batch_op.drop_column('isp_out_of_hours_fee')
