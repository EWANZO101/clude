from app.extensions import db


class Settings(db.Model):
    """Single-row table — system-wide settings the admin frontend can read
    and update via the API. Row id is always 1."""
    __tablename__ = "settings"

    id = db.Column(db.Integer, primary_key=True)
    app_name = db.Column(db.String(64), nullable=False, default="StockTool")
    default_low_stock_threshold = db.Column(db.Integer, nullable=False, default=5)
    kiosk_idle_timeout_seconds = db.Column(db.Integer, nullable=False, default=60)
    kiosk_token_expires_minutes = db.Column(db.Integer, nullable=False, default=15)

    # KPI: a tool still checked out longer than this is flagged "overdue"
    # on the dashboard and tools list. Default 24h — a shop-floor tool
    # that hasn't come back within a day is worth someone glancing at.
    max_checkout_hours = db.Column(db.Integer, nullable=False, default=24)

    # "scan" = classic scan-to-remove screen (original behaviour, still the
    # default so existing installs are unaffected). "browse" = the new
    # Builder-Mode-driven category/item dashboard. Either screen links to
    # the other, so this only decides what a terminal lands on first.
    kiosk_home_screen = db.Column(db.String(16), nullable=False, default="scan")

    @staticmethod
    def get():
        row = Settings.query.get(1)
        if not row:
            row = Settings(id=1)
            db.session.add(row)
            db.session.commit()
        return row

    def to_dict(self) -> dict:
        return {
            "app_name": self.app_name,
            "default_low_stock_threshold": self.default_low_stock_threshold,
            "kiosk_idle_timeout_seconds": self.kiosk_idle_timeout_seconds,
            "kiosk_token_expires_minutes": self.kiosk_token_expires_minutes,
            "max_checkout_hours": self.max_checkout_hours,
            "kiosk_home_screen": self.kiosk_home_screen,
        }
