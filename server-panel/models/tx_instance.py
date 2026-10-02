from datetime import datetime

from database import db


class TxInstance(db.Model):
    """A txAdmin + FXServer install the panel manages from the /tx page.

    `managed` instances were created by the panel (own folder under
    TX_ROOT, own systemd unit, own MySQL db/user). Adopted ones (e.g. the
    original /root/fivem install) were found on disk and registered so they
    can be controlled from the same page; the panel is more careful about
    deleting their files.

    The credential columns are the "saved details" shown in the UI. They
    are stored in plaintext in the panel's sqlite DB (under DATA_DIR, root
    only) — the same trust level as the panel's .env secrets — because the
    whole point is being able to show/copy them later."""

    __tablename__ = "tx_instances"

    id = db.Column(db.Integer, primary_key=True)
    slug = db.Column(db.String(40), unique=True, nullable=False)
    name = db.Column(db.String(80), nullable=False)
    managed = db.Column(db.Boolean, nullable=False, default=True)

    base_dir = db.Column(db.String(255), nullable=False)
    txdata_dir = db.Column(db.String(255), nullable=False)
    server_dir = db.Column(db.String(255), nullable=False)   # folder holding run.sh (artifact)
    artifact_build = db.Column(db.String(16), nullable=True)
    service_unit = db.Column(db.String(128), nullable=False)

    tx_port = db.Column(db.Integer, nullable=False)
    game_port = db.Column(db.Integer, nullable=False)

    tx_username = db.Column(db.String(40), nullable=True)
    tx_password = db.Column(db.String(128), nullable=True)
    db_name = db.Column(db.String(64), nullable=True)
    db_user = db.Column(db.String(32), nullable=True)
    db_password = db.Column(db.String(128), nullable=True)
    cfx_key = db.Column(db.String(128), nullable=True)
    notes = db.Column(db.Text, nullable=True)

    # Last background job (install/reinstall/update/delete) for the UI.
    last_job_id = db.Column(db.String(36), nullable=True)
    state = db.Column(db.String(16), nullable=False, default="ready")  # installing/ready/failed/deleting

    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)

    def to_dict(self, public_ip=None, secrets=True):
        host = public_ip or "127.0.0.1"
        d = {
            "id": self.id, "slug": self.slug, "name": self.name, "managed": self.managed,
            "base_dir": self.base_dir, "txdata_dir": self.txdata_dir, "server_dir": self.server_dir,
            "artifact_build": self.artifact_build, "service_unit": self.service_unit,
            "tx_port": self.tx_port, "game_port": self.game_port,
            "tx_url": f"http://{host}:{self.tx_port}",
            "connect": f"{host}:{self.game_port}",
            "tx_username": self.tx_username, "db_name": self.db_name, "db_user": self.db_user,
            "notes": self.notes, "last_job_id": self.last_job_id, "state": self.state,
            "has_cfx_key": bool(self.cfx_key),
            "created_at": self.created_at.isoformat() if self.created_at else None,
        }
        if secrets:
            d.update({"tx_password": self.tx_password, "db_password": self.db_password, "cfx_key": self.cfx_key})
        return d
