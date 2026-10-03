from app import db

# Monday=0 ... Sunday=6, matching Python's date.weekday()
DAY_NAMES = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]


class WorkingHours(db.Model):
    """One row per user per weekday. `enabled=False` means a day off.

    Multiple working-hour blocks per day aren't modeled — a single
    start/end range per day matches the plan (e.g. 09:00-17:00), and lunch
    or other gaps are carved out via Break rows instead of a second range.
    """

    __tablename__ = "working_hours"
    __table_args__ = (db.UniqueConstraint("user_id", "day_of_week", name="uq_working_hours_user_day"),)

    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False, index=True)
    day_of_week = db.Column(db.SmallInteger, nullable=False)  # 0=Monday ... 6=Sunday
    enabled = db.Column(db.Boolean, nullable=False, default=False)
    start_time = db.Column(db.Time, nullable=True)
    end_time = db.Column(db.Time, nullable=True)

    breaks = db.relationship(
        "Break",
        backref="working_hours",
        lazy="joined",
        order_by="Break.start_time",
        cascade="all, delete-orphan",
    )

    @property
    def day_name(self):
        return DAY_NAMES[self.day_of_week]

    def __repr__(self):  # pragma: no cover
        return f"<WorkingHours {self.day_name} {'off' if not self.enabled else f'{self.start_time}-{self.end_time}'}>"


class Break(db.Model):
    """A recurring unavailable window within a working day, e.g. lunch."""

    __tablename__ = "breaks"

    id = db.Column(db.Integer, primary_key=True)
    working_hours_id = db.Column(db.Integer, db.ForeignKey("working_hours.id"), nullable=False, index=True)
    label = db.Column(db.String(120), nullable=False, default="Break")
    start_time = db.Column(db.Time, nullable=False)
    end_time = db.Column(db.Time, nullable=False)

    def __repr__(self):  # pragma: no cover
        return f"<Break {self.label} {self.start_time}-{self.end_time}>"
