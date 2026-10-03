import json
import secrets
import uuid
from datetime import datetime

from flask_login import UserMixin
from argon2 import PasswordHasher
from argon2.exceptions import VerifyMismatchError

from app.extensions import db

_ph = PasswordHasher()


def gen_uuid() -> str:
    return str(uuid.uuid4())

# Matches the original StockTool Kiosk's seeded roles (technical reference
# doc Section 4.3/8.1). These four are the permanent system baseline —
# guaranteed to exist with zero migration/seeding required, so every
# install keeps working with no DB changes. Part 6 (Admin Panel) adds a
# real, editable Role table on top for site-specific custom roles, per
# the "fully custom/editable role table is Part 6" note this constant
# carried since Part 1.
ROLES = ["super_admin", "admin", "supervisor", "stock_user"]


def gen_badge_code() -> str:
    return "BADGE" + secrets.token_hex(4).upper()


class LocalUser(UserMixin, db.Model):
    __tablename__ = "local_users"

    id = db.Column(db.Integer, primary_key=True)
    # Stable cross-system identity for the Admin Panel <-> Kiosk App
    # inventory sync (see app/blueprints/sync_api.py and the Instance
    # Agent's agent/inventory_sync.py) — this row's own auto-increment id
    # means nothing outside this one machine's database, so the sync
    # protocol addresses every record by this instead.
    public_id = db.Column(db.String(36), unique=True, nullable=False, default=gen_uuid)
    username = db.Column(db.String(80), unique=True, nullable=False)
    badge_code = db.Column(db.String(32), unique=True, nullable=False, default=gen_badge_code)
    role = db.Column(db.String(32), nullable=False, default="stock_user")
    is_active = db.Column(db.Boolean, nullable=False, default=True)

    updated_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow, onupdate=datetime.utcnow)
    # No deleted_at here — this app never hard-deletes or tombstones a
    # LocalUser (see admin.py: removal is always is_active=False), so sync
    # maps an Admin-Panel-side "removed" local user onto is_active=False
    # here too, never onto a delete concept this side doesn't have.

    # Original StockTool Kiosk logs in on badge/username alone, no password
    # (technical doc Section 5.1, and its own "Security note" flags this as
    # loopback-only-safe). This rewrite keeps that as the default (matches
    # documented UX / hardware-scanner workflow) but makes a password an
    # OPTIONAL additional factor per account — nullable, and only enforced
    # if actually set, so hardening is opt-in rather than a breaking change.
    password_hash = db.Column(db.String(255), nullable=True)

    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    # The *previous* successful login, deliberately not touched until a
    # login fully completes (see auth.py) — the login-time activity review
    # needs to know "what happened between last time and now", so this has
    # to still hold the OLD value while that review is computed, only
    # advancing to now() once the person has actually seen it.
    last_login_at = db.Column(db.DateTime, nullable=True)

    def set_password(self, raw_password: str):
        self.password_hash = _ph.hash(raw_password) if raw_password else None

    def check_password(self, raw_password: str) -> bool:
        if not self.password_hash:
            return True  # no password set on this account — badge/username alone is sufficient
        if not raw_password:
            return False
        try:
            return _ph.verify(self.password_hash, raw_password)
        except VerifyMismatchError:
            return False
        except Exception:
            return False

    def get_id(self):
        return str(self.id)

    def erase_personal_data(self) -> None:
        """POPIA data subject right to deletion/de-identification, for a
        person who's left and asked for their personal information to be
        removed. Scrubs this account's own identifying fields (username,
        badge, password) to an anonymous placeholder so it can no longer
        log in or be recognized as them.

        Deliberately does NOT touch ActivityEvent/IssuanceEvent/
        ToolCheckoutEvent/WireIssuanceEvent rows that name this person —
        those are free-text tool/PPE custody and safety-accountability
        records captured at the time (see ActivityEvent.actor's own
        docstring), which the business has its own legitimate,
        independent basis to keep (POPIA condition 5(2) permits retention
        where another law or a legitimate business purpose requires it,
        e.g. OHS-related custody trails) — an admin who also wants those
        redacted needs to handle it deliberately, not as an automatic
        side effect that could quietly break a safety/audit trail.
        Requires the account to already be deactivated, same as the
        badge/role guards elsewhere in this file, so an erasure can't be
        used to accidentally remove someone's ability to log in today."""
        if self.is_active:
            raise ValueError("deactivate this account before erasing its personal data")
        placeholder = f"erased-{self.id}"
        self.username = placeholder
        self.badge_code = f"ERASED{self.id:08d}"
        self.password_hash = None

    def to_sync_dict(self) -> dict:
        """The shape sent to/received from the Admin Panel's own sync API
        (InstanceLocalUser.to_sync_dict() there) via the Instance Agent —
        see app/blueprints/sync_api.py. `deleted_at` is always null here;
        this app has no delete concept for a LocalUser (see is_active
        above) so it never originates a tombstone, only ever honors one
        coming from the other side by deactivating instead."""
        return {
            "public_id": self.public_id, "name": self.username, "status": "active" if self.is_active else "inactive",
            "username": self.username, "role": self.role, "badge_code": self.badge_code,
            "pin_hash": self.password_hash,
            "updated_at": self.updated_at.isoformat() if self.updated_at else None,
            "deleted_at": None,
        }

    def __repr__(self):
        return f"<LocalUser {self.username} ({self.role})>"


class RolePermission(db.Model):
    """Per-ROLE login kill-switch (technical doc Section 4.3) — lets an
    admin disable an entire role's logins at once (e.g. during a stock
    audit) without touching individual accounts."""
    __tablename__ = "role_permissions"

    role = db.Column(db.String(32), primary_key=True)
    login_enabled = db.Column(db.Boolean, nullable=False, default=True)


# ---------------------------------------------------------------------------
# Part 2: Items/consumables (technical doc Sections 4.1, 4.4, 5.3)
# ---------------------------------------------------------------------------

