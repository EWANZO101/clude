"""add product scoping to enrollment_tokens/instances/update_packages

Revision ID: 619d355f87ed
Revises: 6807f9705c29
Create Date: 2026-09-17 00:00:00.000000

Adds a second product ("inventory-ops") alongside Kiosk to the deploy
pipeline — see the plan this implements for the full design. Deliberately
branches off 6807f9705c29 (the revision this live database is actually
stamped at) rather than "head": migration d1a4e7f92b3c is a pre-existing,
never-applied second head whose tables (platform_settings,
agent_error_reports) already exist in the live schema by other means — a
pre-existing inconsistency this migration does not attempt to resolve, to
avoid entangling an unrelated fix with this change.

Every column added here is nullable-and-backward-compatible EXCEPT
update_packages.product_id, which is backfilled to the existing "kiosk"
Product's id for every current row and then made NOT NULL — required so the
new composite (product_id, version) unique constraint enforces the exact
same "kiosk versions are globally unique" guarantee the old plain
unique(version) did (a nullable product_id would silently defeat that:
SQLite treats every NULL as distinct for uniqueness purposes). Nothing about
enrollment_tokens/instances is touched beyond adding the nullable column —
every existing row stays NULL, meaning "kiosk", exactly as it behaves today.
"""
from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision = '619d355f87ed'
down_revision = '6807f9705c29'
branch_labels = None
depends_on = None


def upgrade():
    with op.batch_alter_table('enrollment_tokens', schema=None) as batch_op:
        batch_op.add_column(sa.Column('product_id', sa.Integer(), nullable=True))
        batch_op.create_foreign_key(
            batch_op.f('fk_enrollment_tokens_product_id_products'), 'products', ['product_id'], ['id'],
        )

    with op.batch_alter_table('instances', schema=None) as batch_op:
        batch_op.add_column(sa.Column('product_id', sa.Integer(), nullable=True))
        batch_op.create_foreign_key(
            batch_op.f('fk_instances_product_id_products'), 'products', ['product_id'], ['id'],
        )

    # update_packages: add nullable first so it can be backfilled, then
    # tighten to NOT NULL — a straight NOT NULL add_column would fail on
    # SQLite (and everywhere else) with existing rows and no default.
    with op.batch_alter_table('update_packages', schema=None) as batch_op:
        batch_op.add_column(sa.Column('product_id', sa.Integer(), nullable=True))

    kiosk_product_id = op.get_bind().execute(
        sa.text("SELECT id FROM products WHERE slug = 'kiosk'")
    ).scalar()
    if kiosk_product_id is None:
        raise RuntimeError(
            "no 'kiosk' Product row found — expected migration e7cf76d928c6 to have seeded one "
            "before this migration can backfill update_packages.product_id"
        )
    op.get_bind().execute(
        sa.text("UPDATE update_packages SET product_id = :pid WHERE product_id IS NULL"),
        {"pid": kiosk_product_id},
    )

    with op.batch_alter_table('update_packages', schema=None) as batch_op:
        batch_op.alter_column('product_id', existing_type=sa.Integer(), nullable=False)
        batch_op.create_foreign_key(
            batch_op.f('fk_update_packages_product_id_products'), 'products', ['product_id'], ['id'],
        )
        batch_op.drop_constraint(batch_op.f('uq_update_packages_version'), type_='unique')
        batch_op.create_unique_constraint(
            batch_op.f('uq_update_packages_product_id_version'), ['product_id', 'version'],
        )


def downgrade():
    with op.batch_alter_table('update_packages', schema=None) as batch_op:
        batch_op.drop_constraint(batch_op.f('uq_update_packages_product_id_version'), type_='unique')
        batch_op.create_unique_constraint(batch_op.f('uq_update_packages_version'), ['version'])
        batch_op.drop_constraint(batch_op.f('fk_update_packages_product_id_products'), type_='foreignkey')
        batch_op.drop_column('product_id')

    with op.batch_alter_table('instances', schema=None) as batch_op:
        batch_op.drop_constraint(batch_op.f('fk_instances_product_id_products'), type_='foreignkey')
        batch_op.drop_column('product_id')

    with op.batch_alter_table('enrollment_tokens', schema=None) as batch_op:
        batch_op.drop_constraint(batch_op.f('fk_enrollment_tokens_product_id_products'), type_='foreignkey')
        batch_op.drop_column('product_id')
