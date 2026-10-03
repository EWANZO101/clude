from flask import Blueprint, render_template, redirect, url_for, request, flash
from flask_login import login_required, current_user
from flask_wtf import FlaskForm
from wtforms import StringField, TextAreaField
from wtforms.validators import DataRequired, Length, Optional, Email

from app.extensions import db
from app.models.user import AccountType
from app.models.seller import SellerProfile, SellerStatus
from app.utils.helpers import generate_unique_slug, log_audit

seller_bp = Blueprint("seller", __name__, template_folder="../templates/seller")


class SellerApplicationForm(FlaskForm):
    business_name = StringField("Business name", validators=[DataRequired(), Length(max=255)])
    description = TextAreaField("Tell us about your business", validators=[DataRequired()])
    support_email = StringField("Support email", validators=[Optional(), Length(max=255)])
    website_url = StringField("Website", validators=[Optional(), Length(max=255)])


class SellerSettingsForm(FlaskForm):
    business_name = StringField("Business name", validators=[DataRequired(), Length(max=255)])
    description = TextAreaField("Description", validators=[Optional()])
    support_email = StringField("Support email", validators=[Optional(), Email(), Length(max=255)])
    support_phone = StringField("Support phone", validators=[Optional(), Length(max=30)])
    website_url = StringField("Website", validators=[Optional(), Length(max=255)])


@seller_bp.route("/apply", methods=["GET", "POST"])
@login_required
def apply():
    if current_user.seller_profile:
        return redirect(url_for("seller.dashboard"))

    form = SellerApplicationForm()
    if form.validate_on_submit():
        profile = SellerProfile(
            user_id=current_user.id,
            business_name=form.business_name.data,
            slug=generate_unique_slug(SellerProfile, form.business_name.data),
            description=form.description.data,
            support_email=form.support_email.data or current_user.email,
            website_url=form.website_url.data,
            status=SellerStatus.APPLICATION,
        )
        db.session.add(profile)
        current_user.account_type = AccountType.SELLER
        db.session.flush()
        log_audit("seller.application_submitted", "SellerProfile", profile.id)
        db.session.commit()
        flash("Your seller application has been submitted for review.", "success")
        return redirect(url_for("seller.dashboard"))

    return render_template("seller/apply.html", form=form)


@seller_bp.before_request
@login_required
def require_seller():
    return None


@seller_bp.route("/")
def dashboard():
    profile = current_user.seller_profile
    if profile is None:
        return redirect(url_for("seller.apply"))
    if profile.status not in (SellerStatus.APPROVED, SellerStatus.ACTIVE):
        return render_template("seller/pending.html", profile=profile)

    from app.models.server import Server, InventoryStatus
    from app.models.order import Order, OrderStatus, OrderPaymentStatus

    seller_servers = Server.query.filter_by(seller_id=profile.id)
    seller_orders = Order.query.filter_by(seller_id=profile.id)
    revenue = (
        db.session.query(db.func.coalesce(db.func.sum(Order.total), 0))
        .filter(Order.seller_id == profile.id, Order.payment_status == OrderPaymentStatus.PAID)
        .scalar()
    )
    stats = {
        "active_servers": seller_servers.filter_by(is_active=True).count(),
        "available_servers": seller_servers.filter_by(inventory_status=InventoryStatus.AVAILABLE).count(),
        "sold_servers": seller_servers.filter_by(inventory_status=InventoryStatus.SOLD).count(),
        "orders": seller_orders.count(),
        "revenue": revenue or 0,
        "pending_orders": seller_orders.filter(
            Order.status.in_([OrderStatus.PENDING, OrderStatus.AWAITING_PAYMENT])
        ).count(),
    }
    return render_template("seller/dashboard.html", profile=profile, stats=stats)


@seller_bp.route("/settings", methods=["GET", "POST"])
def settings():
    profile = _active_seller_or_redirect()
    if profile is None:
        return redirect(url_for("seller.dashboard"))

    form = SellerSettingsForm(obj=profile)
    if form.validate_on_submit():
        profile.business_name = form.business_name.data
        profile.description = form.description.data
        profile.support_email = form.support_email.data
        profile.support_phone = form.support_phone.data
        profile.website_url = form.website_url.data
        log_audit("seller.settings_updated", "SellerProfile", profile.id)
        db.session.commit()
        flash("Business profile updated.", "success")
        return redirect(url_for("seller.settings"))

    return render_template("seller/settings.html", form=form, profile=profile)


@seller_bp.route("/customers")
def customers():
    from app.models.order import Order
    from app.models.user import User

    profile = _active_seller_or_redirect()
    if profile is None:
        return redirect(url_for("seller.dashboard"))

    rows = (
        db.session.query(
            User, db.func.count(Order.id).label("order_count"), db.func.coalesce(db.func.sum(Order.total), 0).label("total_spent")
        )
        .join(Order, Order.user_id == User.id)
        .filter(Order.seller_id == profile.id)
        .group_by(User.id)
        .order_by(db.func.sum(Order.total).desc())
        .all()
    )
    return render_template("seller/customers.html", rows=rows)


