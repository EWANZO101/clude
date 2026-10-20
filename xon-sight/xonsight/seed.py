import os
import secrets

from flask import current_app

from .extensions import db
from .models import CommunityRequest, Evidence, Settings, User


def _ensure_general_request(admin=None):
    """The one always-on, no-account tip line linked from the homepage
    (/report) - distinct from the per-case links officers generate on
    demand. Created once; safe to call on every boot."""
    if CommunityRequest.query.filter_by(is_general=True).first() is not None:
        return

    creator = admin or User.query.filter_by(role="admin").order_by(User.id.asc()).first()
    general = CommunityRequest(
        reference_code=CommunityRequest.generate_reference_code(),
        title="Report a crime, submit a tip, or share evidence",
        description=(
            "See something? Share what you know, a link to footage you already have, "
            "or upload a photo/video directly - no account needed."
        ),
        category="General",
        requires_consent=True,
        status="open",
        is_general=True,
        created_by_id=creator.id if creator else None,
    )
    db.session.add(general)


def run_seed():
    """Safe to call on every boot: creates the default Settings row and the
    general tip line if either is missing, and - only on the very first
    boot after accounts were introduced (zero User rows) - creates the
    initial admin account and attributes every existing Evidence row to
    it. Xon Sight's webhook never carried a portal login, so there's no
    other owner to assign legacy (and future) evidence to."""
    Settings.get()

    is_first_boot = User.query.first() is None
    admin = None

    if is_first_boot:
        password = secrets.token_urlsafe(12)
        admin = User(username="admin", role="admin")
        admin.set_password(password)
        db.session.add(admin)
        db.session.flush()  # assigns admin.id without a full commit yet

        Evidence.query.filter(Evidence.owner_id.is_(None)).update(
            {Evidence.owner_id: admin.id}, synchronize_session=False
        )

    _ensure_general_request(admin)

    db.session.commit()

    if is_first_boot:
        cred_path = os.path.join(current_app.instance_path, "ADMIN_CREDENTIALS.txt")
        with open(cred_path, "w") as f:
            f.write(
                "Xon Sight initial admin account - read this once, note the\n"
                "password somewhere safe, then delete this file.\n\n"
                f"username: admin\npassword: {password}\n"
            )
        current_app.logger.warning(
            "Created initial admin account 'admin' - credentials written to %s. Log in, then delete that file.",
            cred_path,
        )
