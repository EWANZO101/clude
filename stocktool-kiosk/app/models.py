"""
Local embedded database models for StockTool Kiosk v2.

Every syncable table carries three bookkeeping columns used by the sync
engine (Part 3) — none of this is wired up to the cloud yet in Part 1,
but the schema is designed so Part 3 doesn't need a migration to add it
later:

  - server_id     nullable int  — the row's ID on the cloud API, once synced
  - updated_at    datetime      — last local modification time
  - dirty         bool          — True if this row has local changes that
                                   haven't been pushed to the cloud yet
"""
from datetime import datetime, timezone
from flask_sqlalchemy import SQLAlchemy

db = SQLAlchemy()


def _now():
    return datetime.now(timezone.utc)


class SyncMixin:
    server_id = db.Column(db.Integer, nullable=True, index=True)
    updated_at = db.Column(db.DateTime, default=_now, onupdate=_now, nullable=False)
    dirty = db.Column(db.Boolean, default=True, nullable=False)  # True until first sync


class Item(db.Model, SyncMixin):
    __tablename__ = "items"

    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(200), nullable=False)
    sku = db.Column(db.String(100), nullable=True, index=True)
    description = db.Column(db.Text, nullable=True)
    quantity = db.Column(db.Integer, nullable=False, default=0)
    unit = db.Column(db.String(32), nullable=True)
    barcode_code = db.Column(db.String(32), nullable=True, unique=True, index=True)
    last_adjusted_by = db.Column(db.String(64), nullable=True)  # username, set when a scan-workflow adjustment names who did it
    last_used_project = db.Column(db.String(200), nullable=True)  # most recent project this item's stock was used for

    # ── Category + PPE anomaly config (spec items 3-4) ─────────────
    CATEGORY_CONSUMABLE = "consumable"
    CATEGORY_PPE = "ppe"
    # nullable=True on purpose: app/__init__.py's startup auto-migrate
    # only ever adds NULLABLE columns to an existing table (it skips
    # NOT NULL ones rather than guess a backfill value -- see its
    # docstring), so a NOT NULL column here would silently never get
    # added to any already-installed kiosk's DB, and every query
    # against items would start failing with "no such column:
    # items.category". default= still applies at INSERT time for any
    # newly created row either way; to_dict() below coalesces existing
    # legacy NULL rows to CATEGORY_CONSUMABLE for display.
    category = db.Column(db.String(32), nullable=True, default=CATEGORY_CONSUMABLE)
    normal_interval_days = db.Column(db.Float, nullable=True)  # expected re-issue gap per employee, if known

    # ── Sage Active / Pastel accounting integration ────────────────
    # nullable so the startup auto-migrate (see app/__init__.py) can add
    # it to an already-installed kiosk's DB without a manual migration.
    unit_cost = db.Column(db.Float, nullable=True)  # cost price used when posting issuance/usage accounting entries

    def adjust_stock(self, delta: int, adjusted_by: str | None = None, project: str | None = None):
        self.quantity = max(0, self.quantity + delta)
        self.dirty = True
        self.updated_at = _now()
        if adjusted_by:
            self.last_adjusted_by = adjusted_by
        if project:
            self.last_used_project = project

    def to_dict(self):
        return {
            "id": self.id, "name": self.name, "sku": self.sku,
            "description": self.description, "quantity": self.quantity,
            "unit": self.unit, "barcode_code": self.barcode_code,
            "last_adjusted_by": self.last_adjusted_by,
            "last_used_project": self.last_used_project,
            "category": self.category or Item.CATEGORY_CONSUMABLE,
            "normal_interval_days": self.normal_interval_days,
            "unit_cost": self.unit_cost,
            "updated_at": self.updated_at.isoformat() if self.updated_at else None,
        }


