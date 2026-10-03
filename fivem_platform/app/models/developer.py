from datetime import datetime, timezone
from app.extensions import db


def utcnow():
    return datetime.now(timezone.utc)


class DeveloperProfile(db.Model):
    """One-to-one with User. Created when a user becomes a developer.
    Holds the Developer API Key used for external sites / Tebex / custom
    integrations (separate from any single product's API key)."""

    __tablename__ = "developer_profiles"

    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.Integer, db.ForeignKey("users.id"), unique=True, nullable=False)

    developer_api_key_hash = db.Column(db.String(255), nullable=False)
    developer_api_key_prefix = db.Column(db.String(12), nullable=False)  # shown in UI, e.g. "dev_9f2a"

    # Custom domain (white-label) - e.g. a developer CNAMEs
    # "scripts.theirbrand.com" to this platform via Cloudflare (or any DNS
    # provider) and their generated files use it instead of the platform's
    # own domain. Only used once verified, so a misconfigured domain never
    # silently ships broken files to a developer's customers.
    custom_domain = db.Column(db.String(255), nullable=True)
    custom_domain_verified = db.Column(db.Boolean, default=False, server_default=db.text("false"), nullable=False)
    custom_domain_checked_at = db.Column(db.DateTime(timezone=True), nullable=True)

    # Email notifications - on by default, since silence isn't a
    # reasonable default when someone's actually paying you.
    email_notifications_enabled = db.Column(db.Boolean, default=True, server_default=db.text("true"), nullable=False)

    created_at = db.Column(db.DateTime(timezone=True), default=utcnow, nullable=False)

    user = db.relationship("User", backref=db.backref("developer_profile", uselist=False))

    def effective_api_base(self, fallback: str) -> str:
        """The domain that should be baked into this developer's generated
        files - their verified custom domain if they have one, otherwise
        the platform's own domain. Never returns an unverified domain,
        since that could ship a broken config to their customers."""
        if self.custom_domain and self.custom_domain_verified:
            return f"https://{self.custom_domain}"
        return fallback


class Product(db.Model):
    __tablename__ = "products"

    id = db.Column(db.Integer, primary_key=True)
    developer_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False, index=True)

    product_id = db.Column(db.String(24), unique=True, nullable=False, index=True)  # e.g. PRD-849201

    name = db.Column(db.String(120), nullable=False)
    version = db.Column(db.String(32), default="1.0.0", nullable=False)
    product_type = db.Column(db.String(64), default="FiveM Resource", nullable=False)
    description = db.Column(db.Text, nullable=True)

    api_key = db.Column(db.String(64), unique=True, nullable=False, index=True)  # sent by loader, not secret
    secret_key_hash = db.Column(db.String(255), nullable=False)  # verified server-side, never shown again

    is_active = db.Column(db.Boolean, default=True, nullable=False)

    # Remote Configuration (spec: "Config loader" / /api/config/load).
    # Raw JSON text, nullable - developers tune values live without a
    # code redeploy. Nullable specifically so this needs no server_default
    # dance; "no config set" is a perfectly valid, common state.
    remote_config = db.Column(db.Text, nullable=True)

    # Developer Marketplace (spec: "Future Features"). Opt-in public
    # listing; purchase_url points at wherever the developer actually
    # sells it (their Tebex store page) since checkout itself happens
    # outside this platform.
    marketplace_listed = db.Column(db.Boolean, default=False, server_default=db.text("false"), nullable=False)
    purchase_url = db.Column(db.String(500), nullable=True)

    created_at = db.Column(db.DateTime(timezone=True), default=utcnow, nullable=False)
    updated_at = db.Column(db.DateTime(timezone=True), default=utcnow, onupdate=utcnow, nullable=False)

    developer = db.relationship("User", backref="products")
    licenses = db.relationship("License", backref="product", cascade="all, delete-orphan")

    @property
    def license_endpoint(self):
        from flask import url_for
        return url_for("api.license_check", product_id=self.product_id, _external=True)


