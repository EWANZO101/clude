from database import db

# Built-in role names, ordered highest -> lowest privilege
ROLE_OWNER = "Owner"
ROLE_ADMINISTRATOR = "Administrator"
ROLE_MANAGER = "Manager"
ROLE_USER = "User"
ROLE_VIEWER = "Viewer"

ALL_ROLES = [ROLE_OWNER, ROLE_ADMINISTRATOR, ROLE_MANAGER, ROLE_USER, ROLE_VIEWER]

# Default permission sets per role. Owner implicitly has every permission.
DEFAULT_ROLE_PERMISSIONS = {
    ROLE_OWNER: ["*"],
    ROLE_ADMINISTRATOR: [
        "system.restart", "system.shutdown", "nginx.manage", "firewall.manage",
        "users.manage", "installers.run", "services.manage", "networking.manage",
        "logs.view", "security.manage", "security.view", "dns.manage", "dns.view",
        "vms.manage", "vms.view", "envfiles.manage", "ssl.view", "ssl.manage",
        "backups.manage", "files.manage", "system.admin", "vps.console", "gameservers.manage",
        "databases.manage", "txadmin.manage",
    ],
    ROLE_MANAGER: [
        "nginx.manage", "services.manage", "installers.run", "logs.view", "security.view", "dns.view",
        "vms.view", "envfiles.manage", "ssl.view", "backups.manage", "files.manage", "gameservers.manage",
        "txadmin.manage",
    ],
    ROLE_USER: ["logs.view"],
    ROLE_VIEWER: ["logs.view"],
}


class Role(db.Model):
    __tablename__ = "roles"

    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(64), unique=True, nullable=False)
    permissions = db.Column(db.Text, nullable=False, default="")  # comma-separated

    users = db.relationship("User", back_populates="role")

    def permission_list(self):
        if not self.permissions:
            return []
        return [p.strip() for p in self.permissions.split(",") if p.strip()]

    def has_permission(self, permission):
        perms = self.permission_list()
        return "*" in perms or permission in perms

    def __repr__(self):
        return f"<Role {self.name}>"

    @staticmethod
    def seed_defaults():
        """Create the built-in roles if they don't already exist."""
        for role_name in ALL_ROLES:
            existing = Role.query.filter_by(name=role_name).first()
            perms = ",".join(DEFAULT_ROLE_PERMISSIONS[role_name])
            if not existing:
                db.session.add(Role(name=role_name, permissions=perms))
            elif not existing.permissions:
                existing.permissions = perms
        db.session.commit()
        Role._merge_new_default_permissions()

    # Permissions introduced after the initial release of a role's default
    # set. Listed explicitly (rather than diffing all of
    # DEFAULT_ROLE_PERMISSIONS) so this migration can only ever ADD one of
    # these specific, known-new permissions — it will never silently
    # restore some other default permission an admin deliberately removed
    # from a role.
    _NEWLY_INTRODUCED_PERMISSIONS = {
        ROLE_ADMINISTRATOR: [
            "security.manage", "security.view", "dns.manage", "dns.view",
            "vms.manage", "vms.view", "envfiles.manage", "ssl.view", "ssl.manage",
            "backups.manage", "files.manage", "system.admin", "vps.console", "gameservers.manage",
            "databases.manage", "txadmin.manage",
        ],
        ROLE_MANAGER: ["security.view", "dns.view", "vms.view", "envfiles.manage", "ssl.view", "backups.manage", "files.manage", "gameservers.manage", "txadmin.manage"],
    }

    @staticmethod
    def _merge_new_default_permissions():
        """Additive upgrade path for panels whose roles already existed in
        the DB before a new built-in permission (e.g. security.manage) was
        introduced. Owner is untouched since '*' already covers everything."""
        changed = False
        for role_name, new_perms in Role._NEWLY_INTRODUCED_PERMISSIONS.items():
            role = Role.query.filter_by(name=role_name).first()
            if not role or not role.permissions:
                continue
            current = set(role.permission_list())
            if "*" in current:
                continue
            missing = [p for p in new_perms if p not in current]
            if missing:
                role.permissions = ",".join(sorted(current | set(missing)))
                changed = True
        if changed:
            db.session.commit()