class Tool(db.Model, SyncMixin):
    __tablename__ = "tools"

    STATUS_AVAILABLE = "available"
    STATUS_CHECKED_OUT = "checked_out"
    STATUS_MAINTENANCE = "maintenance"

    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(200), nullable=False)
    description = db.Column(db.Text, nullable=True)
    status = db.Column(db.String(32), nullable=False, default=STATUS_AVAILABLE)
    checked_out_by_name = db.Column(db.String(120), nullable=True)
    current_project = db.Column(db.String(200), nullable=True)  # live while checked out; cleared on checkin
    barcode_code = db.Column(db.String(32), nullable=True, unique=True, index=True)

    # ── Economics (Part: Tools/Assets) ─────────────────────────────
    purchase_price = db.Column(db.Float, nullable=True)
    maintenance_level = db.Column(db.Integer, nullable=True)  # set while status == maintenance; None otherwise

    def to_dict(self):
        return {
            "id": self.id, "name": self.name, "description": self.description,
            "status": self.status, "checked_out_by_name": self.checked_out_by_name,
            "current_project": self.current_project,
            "barcode_code": self.barcode_code,
            "purchase_price": self.purchase_price,
            "maintenance_level": self.maintenance_level,
            "updated_at": self.updated_at.isoformat() if self.updated_at else None,
        }

    # ── Economics rollups, computed from ToolCheckoutEvent / ToolMaintenanceEvent ──
    def usage_summary(self):
        checkouts = ToolCheckoutEvent.query.filter_by(tool_id=self.id).all()
        maint = ToolMaintenanceEvent.query.filter_by(tool_id=self.id).all()

        total_checkout_count = len(checkouts)
        total_usage_seconds = sum(
            (c.duration_seconds if c.duration_seconds is not None else
             max(0, (_now() - c.checked_out_at.replace(tzinfo=timezone.utc)).total_seconds()))
            for c in checkouts
        )
        total_usage_hours = round(total_usage_seconds / 3600.0, 2)

        maintenance_count = len(maint)
        total_maintenance_seconds = sum(
            (m.duration_seconds if m.duration_seconds is not None else
             max(0, (_now() - m.started_at.replace(tzinfo=timezone.utc)).total_seconds()))
            for m in maint
        )
        total_maintenance_hours = round(total_maintenance_seconds / 3600.0, 2)
        total_maintenance_cost = round(sum(m.cost or 0 for m in maint), 2)

        # Replacement-candidate heuristic: lots of maintenance cost/time
        # relative to how little productive (checked-out) use it's seeing.
        # Either signal alone can trigger it; reasons are returned so the
        # UI can explain *why*, not just flash a flag.
        reasons = []
        if self.purchase_price and total_maintenance_cost >= 0.5 * self.purchase_price:
            reasons.append(
                f"Maintenance cost (£{total_maintenance_cost:.2f}) is at least half the "
                f"purchase price (£{self.purchase_price:.2f})."
            )
        if maintenance_count >= 3 and total_usage_hours < total_maintenance_hours:
            reasons.append(
                f"Spent more hours in maintenance ({total_maintenance_hours}h) than in use "
                f"({total_usage_hours}h) across {maintenance_count} maintenance events."
            )
        if maintenance_count >= 5:
            reasons.append(f"Has been sent to maintenance {maintenance_count} times.")

        return {
            "tool_id": self.id,
            "purchase_price": self.purchase_price,
            "total_checkout_count": total_checkout_count,
            "total_usage_hours": total_usage_hours,
            "maintenance_count": maintenance_count,
            "total_maintenance_hours": total_maintenance_hours,
            "total_maintenance_cost": total_maintenance_cost,
            "is_replacement_candidate": bool(reasons),
            "replacement_reasons": reasons,
        }