def gen_item_barcode() -> str:
    import secrets
    return "ITEM" + secrets.token_hex(4).upper()


class Barcode(db.Model):
    """Central scan-lookup table (technical doc Section 4.3): every scan
    resolves here first, kept as its own table rather than a code column
    per entity so lookup is always a single fast indexed query regardless
    of what the code turns out to be — matters once Tools/Projects/Wire
    (Parts 3-5) share this same table."""
    __tablename__ = "barcodes"

    code = db.Column(db.String(32), primary_key=True)
    entity_type = db.Column(db.String(16), nullable=False)  # item | tool | project | wire
    entity_id = db.Column(db.Integer, nullable=False)


class Item(db.Model):
    """A consumable or PPE stock line (technical doc Section 4.1)."""
    __tablename__ = "items"

    id = db.Column(db.Integer, primary_key=True)
    # Stable cross-system identity — see LocalUser.public_id above for why.
    public_id = db.Column(db.String(36), unique=True, nullable=False, default=gen_uuid)
    name = db.Column(db.String(255), nullable=False)
    sku = db.Column(db.String(64), nullable=True, index=True)
    description = db.Column(db.Text, nullable=True)

    quantity = db.Column(db.Integer, nullable=False, default=0)  # never negative
    unit = db.Column(db.String(32), nullable=True)  # e.g. "ea", "pair"

    barcode_code = db.Column(db.String(32), db.ForeignKey("barcodes.code"), unique=True, nullable=False,
                              default=gen_item_barcode)
    # Freeform grouping label — the Items page groups by this. Not
    # restricted to any fixed set on this app's own add/edit/import paths
    # (see items.py); category_display()'s "consumable" fallback below is
    # kept for to_dict()'s existing wire contract, but the raw column can
    # hold anything, including labels assigned from the Admin Panel side.
    category = db.Column(db.String(64), nullable=True)

    normal_interval_days = db.Column(db.Float, nullable=True)  # expected PPE re-issue gap
    unit_cost = db.Column(db.Float, nullable=True)

    last_adjusted_by = db.Column(db.String(255), nullable=True)
    last_used_project = db.Column(db.String(255), nullable=True)

    updated_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow, onupdate=datetime.utcnow)
    # Soft-delete tombstone for the Admin Panel <-> Kiosk App sync (see
    # app/blueprints/sync_api.py) — unlike LocalUser, an Item genuinely can
    # be deleted here (no equivalent "deactivate instead" convention exists
    # for stock lines), so a real tombstone is needed to carry that removal
    # across to the other side rather than a hard delete the sync would
    # never see. Excluded from every normal query in items.py via a
    # deleted_at.is_(None) filter — see that blueprint.
    deleted_at = db.Column(db.DateTime, nullable=True)

    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)

    def category_display(self) -> str:
        return self.category or "consumable"  # coalesced, matches technical doc's to_dict()

    def adjust_stock(self, delta: int, adjusted_by: str = None, project: str = None, local_user_id: int = None) -> int:
        """Applies delta, clamped at 0 (technical doc: 'never negative').
        Records an ActivityEvent always, and an IssuanceEvent specifically
        for a reduction with an adjuster named (matches the doc's exact
        trigger condition for IssuanceEvent).

        `adjusted_by` (a free-text name, usually current_user.username) and
        `local_user_id` (the actually-logged-in account's real id) are
        deliberately two separate params, same distinction as
        ActivityEvent.actor vs .local_user_id — see that column's own
        comment for why they can legitimately differ and why that gap
        matters."""
        new_quantity = self.quantity + delta
        clamped = max(0, new_quantity)
        actual_delta = clamped - self.quantity
        self.quantity = clamped

        if adjusted_by:
            self.last_adjusted_by = adjusted_by
        if project:
            self.last_used_project = project

        db.session.add(ActivityEvent(
            event_type="item_adjust",
            entity_name=self.name,
            actor=adjusted_by or "system",
            local_user_id=local_user_id,
            project=project,
            detail=f"Stock adjusted — {'+' if actual_delta >= 0 else ''}{actual_delta} "
                   f"({'used' if actual_delta < 0 else 'added'})",
        ))

        if actual_delta < 0 and adjusted_by:
            db.session.add(IssuanceEvent(
                item_id=self.id, employee=adjusted_by, quantity=abs(actual_delta), project=project,
            ))

        return actual_delta

    def to_dict(self) -> dict:
        return {
            "id": self.id, "name": self.name, "sku": self.sku, "description": self.description,
            "quantity": self.quantity, "unit": self.unit, "barcode_code": self.barcode_code,
            "category": self.category_display(), "unit_cost": self.unit_cost,
        }

    def to_sync_dict(self) -> dict:
        """The shape sent to/received from the Admin Panel's own sync API
        (InstanceEquipmentItem.to_sync_dict() there, kind='item') via the
        Instance Agent — see app/blueprints/sync_api.py. Fields with no
        Admin Panel counterpart (normal_interval_days, last_adjusted_by/
        last_used_project, the event histories) never travel — those stay
        real inventory-management data owned entirely by this app."""
        return {
            "public_id": self.public_id, "name": self.name, "description": self.description,
            "status": "active", "sku": self.sku, "quantity": self.quantity, "unit": self.unit,
            "category": self.category_display(), "unit_cost": self.unit_cost,
            "tool_status": None, "checked_out_by_name": None, "current_project": None, "purchase_price": None,
            "barcode_code": self.barcode_code,
            "updated_at": self.updated_at.isoformat() if self.updated_at else None,
            "deleted_at": self.deleted_at.isoformat() if self.deleted_at else None,
        }


