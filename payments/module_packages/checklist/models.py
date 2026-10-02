from datetime import datetime
from app.extensions import db
from app.core.database.models import gen_uuid


class ChecklistList(db.Model):
    __tablename__ = "checklist_lists"
    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    user_id = db.Column(db.String(36), db.ForeignKey("users.id"), nullable=False, index=True)
    name = db.Column(db.String(200), nullable=False)
    archived = db.Column(db.Boolean, default=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    updated_at = db.Column(db.DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)

    tasks = db.relationship("ChecklistTask", backref="checklist", lazy="dynamic",
                             cascade="all, delete-orphan", order_by="ChecklistTask.position")

    @property
    def progress(self):
        total = self.tasks.count()
        if total == 0:
            return 0
        done = self.tasks.filter_by(completed=True).count()
        return round(done / total * 100)


class ChecklistTask(db.Model):
    __tablename__ = "checklist_tasks"
    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    list_id = db.Column(db.String(36), db.ForeignKey("checklist_lists.id"), nullable=False, index=True)
    parent_task_id = db.Column(db.String(36), db.ForeignKey("checklist_tasks.id"), nullable=True, index=True)
    title = db.Column(db.String(400), nullable=False)
    notes = db.Column(db.Text)
    category = db.Column(db.String(80))
    priority = db.Column(db.String(10), default="medium")  # low, medium, high
    due_date = db.Column(db.Date, nullable=True)
    estimated_minutes = db.Column(db.Integer, nullable=True)
    completed = db.Column(db.Boolean, default=False)
    position = db.Column(db.Integer, default=0)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    subtasks = db.relationship("ChecklistTask", backref=db.backref("parent", remote_side=[id]),
                                cascade="all, delete-orphan", single_parent=True)
    tags = db.relationship("ChecklistTag", secondary="checklist_task_tags", backref="tasks")


class ChecklistTag(db.Model):
    __tablename__ = "checklist_tags"
    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.String(36), db.ForeignKey("users.id"), nullable=False, index=True)
    name = db.Column(db.String(80), nullable=False)

    __table_args__ = (db.UniqueConstraint("user_id", "name", name="uq_tag_user_name"),)


class ChecklistTaskTag(db.Model):
    __tablename__ = "checklist_task_tags"
    task_id = db.Column(db.String(36), db.ForeignKey("checklist_tasks.id"), primary_key=True)
    tag_id = db.Column(db.Integer, db.ForeignKey("checklist_tags.id"), primary_key=True)