class ToolCheckoutEvent(db.Model):
    """One checkout/checkin cycle for a Tool -- created on checkout,
    closed (checked_in_at + duration_seconds filled in) on checkin.
    An open row (checked_in_at is None) means the tool is still out.
    This is what total usage hours / checkout count / duration-per-use
    are computed from; Tool.checked_out_by_name only ever reflects the
    CURRENT checkout, not history."""
    __tablename__ = "tool_checkout_events"

    id = db.Column(db.Integer, primary_key=True)
    tool_id = db.Column(db.Integer, db.ForeignKey("tools.id"), nullable=False, index=True)
    checked_out_by_name = db.Column(db.String(120), nullable=False)
    project = db.Column(db.String(200), nullable=True)
    checked_out_at = db.Column(db.DateTime, default=_now, nullable=False)
    checked_in_at = db.Column(db.DateTime, nullable=True)
    duration_seconds = db.Column(db.Float, nullable=True)  # filled in on checkin

    def to_dict(self):
        return {
            "id": self.id, "tool_id": self.tool_id,
            "checked_out_by_name": self.checked_out_by_name, "project": self.project,
            "checked_out_at": self.checked_out_at.isoformat() if self.checked_out_at else None,
            "checked_in_at": self.checked_in_at.isoformat() if self.checked_in_at else None,
            "duration_seconds": self.duration_seconds,
            "duration_hours": round(self.duration_seconds / 3600.0, 2) if self.duration_seconds is not None else None,
        }


class ToolMaintenanceEvent(db.Model):
    """One trip into maintenance for a Tool -- created when a tool's
    status is set to 'maintenance' (level required), closed (ended_at +
    duration_seconds + cost) when it's set back to 'available'. An open
    row (ended_at is None) means the tool is currently in maintenance --
    that's also what the maintenance-alert feature checks against."""
    __tablename__ = "tool_maintenance_events"

    id = db.Column(db.Integer, primary_key=True)
    tool_id = db.Column(db.Integer, db.ForeignKey("tools.id"), nullable=False, index=True)
    level = db.Column(db.Integer, nullable=False, default=1)
    reason = db.Column(db.String(255), nullable=True)
    started_at = db.Column(db.DateTime, default=_now, nullable=False)
    ended_at = db.Column(db.DateTime, nullable=True)
    duration_seconds = db.Column(db.Float, nullable=True)  # filled in when closed
    cost = db.Column(db.Float, nullable=True)  # filled in when closed (or updated after)

    def to_dict(self):
        return {
            "id": self.id, "tool_id": self.tool_id, "level": self.level, "reason": self.reason,
            "started_at": self.started_at.isoformat() if self.started_at else None,
            "ended_at": self.ended_at.isoformat() if self.ended_at else None,
            "duration_seconds": self.duration_seconds,
            "duration_hours": round(self.duration_seconds / 3600.0, 2) if self.duration_seconds is not None else None,
            "cost": self.cost,
        }


class MaintenanceAlertThreshold(db.Model):
    """How long a tool can sit in a given maintenance level before it's
    flagged as overdue-for-attention. One row per level, created lazily
    the first time it's read/written (same get_or_create pattern as
    RolePermission) -- a level with no row yet falls back to a sane
    default (level * 24h) rather than requiring a migration/seed step."""
    __tablename__ = "maintenance_alert_thresholds"

    level = db.Column(db.Integer, primary_key=True)
    threshold_hours = db.Column(db.Float, nullable=False)

    @staticmethod
    def default_for_level(level: int) -> float:
        return float(level) * 24.0  # Level 1 -> 24h, Level 2 -> 48h, Level 3 -> 72h, ...

    @staticmethod
    def get_threshold_hours(level: int) -> float:
        row = db.session.get(MaintenanceAlertThreshold, level)
        return row.threshold_hours if row else MaintenanceAlertThreshold.default_for_level(level)

    @staticmethod
    def set_threshold_hours(level: int, hours: float) -> "MaintenanceAlertThreshold":
        row = db.session.get(MaintenanceAlertThreshold, level)
        if not row:
            row = MaintenanceAlertThreshold(level=level, threshold_hours=hours)
            db.session.add(row)
        else:
            row.threshold_hours = hours
        return row

    def to_dict(self):
        return {"level": self.level, "threshold_hours": self.threshold_hours}