class IssuanceEvent(db.Model):
    """One consumable/PPE issuance to an employee (technical doc Section
    4.1) — created whenever an Item's stock is reduced with an adjuster
    named. Distinct from ActivityEvent: structured per-item/per-employee
    data for PPE anomaly checks and issuance-history reporting (Part 7)."""
    __tablename__ = "issuance_events"

    id = db.Column(db.Integer, primary_key=True)
    item_id = db.Column(db.Integer, db.ForeignKey("items.id"), nullable=False)
    employee = db.Column(db.String(255), nullable=False)
    quantity = db.Column(db.Integer, nullable=False)  # always positive
    project = db.Column(db.String(255), nullable=True)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)

    item = db.relationship("Item")


class ActivityEvent(db.Model):
    """Real stock/tool/wire activity feed (technical doc Section 4.4) —
    dashboard 'Recent Activity'. Written now (Part 2), rendered on the
    dashboard in Part 7."""
    __tablename__ = "activity_events"

    id = db.Column(db.Integer, primary_key=True)
    event_type = db.Column(db.String(32), nullable=False)  # item_adjust | tool_checkout | ...
    entity_name = db.Column(db.String(255), nullable=False)
    # Free text — whoever the terminal operator typed/selected as "who
    # this was for" (e.g. a tool's "checked out by" field), which is NOT
    # necessarily the account actually logged in when this was recorded.
    # That's exactly the gap local_user_id below closes.
    actor = db.Column(db.String(255), nullable=True)
    project = db.Column(db.String(255), nullable=True)
    detail = db.Column(db.Text, nullable=True)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)

    # The account that was actually logged in and performed this action —
    # a real, unspoofable link (unlike `actor` above), added specifically
    # to power the "review what happened on your account since you last
    # logged in" step in auth.py. Nullable because rows written before
    # this column existed have no way to backfill it.
    local_user_id = db.Column(db.Integer, db.ForeignKey("local_users.id"), nullable=True)
    local_user = db.relationship("LocalUser")


class ActivityFlag(db.Model):
    """A "this wasn't me" report from the login-time activity review (see
    auth.py) — surfaced to admins on the dashboard so a mismatch between
    who was logged in and who a scan was actually recorded for gets looked
    at, rather than silently trusted forever."""
    __tablename__ = "activity_flags"

    id = db.Column(db.Integer, primary_key=True)
    activity_event_id = db.Column(db.Integer, db.ForeignKey("activity_events.id"), nullable=False)
    reported_by_id = db.Column(db.Integer, db.ForeignKey("local_users.id"), nullable=False)
    note = db.Column(db.Text, nullable=True)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    resolved_at = db.Column(db.DateTime, nullable=True)
    resolved_by_id = db.Column(db.Integer, db.ForeignKey("local_users.id"), nullable=True)

    activity_event = db.relationship("ActivityEvent")
    reported_by = db.relationship("LocalUser", foreign_keys=[reported_by_id])
    resolved_by = db.relationship("LocalUser", foreign_keys=[resolved_by_id])


# ---------------------------------------------------------------------------
# Part 3: Tools (technical doc Section 4.1)
# ---------------------------------------------------------------------------

def gen_tool_barcode() -> str:
    import secrets
    return "TOOL" + secrets.token_hex(4).upper()


class Tool(db.Model):
    """A checkoutable asset (drill, grinder, etc.)."""
    __tablename__ = "tools"

    id = db.Column(db.Integer, primary_key=True)
    # Stable cross-system identity — see LocalUser.public_id above for why.
    public_id = db.Column(db.String(36), unique=True, nullable=False, default=gen_uuid)
    name = db.Column(db.String(255), nullable=False)
    description = db.Column(db.Text, nullable=True)

    status = db.Column(db.String(16), nullable=False, default="available")  # available|checked_out|maintenance

    checked_out_by_name = db.Column(db.String(255), nullable=True)  # live only while checked out
    current_project = db.Column(db.String(255), nullable=True)

    barcode_code = db.Column(db.String(32), db.ForeignKey("barcodes.code"), unique=True, nullable=False,
                              default=gen_tool_barcode)
    purchase_price = db.Column(db.Float, nullable=True)
    maintenance_level = db.Column(db.Integer, nullable=True)  # set while status == 'maintenance'
    # Freeform grouping label, same purpose as Item.category above — the
    # Tools page groups by this. Added via run.py's _ensure_sync_columns()
    # poor-man's-migration on an already-provisioned install.
    category = db.Column(db.String(64), nullable=True)

    updated_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow, onupdate=datetime.utcnow)
    deleted_at = db.Column(db.DateTime, nullable=True)  # soft-delete tombstone — see Item.deleted_at above

    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)

    checkout_events = db.relationship(
        "ToolCheckoutEvent", back_populates="tool", cascade="all, delete-orphan",
        order_by="ToolCheckoutEvent.checked_out_at.desc()",
    )
    maintenance_events = db.relationship(
        "ToolMaintenanceEvent", back_populates="tool", cascade="all, delete-orphan",
        order_by="ToolMaintenanceEvent.started_at.desc()",
    )

    def usage_summary(self) -> dict:
        """Computed on demand from event history, never stored (technical
        doc: 'never stored, always derived')."""
        total_checkout_seconds = 0.0
        for e in self.checkout_events:
            if e.duration_seconds is not None:
                total_checkout_seconds += e.duration_seconds
            elif e.checked_in_at is None:
                total_checkout_seconds += (datetime.utcnow() - e.checked_out_at).total_seconds()

        total_maintenance_seconds = 0.0
        total_maintenance_cost = 0.0
        maintenance_count = 0
        for e in self.maintenance_events:
            maintenance_count += 1
            if e.cost:
                total_maintenance_cost += e.cost
            if e.duration_seconds is not None:
                total_maintenance_seconds += e.duration_seconds
            elif e.ended_at is None:
                total_maintenance_seconds += (datetime.utcnow() - e.started_at).total_seconds()

        # Replacement-candidate heuristic (not specified exactly by the
        # original doc's excerpt available here — documented plainly as a
        # heuristic, tunable later): flagged if accumulated maintenance
        # cost has passed half the purchase price, or it's been through
        # maintenance 3+ times.
        replacement_candidate = maintenance_count >= 3
        if self.purchase_price and self.purchase_price > 0:
            if total_maintenance_cost >= (self.purchase_price * 0.5):
                replacement_candidate = True

        return {
            "total_checkout_hours": round(total_checkout_seconds / 3600, 1),
            "total_maintenance_hours": round(total_maintenance_seconds / 3600, 1),
            "total_maintenance_cost": round(total_maintenance_cost, 2),
            "maintenance_count": maintenance_count,
            "replacement_candidate": replacement_candidate,
        }

    def to_sync_dict(self) -> dict:
        """The shape sent to/received from the Admin Panel's own sync API
        (InstanceEquipmentItem.to_sync_dict() there, kind='tool') via the
        Instance Agent — see app/blueprints/sync_api.py. maintenance_level
        and the checkout/maintenance event histories never travel — those
        stay real asset-management data owned entirely by this app."""
        return {
            "public_id": self.public_id, "name": self.name, "description": self.description,
            "status": "active", "sku": None, "quantity": None, "unit": None, "category": self.category,
            "unit_cost": None, "tool_status": self.status, "checked_out_by_name": self.checked_out_by_name,
            "current_project": self.current_project, "purchase_price": self.purchase_price,
            "barcode_code": self.barcode_code,
            "updated_at": self.updated_at.isoformat() if self.updated_at else None,
            "deleted_at": self.deleted_at.isoformat() if self.deleted_at else None,
        }


