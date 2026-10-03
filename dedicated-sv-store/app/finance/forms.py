from flask_wtf import FlaskForm
from wtforms import StringField, SelectField, DecimalField, IntegerField, BooleanField, TextAreaField
from wtforms.validators import DataRequired, Optional, Length

from app.models.finance import DiscountType

DISCOUNT_TYPE_CHOICES = [(d.value, d.name.title()) for d in DiscountType]


class CouponForm(FlaskForm):
    code = StringField("Code", validators=[DataRequired(), Length(max=50)])
    description = TextAreaField("Description", validators=[Optional()])
    discount_type = SelectField("Type", choices=DISCOUNT_TYPE_CHOICES, validators=[DataRequired()])
    value = DecimalField("Value (% or fixed amount)", validators=[DataRequired()], places=2)
    max_uses = IntegerField("Max uses (blank = unlimited)", validators=[Optional()])
    is_active = BooleanField("Active", default=True)