class IssuanceEvent(db.Model):
    """One consumable/PPE issuance to an employee -- created whenever an
    Item's stock is reduced (adjust_item with a negative delta) and an
    adjusted_by name is given. Distinct from ActivityEvent: ActivityEvent
    is a flat human-readable feed of everything; this is structured,
    per-item, per-employee data built specifically to answer 'who got
    how much of this, and when' (Items/Consumables + PPE transaction
    history, and the anomalous-usage checks built on top of it)."""
    __tablename__ = "issuance_events"

    id = db.Column(db.Integer, primary_key=True)
    item_id = db.Column(db.Integer, db.ForeignKey("items.id"), nullable=False, index=True)
    employee = db.Column(db.String(120), nullable=False, index=True)
    quantity = db.Column(db.Integer, nullable=False)  # always positive -- the amount issued
    project = db.Column(db.String(200), nullable=True)
    created_at = db.Column(db.DateTime, default=_now, nullable=False)

    def to_dict(self):
        return {
            "id": self.id, "item_id": self.item_id, "employee": self.employee,
            "quantity": self.quantity, "project": self.project,
            "created_at": self.created_at.isoformat() if self.created_at else None,
        }


class WireCode(db.Model):
    """Admin-manageable welding-wire type/code catalogue (spec items 7,
    8). Seeded with '1.2 Code Wire' / '1.6 Code Wire' by migrate.py, but
    nothing about the set is hard-coded beyond that seed -- admins add,
    rename, and deactivate rows here via /api/wire/codes, and both the
    kiosk's wire dropdown and the admin 'Add Welding Wire' form read
    from this table. Deactivating (is_active=False) rather than
    deleting keeps existing coils/history pointing at a valid code."""
    __tablename__ = "wire_codes"

    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(100), nullable=False, unique=True)  # e.g. "1.2 Code Wire"
    is_active = db.Column(db.Boolean, default=True, nullable=False)
    created_at = db.Column(db.DateTime, default=_now, nullable=False)

    def to_dict(self):
        return {
            "id": self.id, "name": self.name, "is_active": self.is_active,
            "created_at": self.created_at.isoformat() if self.created_at else None,
        }


class WireCoil(db.Model):
    """One physical welding-wire spool/roll (spec item 6), identified by
    the barcode on its tag. Carries a live status exactly like Tool
    does (see Tool.status / STATUS_* above) so a coil currently checked
    out to someone can't be checked out again by anyone else (spec item
    10) -- current_weight/checked_out_by_name/current_project are only
    ever the CURRENT checkout; full history lives in WireTransaction."""
    __tablename__ = "wire_coils"

    STATUS_AVAILABLE = "available"
    STATUS_CHECKED_OUT = "checked_out"
    STATUS_EMPTY = "empty"        # current_weight reached 0, or admin marked it finished
    STATUS_INACTIVE = "inactive"  # admin pulled it from rotation

    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(200), nullable=True)  # description, e.g. "ER70S-6 Mild Steel"
    barcode_code = db.Column(db.String(32), nullable=True, unique=True, index=True)
    wire_code_id = db.Column(db.Integer, db.ForeignKey("wire_codes.id"), nullable=True, index=True)
    wire_code = db.relationship("WireCode")

    status = db.Column(db.String(20), nullable=False, default=STATUS_AVAILABLE)
    initial_weight = db.Column(db.Float, nullable=False)
    current_weight = db.Column(db.Float, nullable=False)  # updated on checkin

    # Live only while status == checked_out; cleared on checkin (same
    # convention as Tool.checked_out_by_name / current_project).
    checked_out_by_name = db.Column(db.String(120), nullable=True)
    checked_out_by_badge = db.Column(db.String(32), nullable=True)
    current_project = db.Column(db.String(200), nullable=True)

    # Set the moment status becomes STATUS_EMPTY (checkin reaching 0kg,
    # or an admin marking it finished by hand), cleared if it's ever
    # revived (e.g. topped back up -- see routes_wire.py's add_weight
    # handling). Drives both the "Empty / Finished" grouping in the
    # kiosk list and its 30-day auto-delete window -- see
    # wire_cleanup_scheduler.py.
    empty_at = db.Column(db.DateTime, nullable=True)

    created_at = db.Column(db.DateTime, default=_now, nullable=False)
    updated_at = db.Column(db.DateTime, default=_now, onupdate=_now, nullable=False)

    def to_dict(self):
        return {
            "id": self.id, "name": self.name, "barcode_code": self.barcode_code,
            "wire_code_id": self.wire_code_id,
            "wire_code_name": self.wire_code.name if self.wire_code else None,
            "status": self.status,
            "initial_weight": self.initial_weight, "current_weight": self.current_weight,
            "total_used": round(self.initial_weight - self.current_weight, 4),
            "checked_out_by_name": self.checked_out_by_name,
            "checked_out_by_badge": self.checked_out_by_badge,
            "current_project": self.current_project,
            "empty_at": self.empty_at.isoformat() if self.empty_at else None,
            "created_at": self.created_at.isoformat() if self.created_at else None,
            "updated_at": self.updated_at.isoformat() if self.updated_at else None,
        }