@seller_bp.route("/sales")
def sales():
    from app.models.order import Order

    profile = _active_seller_or_redirect()
    if profile is None:
        return redirect(url_for("seller.dashboard"))

    page = request.args.get("page", 1, type=int)
    query = Order.query.filter_by(seller_id=profile.id).order_by(Order.created_at.desc())
    from app.utils.helpers import paginate_query

    pagination = paginate_query(query, page, 25)
    return render_template("seller/sales.html", pagination=pagination)


@seller_bp.route("/revenue")
def revenue():
    from app.models.order import Order, OrderPaymentStatus
    from app.models.finance import SellerPayout

    profile = _active_seller_or_redirect()
    if profile is None:
        return redirect(url_for("seller.dashboard"))

    paid_orders = Order.query.filter_by(seller_id=profile.id, payment_status=OrderPaymentStatus.PAID)
    gross_revenue = db.session.query(db.func.coalesce(db.func.sum(Order.total), 0)).filter(
        Order.seller_id == profile.id, Order.payment_status == OrderPaymentStatus.PAID
    ).scalar() or 0

    payouts = SellerPayout.query.filter_by(seller_id=profile.id).all()
    totals = {
        "gross_revenue": gross_revenue,
        "paid_order_count": paid_orders.count(),
        "commission": sum((p.commission_amount for p in payouts), 0),
        "net": sum((p.net_amount for p in payouts), 0),
        "pending_payout": sum((p.net_amount for p in payouts if p.status != "paid"), 0),
    }

    monthly = (
        db.session.query(
            db.func.date_trunc("month", Order.created_at).label("month"),
            db.func.coalesce(db.func.sum(Order.total), 0).label("total"),
        )
        .filter(Order.seller_id == profile.id, Order.payment_status == OrderPaymentStatus.PAID)
        .group_by("month")
        .order_by(db.desc("month"))
        .limit(12)
        .all()
    )
    return render_template("seller/revenue.html", totals=totals, monthly=monthly)


@seller_bp.route("/messages")
def messages():
    from app.models.chat import Conversation, ConversationContext
    from app.models.order import Order

    profile = _active_seller_or_redirect()
    if profile is None:
        return redirect(url_for("seller.dashboard"))

    conversations = (
        Conversation.query.join(Order, db.and_(Conversation.context_type == ConversationContext.ORDER, Conversation.context_id == Order.id))
        .filter(Order.seller_id == profile.id)
        .order_by(Conversation.updated_at.desc())
        .all()
    )
    return render_template("seller/messages.html", conversations=conversations)


@seller_bp.route("/messages/<int:conversation_id>", methods=["GET", "POST"])
def conversation_detail(conversation_id):
    from app.models.chat import Conversation, ConversationContext, Message
    from app.models.order import Order
    from app.chat.forms import CustomerMessageForm

    profile = _active_seller_or_redirect()
    if profile is None:
        return redirect(url_for("seller.dashboard"))

    conversation = (
        Conversation.query.join(Order, db.and_(Conversation.context_type == ConversationContext.ORDER, Conversation.context_id == Order.id))
        .filter(Conversation.id == conversation_id, Order.seller_id == profile.id)
        .first()
    )
    if conversation is None:
        from flask import abort

        abort(404)

    # Sellers get the same restricted view as customers: staff-only internal
    # notes on this conversation must never be visible to them, and they
    # can't create one themselves (no is_internal_note field on this form).
    form = CustomerMessageForm()
    if form.validate_on_submit():
        db.session.add(Message(conversation_id=conversation.id, sender_id=current_user.id, body=form.body.data))
        db.session.commit()
        return redirect(url_for("seller.conversation_detail", conversation_id=conversation.id))

    return render_template(
        "seller/conversation_detail.html", conversation=conversation, form=form,
        visible_messages=conversation.visible_messages(False),
    )


@seller_bp.route("/payouts")
def payouts():
    from app.models.finance import SellerPayout

    profile = _active_seller_or_redirect()
    if profile is None:
        return redirect(url_for("seller.dashboard"))
    payout_list = (
        SellerPayout.query.filter_by(seller_id=profile.id).order_by(SellerPayout.created_at.desc()).all()
    )
    totals = {
        "gross": sum((p.gross_amount for p in payout_list), 0),
        "commission": sum((p.commission_amount for p in payout_list), 0),
        "net": sum((p.net_amount for p in payout_list), 0),
    }
    return render_template("seller/payouts.html", payouts=payout_list, totals=totals)


from app.seller.server_views import register_seller_server_views, _active_seller_or_redirect  # noqa: E402
from app.seller.order_views import register_seller_order_views  # noqa: E402
from app.seller.api_views import register_seller_api_views  # noqa: E402

register_seller_server_views(seller_bp)
register_seller_order_views(seller_bp)
register_seller_api_views(seller_bp)
