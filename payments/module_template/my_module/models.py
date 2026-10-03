from app.extensions import db


class MyModuleItem(db.Model):
    __tablename__ = "my_module_items"
    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.String(36), db.ForeignKey("users.id"), nullable=False, index=True)
    name = db.Column(db.String(200), nullable=False)