class WireTransaction(db.Model):
    """One checkout/checkin cycle for a WireCoil (spec items 2, 3, 5) --
    created (open) on checkout, closed (finishing_weight/consumed/
    checked_in_at filled in) on checkin. An open row (checked_in_at is
    None) means the coil is still out -- mirrors ToolCheckoutEvent's
    convention exactly. starting_weight is always the coil's
    current_weight AT CHECKOUT time, never client-supplied, and
    consumed is always computed server-side at checkin (spec item 4) --
    a caller can only ever supply finishing_weight."""
    __tablename__ = "wire_transactions"

    id = db.Column(db.Integer, primary_key=True)
    coil_id = db.Column(db.Integer, db.ForeignKey("wire_coils.id"), nullable=False, index=True)

    user_name = db.Column(db.String(120), nullable=False)
    user_badge = db.Column(db.String(32), nullable=True)
    project = db.Column(db.String(200), nullable=True, index=True)

    starting_weight = db.Column(db.Float, nullable=False)
    finishing_weight = db.Column(db.Float, nullable=True)  # filled on checkin
    consumed = db.Column(db.Float, nullable=True)          # filled on checkin, start - finish

    checked_out_at = db.Column(db.DateTime, default=_now, nullable=False)
    checked_in_at = db.Column(db.DateTime, nullable=True)
    checked_in_by_name = db.Column(db.String(120), nullable=True)
    checked_in_by_badge = db.Column(db.String(32), nullable=True)

    def to_dict(self):
        return {
            "id": self.id, "coil_id": self.coil_id,
            "coil_reference": self.coil.barcode_code if self.coil else None,
            "coil_name": self.coil.name if self.coil else None,
            "wire_code_name": self.coil.wire_code.name if self.coil and self.coil.wire_code else None,
            "user_name": self.user_name, "user_badge": self.user_badge, "project": self.project,
            "starting_weight": self.starting_weight, "finishing_weight": self.finishing_weight,
            "consumed": self.consumed,
            "checked_out_at": self.checked_out_at.isoformat() if self.checked_out_at else None,
            "checked_in_at": self.checked_in_at.isoformat() if self.checked_in_at else None,
            "checked_in_by_name": self.checked_in_by_name, "checked_in_by_badge": self.checked_in_by_badge,
            "is_open": self.checked_in_at is None,
        }

    coil = db.relationship("WireCoil")


class WireProjectBudget(db.Model):
    """Target/budget welding-wire weight for a project (spec item 7),
    keyed by the same free-text project name used elsewhere in this app
    (Tool.current_project, Item.last_used_project, etc. -- there's no
    separate Project FK convention for this kind of usage anywhere in
    the codebase, so this matches that)."""
    __tablename__ = "wire_project_budgets"

    project = db.Column(db.String(200), primary_key=True)
    target_weight = db.Column(db.Float, nullable=False)

    def to_dict(self):
        return {"project": self.project, "target_weight": self.target_weight}


class Project(db.Model, SyncMixin):
    __tablename__ = "projects"

    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(200), nullable=False)
    description = db.Column(db.Text, nullable=True)
    is_active = db.Column(db.Boolean, default=True, nullable=False)
    barcode_code = db.Column(db.String(32), nullable=True, unique=True, index=True)

    def to_dict(self):
        return {
            "id": self.id, "name": self.name, "description": self.description,
            "is_active": self.is_active, "barcode_code": self.barcode_code,
            "updated_at": self.updated_at.isoformat() if self.updated_at else None,
        }