class License(db.Model):
    __tablename__ = "licenses"

    id = db.Column(db.Integer, primary_key=True)
    product_id = db.Column(db.Integer, db.ForeignKey("products.id"), nullable=False, index=True)
    developer_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False, index=True)

    license_key = db.Column(db.String(40), unique=True, nullable=False, index=True)  # customer-facing

    customer_email = db.Column(db.String(255), nullable=True, index=True)
    customer_user_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=True)

    status = db.Column(db.String(20), default="active", nullable=False)  # active | suspended | revoked
    server_binding = db.Column(db.String(255), nullable=True)  # e.g. FiveM server ID/IP, set on first check

    notes = db.Column(db.Text, nullable=True)

    created_at = db.Column(db.DateTime(timezone=True), default=utcnow, nullable=False)
    activated_at = db.Column(db.DateTime(timezone=True), nullable=True)
    last_checked_at = db.Column(db.DateTime(timezone=True), nullable=True)
    expires_at = db.Column(db.DateTime(timezone=True), nullable=True)  # null = perpetual

    customer_user = db.relationship("User", foreign_keys=[customer_user_id])

    @property
    def is_valid(self):
        if self.status != "active":
            return False
        if self.expires_at and self.expires_at < utcnow():
            return False
        return True


class TebexIntegration(db.Model):
    """One per product. Holds the webhook secret used to verify incoming
    Tebex webhook requests (HMAC-SHA256 over the raw request body)."""

    __tablename__ = "tebex_integrations"

    id = db.Column(db.Integer, primary_key=True)
    product_id = db.Column(db.Integer, db.ForeignKey("products.id"), unique=True, nullable=False)
    developer_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False, index=True)

    webhook_secret_encrypted = db.Column(db.Text, nullable=False)
    webhook_secret_prefix = db.Column(db.String(16), nullable=False)  # shown in UI

    is_active = db.Column(db.Boolean, default=True, nullable=False)
    package_id_filter = db.Column(db.String(64), nullable=True)  # optional: only this Tebex package ID triggers

    created_at = db.Column(db.DateTime(timezone=True), default=utcnow, nullable=False)
    last_event_at = db.Column(db.DateTime(timezone=True), nullable=True)
    total_purchases = db.Column(db.Integer, default=0, nullable=False)

    product = db.relationship("Product", backref=db.backref("tebex_integration", uselist=False))

    @property
    def webhook_url(self):
        from flask import url_for
        return url_for("api.tebex_webhook", product_id=self.product.product_id, _external=True)


class ScriptUpload(db.Model):
    """A developer's uploaded script.zip, plus the platform-injected
    protected build generated from it (License validation, API connection,
    update checker per the spec's Automatic API Injector)."""

    __tablename__ = "script_uploads"

    id = db.Column(db.Integer, primary_key=True)
    product_id = db.Column(db.Integer, db.ForeignKey("products.id"), nullable=False, index=True)
    developer_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False, index=True)

    original_filename = db.Column(db.String(255), nullable=False)
    resource_name = db.Column(db.String(120), nullable=True)  # detected from fxmanifest's folder

    status = db.Column(db.String(20), default="processing", nullable=False)  # processing | ready | failed
    error_message = db.Column(db.Text, nullable=True)

    protected_file_path = db.Column(db.String(500), nullable=True)  # on disk, relative to UPLOAD_FOLDER
    file_size_bytes = db.Column(db.Integer, nullable=True)
    checksum_sha256 = db.Column(db.String(64), nullable=True)

    created_at = db.Column(db.DateTime(timezone=True), default=utcnow, nullable=False)

    product = db.relationship("Product", backref="script_uploads")


