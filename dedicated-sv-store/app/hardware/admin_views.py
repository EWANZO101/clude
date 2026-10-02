from flask import render_template, redirect, url_for, request, flash, abort

from app.extensions import db
from app.models.hardware import HardwareBrand, Availability, StorageType, TransceiverType
from app.hardware.registry import HARDWARE_REGISTRY
from app.hardware.forms import HardwareBrandForm
from app.utils.permissions import permission_required
from app.utils.helpers import log_audit, paginate_query


def _coerce_enum_fields(instance):
    """WTForms populates enum-backed SelectFields with plain strings; convert
    them back to the proper Python Enum member the SQLAlchemy column expects."""
    if hasattr(instance, "availability") and instance.availability is not None:
        instance.availability = Availability(instance.availability)
    if hasattr(instance, "storage_type") and instance.storage_type is not None:
        instance.storage_type = StorageType(instance.storage_type)
    if hasattr(instance, "transceiver_type") and instance.transceiver_type is not None:
        instance.transceiver_type = TransceiverType(instance.transceiver_type)


def _get_type_or_404(type_slug):
    entry = HARDWARE_REGISTRY.get(type_slug)
    if entry is None:
        abort(404)
    return entry


def _populate_brand_choices(form):
    brands = HardwareBrand.query.filter_by(is_active=True).order_by(HardwareBrand.name).all()
    form.brand_id.choices = [(b.id, b.name) for b in brands]


def register_hardware_admin(admin_bp):
    @admin_bp.route("/hardware")
    @permission_required("hardware.view")
    def hardware_overview():
        counts = {
            slug: entry["model"].query.filter_by(is_active=True).count()
            for slug, entry in HARDWARE_REGISTRY.items()
        }
        return render_template(
            "admin/hardware/overview.html",
            registry=HARDWARE_REGISTRY,
            counts=counts,
            brand_count=HardwareBrand.query.count(),
        )

    @admin_bp.route("/hardware/brands", methods=["GET", "POST"])
    @permission_required("hardware.edit")
    def hardware_brands():
        form = HardwareBrandForm()
        if form.validate_on_submit():
            from app.utils.helpers import generate_unique_slug

            brand = HardwareBrand(
                name=form.name.data,
                slug=generate_unique_slug(HardwareBrand, form.name.data),
                logo_path=form.logo_path.data,
                is_active=form.is_active.data,
            )
            db.session.add(brand)
            db.session.flush()
            log_audit("hardware_brand.created", "HardwareBrand", brand.id, None, {"name": brand.name})
            db.session.commit()
            flash("Brand added.", "success")
            return redirect(url_for("admin.hardware_brands"))

        brands = HardwareBrand.query.order_by(HardwareBrand.name).all()
        return render_template("admin/hardware/brands.html", brands=brands, form=form)

    @admin_bp.route("/hardware/brands/<int:brand_id>/toggle", methods=["POST"])
    @permission_required("hardware.edit")
    def hardware_brand_toggle(brand_id):
        brand = db.session.get(HardwareBrand, brand_id) or abort(404)
        old = brand.is_active
        brand.is_active = not brand.is_active
        log_audit("hardware_brand.toggled", "HardwareBrand", brand.id, {"is_active": old}, {"is_active": brand.is_active})
        db.session.commit()
        flash(f"Brand {'enabled' if brand.is_active else 'disabled'}.", "success")
        return redirect(url_for("admin.hardware_brands"))

    @admin_bp.route("/hardware/<type_slug>")
    @permission_required("hardware.view")
    def hardware_list(type_slug):
        entry = _get_type_or_404(type_slug)
        page = request.args.get("page", 1, type=int)
        q = request.args.get("q", "").strip()
        query = entry["model"].query.order_by(entry["model"].id.desc())
        if q:
            query = query.filter(entry["model"].model_name.ilike(f"%{q}%"))
        pagination = paginate_query(query, page, 25)
        return render_template(
            "admin/hardware/list.html",
            entry=entry,
            type_slug=type_slug,
            pagination=pagination,
            q=q,
        )

    @admin_bp.route("/hardware/<type_slug>/new", methods=["GET", "POST"])
    @permission_required("hardware.edit")
    def hardware_new(type_slug):
        entry = _get_type_or_404(type_slug)
        form = entry["form"]()
        _populate_brand_choices(form)

        if form.validate_on_submit():
            instance = entry["model"]()
            form.populate_obj(instance)
            _coerce_enum_fields(instance)
            db.session.add(instance)
            db.session.flush()
            log_audit(f"{type_slug}.created", entry["model"].__name__, instance.id, None, {"model_name": instance.model_name})
            db.session.commit()
            flash(f"{entry['label'][:-1] if entry['label'].endswith('s') else entry['label']} added.", "success")
            return redirect(url_for("admin.hardware_list", type_slug=type_slug))

        return render_template(
            "admin/hardware/form.html", entry=entry, type_slug=type_slug, form=form, is_new=True
        )

    @admin_bp.route("/hardware/<type_slug>/<int:item_id>", methods=["GET", "POST"])
    @permission_required("hardware.edit")
    def hardware_edit(type_slug, item_id):
        entry = _get_type_or_404(type_slug)
        instance = db.session.get(entry["model"], item_id) or abort(404)
        form = entry["form"](obj=instance)
        _populate_brand_choices(form)

        if form.validate_on_submit():
            old_values = {"model_name": instance.model_name, "price": str(instance.price)}
            form.populate_obj(instance)
            _coerce_enum_fields(instance)
            log_audit(f"{type_slug}.updated", entry["model"].__name__, instance.id, old_values, {"model_name": instance.model_name})
            db.session.commit()
            flash("Changes saved.", "success")
            return redirect(url_for("admin.hardware_list", type_slug=type_slug))

        return render_template(
            "admin/hardware/form.html", entry=entry, type_slug=type_slug, form=form, is_new=False, instance=instance
        )

    @admin_bp.route("/hardware/<type_slug>/<int:item_id>/toggle", methods=["POST"])
    @permission_required("hardware.edit")
    def hardware_toggle(type_slug, item_id):
        entry = _get_type_or_404(type_slug)
        instance = db.session.get(entry["model"], item_id) or abort(404)
        old = instance.is_active
        instance.is_active = not instance.is_active
        log_audit(f"{type_slug}.toggled", entry["model"].__name__, instance.id, {"is_active": old}, {"is_active": instance.is_active})
        db.session.commit()
        flash(f"{'Enabled' if instance.is_active else 'Disabled'}.", "success")
        return redirect(url_for("admin.hardware_list", type_slug=type_slug))

    @admin_bp.route("/hardware/<type_slug>/<int:item_id>/merge", methods=["POST"])
    @permission_required("hardware.edit")
    def hardware_merge(type_slug, item_id):
        entry = _get_type_or_404(type_slug)
        source = db.session.get(entry["model"], item_id) or abort(404)
        target_id = request.form.get("target_id", type=int)
        target = db.session.get(entry["model"], target_id) if target_id else None
        if not target or target.id == source.id:
            flash("Choose a different record to merge into.", "error")
            return redirect(url_for("admin.hardware_list", type_slug=type_slug))

        source.is_active = False
        source.merged_into_id = target.id
        log_audit(f"{type_slug}.merged", entry["model"].__name__, source.id, None, {"merged_into_id": target.id})
        db.session.commit()
        flash(f"Merged into {target.model_name}.", "success")
        return redirect(url_for("admin.hardware_list", type_slug=type_slug))
