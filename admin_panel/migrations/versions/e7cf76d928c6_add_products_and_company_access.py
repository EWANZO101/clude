"""add products + company_product_access, seed Kiosk System, grandfather
existing companies as already-approved for it

Revision ID: e7cf76d928c6
Revises: 008900b88a30
Create Date: 2026-09-11 21:30:00.000000

Applied directly against the running SQLite file (see
backups/pre_products_*.db for the pre-change snapshot), same as every
migration since f2a6c3e91d47 — see that migration's own docstring for why
this repo's history doesn't go through `flask db upgrade` normally right
now. Chained after 008900b88a30 to match the live database's current
alembic_version stamp.

Data migration, not just schema: from here on, a brand-new company has NO
product access until it's requested and approved (spec: "companies should
not automatically have access to any product"). That would silently lock
out every company that already exists — including the real, actively-used
"opslabsystems" company — the instant this ships, unless this migration
also seeds the one product that exists today (Kiosk System) and marks
every existing company as already-approved for it. New companies created
after this point get no such row and must go through the real request/
approve flow.
"""
from datetime import datetime

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision = 'e7cf76d928c6'
down_revision = '008900b88a30'
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        'products',
        sa.Column('id', sa.Integer(), primary_key=True),
        sa.Column('public_id', sa.String(length=36), nullable=False),
        sa.Column('slug', sa.String(length=64), nullable=False),
        sa.Column('name', sa.String(length=200), nullable=False),
        sa.Column('description', sa.Text(), nullable=True),
        sa.Column('is_active', sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column('created_at', sa.DateTime(), nullable=False),
        sa.UniqueConstraint('public_id', name='uq_products_public_id'),
        sa.UniqueConstraint('slug', name='uq_products_slug'),
    )

    op.create_table(
        'company_product_access',
        sa.Column('id', sa.Integer(), primary_key=True),
        sa.Column('company_id', sa.Integer(), sa.ForeignKey('companies.id'), nullable=False),
        sa.Column('product_id', sa.Integer(), sa.ForeignKey('products.id'), nullable=False),
        sa.Column('status', sa.String(length=16), nullable=False, server_default='pending'),
        sa.Column('requested_by_id', sa.Integer(), sa.ForeignKey('users.id'), nullable=True),
        sa.Column('requested_at', sa.DateTime(), nullable=False),
        sa.Column('note', sa.Text(), nullable=True),
        sa.Column('decided_by_id', sa.Integer(), sa.ForeignKey('users.id'), nullable=True),
        sa.Column('decided_at', sa.DateTime(), nullable=True),
        sa.Column('decision_note', sa.Text(), nullable=True),
        sa.UniqueConstraint('company_id', 'product_id', name='uq_company_product_access'),
    )

    bind = op.get_bind()
    now = datetime.utcnow()

    products_table = sa.table(
        'products', sa.column('id', sa.Integer), sa.column('public_id', sa.String),
        sa.column('slug', sa.String), sa.column('name', sa.String),
        sa.column('description', sa.Text), sa.column('is_active', sa.Boolean),
        sa.column('created_at', sa.DateTime),
    )
    import uuid
    kiosk_public_id = str(uuid.uuid4())
    bind.execute(products_table.insert().values(
        public_id=kiosk_public_id, slug='kiosk', name='Kiosk System',
        description='StockTool kiosk terminals — inventory, tools, welding wire, and the Instance Agent that manages them.',
        is_active=True, created_at=now,
    ))
    kiosk_product_id = bind.execute(
        sa.text("SELECT id FROM products WHERE slug = 'kiosk'")
    ).scalar()

    company_ids = [row[0] for row in bind.execute(sa.text("SELECT id FROM companies")).fetchall()]
    if company_ids:
        access_table = sa.table(
            'company_product_access', sa.column('company_id', sa.Integer), sa.column('product_id', sa.Integer),
            sa.column('status', sa.String), sa.column('requested_at', sa.DateTime),
            sa.column('decided_at', sa.DateTime), sa.column('decision_note', sa.Text),
        )
        bind.execute(access_table.insert(), [
            {
                'company_id': cid, 'product_id': kiosk_product_id, 'status': 'approved',
                'requested_at': now, 'decided_at': now,
                'decision_note': 'Grandfathered in — this company already had Kiosk System access before product-level access control existed.',
            }
            for cid in company_ids
        ])


def downgrade():
    op.drop_table('company_product_access')
    op.drop_table('products')