class ToolCheckoutEvent(db.Model):
    """One checkout -> checkin cycle for a Tool."""
    __tablename__ = "tool_checkout_events"

    id = db.Column(db.Integer, primary_key=True)
    tool_id = db.Column(db.Integer, db.ForeignKey("tools.id"), nullable=False)

    checked_out_by_name = db.Column(db.String(255), nullable=False)
    project = db.Column(db.String(255), nullable=True)

    checked_out_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    checked_in_at = db.Column(db.DateTime, nullable=True)  # NULL = still out
    duration_seconds = db.Column(db.Float, nullable=True)  # filled in on checkin

    tool = db.relationship("Tool", back_populates="checkout_events")


class ToolMaintenanceEvent(db.Model):
    """One trip into maintenance for a Tool."""
    __tablename__ = "tool_maintenance_events"

    id = db.Column(db.Integer, primary_key=True)
    tool_id = db.Column(db.Integer, db.ForeignKey("tools.id"), nullable=False)

    level = db.Column(db.Integer, nullable=False)
    reason = db.Column(db.Text, nullable=True)

    started_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    ended_at = db.Column(db.DateTime, nullable=True)  # NULL = currently in maintenance
    duration_seconds = db.Column(db.Float, nullable=True)
    cost = db.Column(db.Float, nullable=True)

    tool = db.relationship("Tool", back_populates="maintenance_events")


class MaintenanceAlertThreshold(db.Model):
    """Hours a tool can sit at a maintenance level before it's flagged
    overdue. Default = level * 24h if no row exists yet (lazy
    get-or-create, matching the technical doc)."""
    __tablename__ = "maintenance_alert_thresholds"

    level = db.Column(db.Integer, primary_key=True)
    threshold_hours = db.Column(db.Float, nullable=False)

    @staticmethod
    def get_or_default(level: int) -> float:
        row = MaintenanceAlertThreshold.query.get(level)
        if row is not None:
            return row.threshold_hours
        return level * 24.0


# ---------------------------------------------------------------------------
# Part 4: Projects + barcode scan workflow (technical doc Section 4.1 lists
# "project" as a first-class entity type in the shared barcode table
# alongside item/tool/wire; the excerpt available here doesn't spell out
# Project's own field set, so it's kept to what Items/Tools already lean on
# it for — a name jobs get logged against — plus a status so a finished job
# stops showing up as a scan target.)
# ---------------------------------------------------------------------------

def gen_project_barcode() -> str:
    import secrets
    return "PROJ" + secrets.token_hex(4).upper()


class Project(db.Model):
    """A job/project that Item issuance and Tool checkouts get attributed
    to. Items and Tools already carried a free-text project name
    (last_used_project / current_project) since Part 2 — this table gives
    that name a real record, a barcode of its own, and an active/closed
    lifecycle, without changing how Item/Tool store the association
    (still the project's name as text, matching the existing schema
    rather than introducing a breaking foreign-key migration on those two
    tables mid-rewrite)."""
    __tablename__ = "projects"

    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(255), unique=True, nullable=False)
    code = db.Column(db.String(64), nullable=True, index=True)  # external job/PO number, optional
    description = db.Column(db.Text, nullable=True)

    status = db.Column(db.String(16), nullable=False, default="active")  # active | closed

    barcode_code = db.Column(db.String(32), db.ForeignKey("barcodes.code"), unique=True, nullable=False,
                              default=gen_project_barcode)

    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    closed_at = db.Column(db.DateTime, nullable=True)

    def to_dict(self) -> dict:
        return {
            "id": self.id, "name": self.name, "code": self.code, "description": self.description,
            "status": self.status, "barcode_code": self.barcode_code,
        }


# ---------------------------------------------------------------------------
# Part 5: Welding wire (technical doc Section 4.1 lists "wire" as a shared
# barcode entity_type alongside item/tool/project, same as Project was in
# Part 4 — the excerpt available here doesn't spell out wire's own field
# set or lifecycle beyond that shared table, so this is built to what a
# welding shop actually needs to track a spool by barcode: received ->
# issued to a welder/project -> emptied (consumed) or returned (partially
# used, back to stock) or scrapped, with each step logged for reporting.)
# ---------------------------------------------------------------------------

