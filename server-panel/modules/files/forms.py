from flask_wtf import FlaskForm
from wtforms import StringField
from wtforms.validators import DataRequired, Length


class MkdirForm(FlaskForm):
    name = StringField("Folder name", validators=[DataRequired(), Length(max=255)])


class RenameForm(FlaskForm):
    new_name = StringField("New name", validators=[DataRequired(), Length(max=255)])