class Barcode(db.Model):
    """
    Central lookup table: scanning a code means finding the row here first,
    then following entity_type/entity_id to the actual item/tool/project.
    Kept as its own table (rather than a code column on each entity only)
    so barcode registration/lookup is a single fast indexed query
    regardless of what the code turns out to be.
    """
    __tablename__ = "barcodes"

    id = db.Column(db.Integer, primary_key=True)
    code = db.Column(db.String(32), unique=True, nullable=False, index=True)
    entity_type = db.Column(db.String(20), nullable=False)  # item | tool | project
    entity_id = db.Column(db.Integer, nullable=False)
    created_at = db.Column(db.DateTime, default=_now, nullable=False)

    def to_dict(self):
        return {"code": self.code, "entity_type": self.entity_type, "entity_id": self.entity_id}


class LocalUser(db.Model):
    """
    Local user account for kiosk login. Originally designed as a read-
    mostly mirror of cloud-managed users (see app/routes_admin.py's
    module docstring for why that changed) -- can now also be created/
    edited/deactivated directly on this device via /api/admin/users,
    gated to role=admin.

    Login is by badge_code OR username (see app/routes_auth.py) -- no
    password. There's always a real badge_code either way, auto-
    generated if an admin doesn't set one explicitly (see app/codes.py),
    so every user can log in by badge even if nobody assigned one by
    hand, but username also works as a typed alternative.
    """
    __tablename__ = "local_users"

    id = db.Column(db.Integer, primary_key=True)
    server_id = db.Column(db.Integer, nullable=True, index=True)
    username = db.Column(db.String(64), nullable=False, unique=True)
    badge_code = db.Column(db.String(32), nullable=True, unique=True, index=True)
    role = db.Column(db.String(32), nullable=False, default="stock_user")
    is_active = db.Column(db.Boolean, default=True, nullable=False)

    def to_dict(self):
        return {"id": self.id, "username": self.username, "badge_code": self.badge_code,
                "role": self.role, "is_active": self.is_active}


class RolePermission(db.Model):
    """Per-ROLE login switch -- distinct from LocalUser.is_active, which
    is per-PERSON. This lets an admin disable every stock_user login at
    once (e.g. during an audit, or between seasons for a role nobody
    should be using right now) without touching each individual account.
    One row per role, created lazily the first time it's read/written
    (see get_or_create below) rather than requiring a migration/seed
    step -- a role with no row yet is treated as enabled by default,
    matching how logins already worked before this feature existed."""
    __tablename__ = "role_permissions"

    role = db.Column(db.String(32), primary_key=True)
    login_enabled = db.Column(db.Boolean, default=True, nullable=False)

    @staticmethod
    def is_login_enabled(role: str) -> bool:
        row = db.session.get(RolePermission, role)
        return row.login_enabled if row else True  # no row yet -- default to enabled

    @staticmethod
    def set_login_enabled(role: str, enabled: bool) -> "RolePermission":
        row = db.session.get(RolePermission, role)
        if not row:
            row = RolePermission(role=role, login_enabled=enabled)
            db.session.add(row)
        else:
            row.login_enabled = enabled
        return row

    def to_dict(self):
        return {"role": self.role, "login_enabled": self.login_enabled}