def gen_wire_barcode() -> str:
    import secrets
    return "WIRE" + secrets.token_hex(4).upper()


def gen_batch_label() -> str:
    import secrets
    return "BATCH" + secrets.token_hex(3).upper()


class WireBatch(db.Model):
    """One receiving event — a shipment of N identical spools added
    together via bulk-add. Shared spec fields live here so reporting can
    roll up cost/consumption per batch (e.g. 'lot X had 3 defective
    spools scrapped') instead of only per individual spool."""
    __tablename__ = "wire_batches"

    id = db.Column(db.Integer, primary_key=True)
    label = db.Column(db.String(32), unique=True, nullable=False, default=gen_batch_label)
    lot_number = db.Column(db.String(64), nullable=True)  # supplier/manufacturer lot, optional

    wire_type = db.Column(db.String(64), nullable=False)  # e.g. "ER70S-6"
    diameter = db.Column(db.String(16), nullable=True)  # e.g. ".035\""
    weight_lbs = db.Column(db.Float, nullable=True)  # nominal full-spool weight
    unit_cost = db.Column(db.Float, nullable=True)  # cost per spool

    quantity = db.Column(db.Integer, nullable=False)  # spools created in this batch
    received_by = db.Column(db.String(255), nullable=True)
    received_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)

    spools = db.relationship("WireSpool", back_populates="batch")


class WireSpool(db.Model):
    """One physical spool, individually barcoded so its lifecycle can be
    scanned like a Tool. Spec fields (wire_type/diameter/weight/cost) are
    duplicated onto the spool rather than only living on WireBatch so a
    spool added outside of a batch (batch_id NULL) is still fully
    described, and existing spools aren't invalidated if a batch is later
    edited or deleted."""
    __tablename__ = "wire_spools"

    id = db.Column(db.Integer, primary_key=True)
    batch_id = db.Column(db.Integer, db.ForeignKey("wire_batches.id"), nullable=True)

    wire_type = db.Column(db.String(64), nullable=False)
    diameter = db.Column(db.String(16), nullable=True)
    weight_lbs = db.Column(db.Float, nullable=True)
    unit_cost = db.Column(db.Float, nullable=True)

    # Remaining weight on the spool right now -- starts equal to weight_lbs
    # and only ever moves via an issue/return-or-empty cycle (see
    # wire.py's issue_spool/return_spool/empty_spool). Stays NULL for a
    # spool that was never given a weight_lbs to begin with, so an
    # un-weighed spool's issuance events skip finishing-weight prompting
    # entirely rather than asking for a number there's nothing to compare
    # it against.
    current_weight_lbs = db.Column(db.Float, nullable=True)

    # in_stock -> issued -> (empty | in_stock via return) ; scrapped from any non-scrapped state
    status = db.Column(db.String(16), nullable=False, default="in_stock")

    barcode_code = db.Column(db.String(32), db.ForeignKey("barcodes.code"), unique=True, nullable=False,
                              default=gen_wire_barcode)

    issued_to = db.Column(db.String(255), nullable=True)  # live only while issued
    current_project = db.Column(db.String(255), nullable=True)

    received_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    scrap_reason = db.Column(db.Text, nullable=True)

    batch = db.relationship("WireBatch", back_populates="spools")
    # No delete-orphan cascade here (unlike Tool's checkout_events in Part
    # 3, which does cascade): a spool's issuance history feeds the Part 5
    # reporting rollups by design, so deleting a spool must not silently
    # erase what it was used for. delete_spool() in the wire blueprint
    # enforces this by refusing to delete any spool that has issuance
    # history at all — found by actually exercising the reporting page
    # after a delete during testing and watching a real count go missing.
    issuance_events = db.relationship(
        "WireIssuanceEvent", back_populates="spool",
        order_by="WireIssuanceEvent.issued_at.desc()",
    )

    def wire_label(self) -> str:
        return f"{self.wire_type}" + (f" {self.diameter}" if self.diameter else "")

    def to_dict(self) -> dict:
        return {
            "id": self.id, "wire_type": self.wire_type, "diameter": self.diameter,
            "weight_lbs": self.weight_lbs, "current_weight_lbs": self.current_weight_lbs,
            "unit_cost": self.unit_cost,
            "status": self.status, "barcode_code": self.barcode_code,
        }


class WireIssuanceEvent(db.Model):
    """One issue -> resolution cycle for a spool, mirroring
    ToolCheckoutEvent's shape so the reporting page can total consumption
    by welder/project/wire type. outcome is filled in on resolution:
    'emptied' | 'returned' | 'scrapped'."""
    __tablename__ = "wire_issuance_events"

    id = db.Column(db.Integer, primary_key=True)
    spool_id = db.Column(db.Integer, db.ForeignKey("wire_spools.id"), nullable=False)

    issued_to = db.Column(db.String(255), nullable=False)
    project = db.Column(db.String(255), nullable=True)

    issued_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    resolved_at = db.Column(db.DateTime, nullable=True)  # NULL = still issued
    outcome = db.Column(db.String(16), nullable=True)  # emptied | returned | scrapped

    # Weight bookkeeping, all NULL when the spool itself has no
    # current_weight_lbs to start from. starting_weight_lbs is always the
    # spool's current_weight_lbs read server-side at issue time (never
    # client-supplied); finishing_weight_lbs is the one number a human
    # actually keys in (via the "Return" pop-up, or implicitly 0 for
    # "Mark Empty"); consumed_lbs is always computed as
    # starting - finishing, never trusted from the client, same
    # server-side-only principle the welding-wire kiosk tool uses.
    starting_weight_lbs = db.Column(db.Float, nullable=True)
    finishing_weight_lbs = db.Column(db.Float, nullable=True)
    consumed_lbs = db.Column(db.Float, nullable=True)

    spool = db.relationship("WireSpool", back_populates="issuance_events")