class Module(db.Model):
    """A named piece of Lua code the developer manages directly through the
    dashboard. CloudLoader fetches and runs these at runtime for licensed
    customers - the code never touches the customer's disk as a file the
    way Phase 4's zip download does. This is the spec's Module Delivery
    System (Test Menu / Garage / Dispatch style modules)."""

    __tablename__ = "modules"

    id = db.Column(db.Integer, primary_key=True)
    product_id = db.Column(db.Integer, db.ForeignKey("products.id"), nullable=False, index=True)
    developer_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False, index=True)

    name = db.Column(db.String(80), nullable=False)  # e.g. "testmenu" - used in the download path
    display_name = db.Column(db.String(120), nullable=False)
    side = db.Column(db.String(10), default="server", nullable=False)  # "server" or "client"

    code = db.Column(db.Text, nullable=False)
    version = db.Column(db.String(32), default="1.0.0", nullable=False)
    channel = db.Column(db.String(20), default="stable", server_default=db.text("'stable'"), nullable=False)  # "stable" or "beta"
    is_active = db.Column(db.Boolean, default=True, nullable=False)

    created_at = db.Column(db.DateTime(timezone=True), default=utcnow, nullable=False)
    updated_at = db.Column(db.DateTime(timezone=True), default=utcnow, onupdate=utcnow, nullable=False)

    product = db.relationship("Product", backref="modules")

    # A name can exist once per channel - e.g. "client" (stable) and
    # "client" (beta) are different modules, so a beta track doesn't
    # require inventing separate names.
    __table_args__ = (db.UniqueConstraint("product_id", "name", "channel", name="uq_module_product_name_channel"),)


class UsageEvent(db.Model):
    """A lightweight event log for analytics - one row per license check,
    module download, or Tebex purchase. Kept deliberately simple (no
    per-event payload) so it stays cheap to query even at volume."""

    __tablename__ = "usage_events"

    id = db.Column(db.Integer, primary_key=True)
    product_id = db.Column(db.Integer, db.ForeignKey("products.id"), nullable=False, index=True)
    license_id = db.Column(db.Integer, db.ForeignKey("licenses.id"), nullable=True, index=True)

    event_type = db.Column(db.String(32), nullable=False, index=True)  # license_check | module_download | tebex_purchase
    module_name = db.Column(db.String(80), nullable=True)  # set for module_download events

    created_at = db.Column(db.DateTime(timezone=True), default=utcnow, nullable=False, index=True)

    product = db.relationship("Product", backref="usage_events")


class TeamMember(db.Model):
    """Grants another user access to a developer's whole workspace -
    products, licenses, modules, everything under that developer_id. The
    owner (the developer whose products these are) is never a row here;
    this only represents *additional* members."""

    __tablename__ = "team_members"

    id = db.Column(db.Integer, primary_key=True)
    developer_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False, index=True)  # the owner
    member_user_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False, index=True)

    role = db.Column(db.String(20), default="editor", nullable=False)  # editor | viewer (viewer not yet enforced separately)

    invited_at = db.Column(db.DateTime(timezone=True), default=utcnow, nullable=False)
    accepted_at = db.Column(db.DateTime(timezone=True), nullable=True)

    owner = db.relationship("User", foreign_keys=[developer_id], backref="team_memberships_owned")
    member = db.relationship("User", foreign_keys=[member_user_id], backref="team_memberships")

    __table_args__ = (db.UniqueConstraint("developer_id", "member_user_id", name="uq_team_developer_member"),)


class WorkspaceActivityLog(db.Model):
    """Who did what in a developer workspace - the accountability gap that
    opened up once team accounts existed (multiple people acting under one
    workspace with no way to tell them apart afterward). Deliberately
    covers key mutating actions, not everything - a log of literally every
    click isn't more useful, just noisier."""

    __tablename__ = "workspace_activity_log"

    id = db.Column(db.Integer, primary_key=True)
    developer_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False, index=True)  # the workspace
    actor_user_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False)  # who actually did it

    action = db.Column(db.String(64), nullable=False)
    detail = db.Column(db.String(255), nullable=True)

    created_at = db.Column(db.DateTime(timezone=True), default=utcnow, nullable=False, index=True)

    actor = db.relationship("User", foreign_keys=[actor_user_id])