class AuditRun(db.Model):
    """One completed stock audit for a given period. period_type is
    'day', 'month', or 'year'; period_key is the calendar identifier
    for that period ('2026-08-05', '2026-08', '2026'). Day audits are
    the finest granularity -- every item's quantity gets its own
    AuditItemRecord. Month/year audits are rollups: their
    AuditItemRecord rows summarize the NET discrepancy across every
    day audit that fell inside that period, rather than re-snapshotting
    quantities directly, so a month/year audit is only ever as
    complete as the day audits underneath it.

    is_backfill marks a day audit that was generated to catch up a
    missed previous day (see audit_scheduler.py) rather than one that
    ran live, during that day's own 07:00-18:00 SAST window."""
    __tablename__ = "audit_runs"

    PERIOD_DAY = "day"
    PERIOD_MONTH = "month"
    PERIOD_YEAR = "year"
    PERIODS = (PERIOD_DAY, PERIOD_MONTH, PERIOD_YEAR)

    id = db.Column(db.Integer, primary_key=True)
    period_type = db.Column(db.String(8), nullable=False)
    period_key = db.Column(db.String(16), nullable=False)
    is_backfill = db.Column(db.Boolean, default=False, nullable=False)
    total_items = db.Column(db.Integer, default=0)
    total_quantity = db.Column(db.Integer, default=0)
    discrepancy_count = db.Column(db.Integer, default=0)  # items whose quantity changed over the period
    net_quantity_change = db.Column(db.Integer, default=0)  # sum of all discrepancies, +/-
    created_at = db.Column(db.DateTime, default=_now, nullable=False)

    records = db.relationship("AuditItemRecord", backref="audit_run", cascade="all, delete-orphan")

    __table_args__ = (db.UniqueConstraint("period_type", "period_key", name="uq_audit_period"),)

    def to_dict(self):
        return {
            "id": self.id, "period_type": self.period_type, "period_key": self.period_key,
            "is_backfill": self.is_backfill, "total_items": self.total_items,
            "total_quantity": self.total_quantity, "discrepancy_count": self.discrepancy_count,
            "net_quantity_change": self.net_quantity_change,
            "created_at": self.created_at.isoformat() if self.created_at else None,
        }


class AuditItemRecord(db.Model):
    """Per-item line within an AuditRun. item_name/sku are snapshotted
    at record time (not just joined via item_id) so a run's history
    stays readable even if the item is later renamed or deleted."""
    __tablename__ = "audit_item_records"

    id = db.Column(db.Integer, primary_key=True)
    audit_run_id = db.Column(db.Integer, db.ForeignKey("audit_runs.id"), nullable=False)
    item_id = db.Column(db.Integer, nullable=True)  # nullable: item may be deleted later
    item_name = db.Column(db.String(200), nullable=False)
    sku = db.Column(db.String(100), nullable=True)
    quantity_at_audit = db.Column(db.Integer, nullable=False)
    previous_quantity = db.Column(db.Integer, nullable=True)  # null if no prior audit to compare against
    discrepancy = db.Column(db.Integer, nullable=True)  # quantity_at_audit - previous_quantity

    def to_dict(self):
        return {
            "id": self.id, "item_id": self.item_id, "item_name": self.item_name, "sku": self.sku,
            "quantity_at_audit": self.quantity_at_audit, "previous_quantity": self.previous_quantity,
            "discrepancy": self.discrepancy,
        }


class ActivityEvent(db.Model):
    """Real stock/tool activity -- item adjustments, tool checkouts and
    checkins. Distinct from SyncLog on purpose: SyncLog is push/pull
    events with the cloud (empty until a SYNC_ENGINE is configured),
    while this is what actually happened on this kiosk regardless of
    whether cloud sync exists at all. The dashboard's "Recent Activity"
    panel reads from here; the separate Sync Log tab still reads from
    SyncLog, since those really are two different things a person might
    want to see."""
    __tablename__ = "activity_events"

    TYPE_ITEM_ADJUST = "item_adjust"
    TYPE_TOOL_CHECKOUT = "tool_checkout"
    TYPE_TOOL_CHECKIN = "tool_checkin"
    TYPE_WIRE_CHECKOUT = "wire_checkout"
    TYPE_WIRE_CHECKIN = "wire_checkin"

    id = db.Column(db.Integer, primary_key=True)
    event_type = db.Column(db.String(32), nullable=False)
    entity_name = db.Column(db.String(200), nullable=False)
    actor = db.Column(db.String(120), nullable=True)
    project = db.Column(db.String(200), nullable=True)  # which project this was scanned/used for, if any
    detail = db.Column(db.String(255), nullable=True)
    created_at = db.Column(db.DateTime, default=_now, nullable=False)

    @staticmethod
    def log(event_type, entity_name, actor=None, project=None, detail=None):
        db.session.add(ActivityEvent(
            event_type=event_type, entity_name=entity_name, actor=actor, project=project, detail=detail,
        ))

    def to_dict(self):
        return {
            "id": self.id, "event_type": self.event_type, "entity_name": self.entity_name,
            "actor": self.actor, "project": self.project, "detail": self.detail,
            "created_at": self.created_at.isoformat() if self.created_at else None,
        }