# ---------------------------------------------------------------------------
# Part 6: Kiosk-local Admin Panel — roles/permissions, sidebar builder,
# users, audit (technical doc Sections 4.3/8.1 establish the seeded-role
# baseline and the per-role login kill-switch (RolePermission, Part 1) but
# the excerpt available here doesn't spell out a custom-role table or a
# per-role feature/sidebar permission model beyond that — this extends the
# existing baseline rather than replacing it: the four ROLES stay
# permanent and un-migrated, Role below only holds site-added extras, and
# RoleSidebarPermission is a lazy get-or-default table (same pattern as
# MaintenanceAlertThreshold in Part 3) so an unconfigured install behaves
# exactly like a plain login-only kiosk until an admin actually customizes
# something.
# ---------------------------------------------------------------------------

# Each non-admin nav destination the sidebar can show/hide per role. The
# Admin Panel itself is deliberately NOT in this table — its access is a
# hardcoded role check (see app/blueprints/admin.py), not something the
# permission system it manages can be used to hide from itself and lock
# every admin out with no CLI escape hatch.
SIDEBAR_ITEMS = [
    ("items", "Items", "Inventory"),
    ("items_low_stock", "Low Stock", "Inventory"),
    ("tools", "Tools", "Inventory"),
    ("tools_economics", "Tool Economics", "Inventory"),
    ("tools_alerts", "Maintenance Alerts", "Inventory"),
    ("wire", "Spools", "Welding Wire"),
    ("wire_bulk_add", "Bulk Add", "Welding Wire"),
    ("wire_reporting", "Reporting", "Welding Wire"),
    ("projects", "Projects", "Jobs"),
    ("scan", "Scan Barcode", "Jobs"),
    ("stock_audit", "Stock Audit", "Audit"),
    # Track 2 (see /root/.claude/plans/sprightly-meandering-whisper.md) —
    # the new generic type system's own area. One single gate for the
    # whole thing (type manager + item list/add/manage/bulk) rather than
    # a key per custom type — a custom type's own NavEntry (key
    # "type:<slug>") is just a nav shortcut into this same area, not a
    # separate permission.
    ("inventory_manage", "Manage Inventory", "Inventory"),
]
SIDEBAR_ITEM_KEYS = {key for key, _, _ in SIDEBAR_ITEMS}


class Role(db.Model):
    """Site-added custom roles on top of the permanent ROLES baseline.
    LocalUser.role stays a plain string (not a hard FK) so the four
    baseline roles keep working with zero table rows and zero migration —
    this table only ever holds the extras an admin creates here."""
    __tablename__ = "roles"

    name = db.Column(db.String(32), primary_key=True)
    description = db.Column(db.Text, nullable=True)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)

    @staticmethod
    def all_role_names() -> list:
        """Baseline roles plus every custom role, for dropdowns and
        validation — the single source of truth for "is this a real
        role" anywhere in the app."""
        return ROLES + [r.name for r in Role.query.order_by(Role.name).all()]


class RoleSidebarPermission(db.Model):
    """Per-role visibility for one sidebar item. Composite-keyed rows are
    created only when an admin actually changes something away from the
    default (get_or_default below) — an unconfigured install has zero
    rows here and every item is visible to every role, matching the
    kiosk's pre-Part-6 behavior exactly."""
    __tablename__ = "role_sidebar_permissions"

    role = db.Column(db.String(32), primary_key=True)
    item_key = db.Column(db.String(64), primary_key=True)
    visible = db.Column(db.Boolean, nullable=False, default=True)

    @staticmethod
    def get_or_default(role: str, item_key: str) -> bool:
        row = RoleSidebarPermission.query.get((role, item_key))
        if row is not None:
            return row.visible
        return True  # unconfigured = visible, so a fresh install needs no setup


class AuditLogEntry(db.Model):
    """Admin Panel action log — who changed a user/role/permission and
    when. Deliberately separate from ActivityEvent (Part 2), which is the
    inventory activity feed (stock/tool/wire); this is specifically
    administrative changes to the kiosk's own access control, the kind of
    thing an audit actually needs to answer 'who changed this and when'
    for independent of day-to-day stock activity."""
    __tablename__ = "audit_log_entries"

    id = db.Column(db.Integer, primary_key=True)
    actor = db.Column(db.String(255), nullable=False)
    action = db.Column(db.String(64), nullable=False)
    target = db.Column(db.String(255), nullable=True)
    detail = db.Column(db.Text, nullable=True)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)


# ---------------------------------------------------------------------------
# Part 7: Stock audit engine (technical doc Section 4.3's RolePermission
# excerpt mentions disabling a role's logins "during a stock audit" as a
# use case, without spelling out what the audit itself does — this is
# built as the classic shop-floor physical count: walk the shelves,
# record what's actually there against what the system believes, then
# reconcile (apply the correction) or dismiss (acknowledge a miscount,
# leave the system quantity alone) each discrepancy before closing out.
# Scoped to Items only — Tools and Wire already have their own physical-
# unit lifecycle tracking (checkout/checkin, issue/empty/scrap) that
# serves the equivalent "is this actually here" reconciliation role for
# discrete units; a quantity count is specifically an Item concept here.
# ---------------------------------------------------------------------------

class StockAudit(db.Model):
    """One physical-count session. Only one may be open at a time (single
    shop-wide event, not a per-login-session thing like the active
    project) — enforced in the blueprint, not here, so the DB layer
    doesn't need a partial-unique-index workaround SQLite can't express
    cleanly. Never deleted — an audit is itself the historical record, so
    unlike WireBatch/Project there's deliberately no delete route for it,
    sidestepping the cascade-delete-erases-history class of bug found and
    fixed in Part 5 by simply not building a delete path in the first
    place."""
    __tablename__ = "stock_audits"

    id = db.Column(db.Integer, primary_key=True)
    label = db.Column(db.String(64), nullable=True)
    status = db.Column(db.String(16), nullable=False, default="open")  # open | closed

    started_by = db.Column(db.String(255), nullable=False)
    started_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    closed_by = db.Column(db.String(255), nullable=True)
    closed_at = db.Column(db.DateTime, nullable=True)

    lines = db.relationship(
        "StockAuditLine", back_populates="audit", cascade="all, delete-orphan",
        order_by="StockAuditLine.counted_at.desc()",
    )

    def display_label(self) -> str:
        return self.label or f"Audit #{self.id}"


