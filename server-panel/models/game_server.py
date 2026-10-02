from datetime import datetime

from database import db


class GameServer(db.Model):
    """A registered FXServer instance the panel monitors/controls.

    Deliberately thin: control (start/stop/restart) is delegated to the
    existing systemctl module via service_unit, and log tailing to the
    existing logs socket — this table only holds what's specific to the
    FiveM/FXServer integration (HTTP endpoint + RCON credentials)."""

    __tablename__ = "game_servers"

    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(80), nullable=False)

    # Optional link to an existing systemd unit (Services module) so the
    # detail page can offer start/stop/restart/logs without reimplementing
    # any of that.
    service_unit = db.Column(db.String(128), nullable=True)

    # FXServer's built-in HTTP endpoint (/players.json, /dynamic.json,
    # /info.json) — usually localhost + the server's game port.
    http_host = db.Column(db.String(255), nullable=False, default="127.0.0.1")
    http_port = db.Column(db.Integer, nullable=False, default=30120)

    # RCON (UDP), same host:port as the game server unless overridden.
    rcon_host = db.Column(db.String(255), nullable=True)
    rcon_port = db.Column(db.Integer, nullable=True)
    rcon_password = db.Column(db.String(255), nullable=True)

    # Free-text note on which ban resource (if any) this server uses, since
    # persistent/synced bans aren't reachable through RCON or the HTTP API.
    ban_resource_note = db.Column(db.String(255), nullable=True)

    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)

    def effective_rcon_host(self):
        return self.rcon_host or self.http_host

    def effective_rcon_port(self):
        return self.rcon_port or self.http_port

    def base_url(self):
        return f"http://{self.http_host}:{self.http_port}"

    def has_rcon(self):
        return bool(self.rcon_password)

    def to_dict(self):
        return {
            "id": self.id,
            "name": self.name,
            "service_unit": self.service_unit,
            "http_host": self.http_host,
            "http_port": self.http_port,
            "rcon_host": self.effective_rcon_host(),
            "rcon_port": self.effective_rcon_port(),
            "has_rcon": self.has_rcon(),
            "ban_resource_note": self.ban_resource_note,
            "created_at": self.created_at.isoformat() if self.created_at else None,
        }