class SyncLog(db.Model):
    """Foundation for Part 3 — every sync attempt (push or pull) gets a row
    here so the app can show sync status/history and support retry."""
    __tablename__ = "sync_log"

    id = db.Column(db.Integer, primary_key=True)
    direction = db.Column(db.String(10), nullable=False)  # push | pull
    entity_type = db.Column(db.String(20), nullable=True)
    status = db.Column(db.String(20), nullable=False)  # success | error | conflict
    message = db.Column(db.Text, nullable=True)
    created_at = db.Column(db.DateTime, default=_now, nullable=False)

    def to_dict(self):
        return {
            "id": self.id, "direction": self.direction, "entity_type": self.entity_type,
            "status": self.status, "message": self.message,
            "created_at": self.created_at.isoformat() if self.created_at else None,
        }


class PastelMapping(db.Model):
    """Cross-reference between a local row (Item, Project, ...) and its
    counterpart record in Sage Active/Pastel, keyed by (entity_type,
    local_id) so a repeated push updates the existing remote record
    instead of creating a duplicate every sync cycle. Deliberately a
    separate table (not columns bolted onto Item/Project) so this
    integration can be added/removed without touching the shape of the
    core kiosk tables, and so one local row could in principle map to
    records in more than one remote system later.

    content_hash is a cheap fingerprint of the fields last pushed, used
    to skip no-op pushes (e.g. a dirty=True Item whose only change was
    an unrelated column) without needing a field-by-field diff against
    Pastel on every cycle.
    """
    __tablename__ = "pastel_mapping"

    id = db.Column(db.Integer, primary_key=True)
    entity_type = db.Column(db.String(20), nullable=False, index=True)  # "item" | "project"
    local_id = db.Column(db.Integer, nullable=False, index=True)
    pastel_id = db.Column(db.String(64), nullable=False)  # Sage Active object UUID
    pastel_code = db.Column(db.String(64), nullable=True)  # business code (e.g. product code), handy for debugging
    content_hash = db.Column(db.String(64), nullable=True)
    last_pushed_at = db.Column(db.DateTime, nullable=True)
    last_pulled_at = db.Column(db.DateTime, nullable=True)

    __table_args__ = (
        db.UniqueConstraint("entity_type", "local_id", name="uq_pastel_mapping_entity_local"),
    )

    def to_dict(self):
        return {
            "id": self.id, "entity_type": self.entity_type, "local_id": self.local_id,
            "pastel_id": self.pastel_id, "pastel_code": self.pastel_code,
            "last_pushed_at": self.last_pushed_at.isoformat() if self.last_pushed_at else None,
            "last_pulled_at": self.last_pulled_at.isoformat() if self.last_pulled_at else None,
        }


class PastelSyncLog(db.Model):
    """Same shape/purpose as SyncLog above, kept as its own table so the
    existing cloud-sync history (Item/Tool/Project <-> stocktool cloud)
    and this accounting integration's history don't get interleaved and
    harder to read in either admin screen."""
    __tablename__ = "pastel_sync_log"

    id = db.Column(db.Integer, primary_key=True)
    direction = db.Column(db.String(10), nullable=False)  # push | pull
    entity_type = db.Column(db.String(20), nullable=True)  # item | project | accounting_entry
    status = db.Column(db.String(20), nullable=False)  # success | error
    message = db.Column(db.Text, nullable=True)
    created_at = db.Column(db.DateTime, default=_now, nullable=False)

    def to_dict(self):
        return {
            "id": self.id, "direction": self.direction, "entity_type": self.entity_type,
            "status": self.status, "message": self.message,
            "created_at": self.created_at.isoformat() if self.created_at else None,
        }