class StockAuditLine(db.Model):
    """One item's count within an audit. A line only exists once that
    item has actually been counted — an audit doesn't pre-create a line
    for every Item in the catalog at start, so 'not yet counted' is just
    'no line exists', not a row full of nulls to filter around.
    Re-counting the same item within the same audit updates this row in
    place (upsert, enforced by the unique constraint below) rather than
    creating a duplicate; expected_qty is fixed at the *first* count, not
    refreshed on a recount, since a recount is staff fixing their own
    miscount, not a new system-state snapshot."""
    __tablename__ = "stock_audit_lines"
    __table_args__ = (db.UniqueConstraint("audit_id", "item_id", name="uq_audit_item"),)

    id = db.Column(db.Integer, primary_key=True)
    audit_id = db.Column(db.Integer, db.ForeignKey("stock_audits.id"), nullable=False)
    item_id = db.Column(db.Integer, db.ForeignKey("items.id"), nullable=False)

    expected_qty = db.Column(db.Integer, nullable=False)
    counted_qty = db.Column(db.Integer, nullable=False)
    counted_by = db.Column(db.String(255), nullable=False)
    counted_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)

    status = db.Column(db.String(16), nullable=False, default="pending")  # pending | reconciled | dismissed
    resolved_by = db.Column(db.String(255), nullable=True)
    resolved_at = db.Column(db.DateTime, nullable=True)

    audit = db.relationship("StockAudit", back_populates="lines")
    item = db.relationship("Item")

    @property
    def discrepancy(self) -> int:
        return self.counted_qty - self.expected_qty


# ---------------------------------------------------------------------------
# Part 8: Generic inventory type system (Track 2 of
# /root/.claude/plans/sprightly-meandering-whisper.md) — new tables only,
# additive. Item/Tool/WireSpool and every route/template built on them are
# left completely untouched here; nothing reads or writes these tables yet.
# Phase A is just the shape existing so later phases (sync protocol v2, the
# type manager / Manage view / bulk operations UI, and finally the actual
# data-migration cutover) have something real to build on, per the plan's
# "old functionality keeps working until the phase that supersedes it is
# verified" discipline.
# ---------------------------------------------------------------------------

def gen_sku() -> str:
    return "SKU" + secrets.token_hex(4).upper()


def gen_serial_number() -> str:
    return "SN" + secrets.token_hex(5).upper()


def gen_inventory_barcode() -> str:
    return "INV" + secrets.token_hex(4).upper()


def unique_sku() -> str:
    """Collision-checked, same while-loop-and-retry convention as the
    existing gen_item_barcode()/gen_tool_barcode() callers use."""
    code = gen_sku()
    while InventoryItem.query.filter_by(sku=code).first() is not None:
        code = gen_sku()
    return code


def unique_serial_number() -> str:
    code = gen_serial_number()
    while InventoryItem.query.filter_by(serial_number=code).first() is not None:
        code = gen_serial_number()
    return code


class ItemType(db.Model):
    """A category of inventory item — 'Tool', 'Welding Wire', or any custom
    type an admin defines (spec: 'Tools/Welding Wire/Consumables/Materials/
    Equipment/Parts/Bulk/Custom'). Three built-in rows (item, tool,
    welding_wire) are seeded once at startup (see run.py's
    _ensure_inventory_type_system_seeded()) so the existing three concepts
    have a matching row from day one; is_builtin blocks deletion the same
    way the Role baseline blocks deleting a permanent role."""
    __tablename__ = "item_types"

    key = db.Column(db.String(64), primary_key=True)
    name = db.Column(db.String(255), nullable=False)
    description = db.Column(db.Text, nullable=True)
    is_builtin = db.Column(db.Boolean, nullable=False, default=False)

    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    updated_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow, onupdate=datetime.utcnow)
    deleted_at = db.Column(db.DateTime, nullable=True)  # tombstone — see Item.deleted_at for why

    fields = db.relationship(
        "ItemTypeField", back_populates="item_type", cascade="all, delete-orphan",
        order_by="ItemTypeField.sort_order",
    )

    def to_sync_dict(self) -> dict:
        """Sync protocol v2 shape (agent/inventory_sync.py, both
        sync_api.py files) — type/field *definitions* sync bidirectionally,
        same last-write-wins-by-updated_at discipline as items/tools."""
        return {
            "key": self.key, "name": self.name, "description": self.description,
            "is_builtin": self.is_builtin,
            "fields": [f.to_sync_dict() for f in self.fields],
            "updated_at": self.updated_at.isoformat() if self.updated_at else None,
            "deleted_at": self.deleted_at.isoformat() if self.deleted_at else None,
        }


class ItemTypeField(db.Model):
    """One custom field definition belonging to an ItemType — the 'custom
    fields per type' mechanism (spec sections 5, 9). Values themselves live
    in InventoryItem.custom_fields (one JSON column per item, not a full
    EAV table — see the plan's own reasoning for why)."""
    __tablename__ = "item_type_fields"
    __table_args__ = (
        db.UniqueConstraint("item_type_key", "key", name="uq_item_type_field_key"),
    )

    id = db.Column(db.Integer, primary_key=True)
    item_type_key = db.Column(db.String(64), db.ForeignKey("item_types.key"), nullable=False)
    key = db.Column(db.String(64), nullable=False)
    label = db.Column(db.String(255), nullable=False)
    # text | number | boolean | date | select | measurement | serial_number | sku | custom_unit
    field_type = db.Column(db.String(32), nullable=False, default="text")
    options_json = db.Column(db.Text, nullable=True)  # choices for field_type == "select"
    required = db.Column(db.Boolean, nullable=False, default=False)
    sort_order = db.Column(db.Integer, nullable=False, default=0)

    item_type = db.relationship("ItemType", back_populates="fields")

    def options(self) -> list:
        try:
            return json.loads(self.options_json) if self.options_json else []
        except ValueError:
            return []

    def to_sync_dict(self) -> dict:
        return {
            "key": self.key, "label": self.label, "field_type": self.field_type,
            "options": self.options(), "required": self.required, "sort_order": self.sort_order,
        }


class InventoryItem(db.Model):
    """Generic replacement for Item/Tool (and, on the Admin Panel side,
    InstanceEquipmentItem) — one row per physical thing, typed by
    item_type_key rather than a fixed schema. Not wired into any route yet
    (Phase C); Item/Tool remain the real, live tables until the Phase D
    cutover. checked_out_by_name/current_project are kept as real columns
    (not custom fields) since Tool/Wire's checkout behavior is common
    enough across types to deserve first-class support alongside
    InventoryItemEvent below, matching ToolCheckoutEvent/WireIssuanceEvent's
    existing role today."""
    __tablename__ = "inventory_items"

    id = db.Column(db.Integer, primary_key=True)
    public_id = db.Column(db.String(36), unique=True, nullable=False, default=gen_uuid)
    item_type_key = db.Column(db.String(64), db.ForeignKey("item_types.key"), nullable=False)

    name = db.Column(db.String(255), nullable=False)
    sku = db.Column(db.String(64), unique=True, nullable=True, index=True)
    serial_number = db.Column(db.String(128), unique=True, nullable=True, index=True)
    status = db.Column(db.String(16), nullable=False, default="active")

    # Measurement system: quantity_value is a plain float in quantity_unit's
    # own terms (see app/measurement.py) — converting units keeps this value
    # meaningful via measurement.convert(), never silently rescaling data.
    quantity_value = db.Column(db.Float, nullable=True)
    quantity_unit = db.Column(db.String(16), nullable=True)  # key into MEASUREMENT_KINDS[...]["units"]

    # One JSON blob per item for every ItemTypeField value keyed by field
    # key — e.g. {"wire_diameter": ".035\"", "lot_number": "L482"}.
    custom_fields = db.Column(db.Text, nullable=True)

    barcode_code = db.Column(db.String(32), db.ForeignKey("barcodes.code"), unique=True, nullable=True)

    checked_out_by_name = db.Column(db.String(255), nullable=True)
    current_project = db.Column(db.String(255), nullable=True)

    deleted_at = db.Column(db.DateTime, nullable=True)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    updated_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow, onupdate=datetime.utcnow)

    item_type = db.relationship("ItemType")
    events = db.relationship(
        "InventoryItemEvent", back_populates="item", cascade="all, delete-orphan",
        order_by="InventoryItemEvent.occurred_at.desc()",
    )

    def custom_fields_dict(self) -> dict:
        try:
            return json.loads(self.custom_fields) if self.custom_fields else {}
        except ValueError:
            return {}

    def to_sync_dict(self) -> dict:
        return {
            "public_id": self.public_id, "item_type_key": self.item_type_key, "name": self.name,
            "sku": self.sku, "serial_number": self.serial_number, "status": self.status,
            "quantity_value": self.quantity_value, "quantity_unit": self.quantity_unit,
            "custom_fields": self.custom_fields_dict(),
            "barcode_code": self.barcode_code,
            "checked_out_by_name": self.checked_out_by_name, "current_project": self.current_project,
            "updated_at": self.updated_at.isoformat() if self.updated_at else None,
            "deleted_at": self.deleted_at.isoformat() if self.deleted_at else None,
        }


class InventoryItemEvent(db.Model):
    """Generalizes WireIssuanceEvent + Tool's checkout/maintenance events
    into one event log any item type can use — event_type distinguishes
    what actually happened (spec: issue | checkin | scrap |
    maintenance_start | maintenance_end | ...)."""
    __tablename__ = "inventory_item_events"

    id = db.Column(db.Integer, primary_key=True)
    item_id = db.Column(db.Integer, db.ForeignKey("inventory_items.id"), nullable=False)

    event_type = db.Column(db.String(32), nullable=False)
    actor = db.Column(db.String(255), nullable=True)
    project = db.Column(db.String(255), nullable=True)

    occurred_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    resolved_at = db.Column(db.DateTime, nullable=True)
    outcome = db.Column(db.String(32), nullable=True)
    detail = db.Column(db.Text, nullable=True)

    item = db.relationship("InventoryItem", back_populates="events")


class NavEntry(db.Model):
    """One sidebar nav entry (kiosk_app/app/templates/base.html), replacing
    that template's hardcoded <details> groups once Phase C wires this up.
    Seeded from today's literal SIDEBAR_ITEMS order at startup (see run.py)
    so upgrading changes nothing visually; creating a custom ItemType then
    auto-inserts one more row here (key='type:<slug>') — the 'sidebar
    builder' feature from the plan. is_builtin blocks deleting one of the
    original seeded entries (their visibility is still controlled entirely
    by RoleSidebarPermission/item_key, unchanged)."""
    __tablename__ = "nav_entries"

    key = db.Column(db.String(80), primary_key=True)
    label = db.Column(db.String(255), nullable=False)
    section = db.Column(db.String(64), nullable=False)
    is_builtin = db.Column(db.Boolean, nullable=False, default=False)
    sort_order = db.Column(db.Integer, nullable=False, default=0)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)

    def to_sync_dict(self) -> dict:
        return {
            "key": self.key, "label": self.label, "section": self.section,
            "is_builtin": self.is_builtin, "sort_order": self.sort_order,
        }
