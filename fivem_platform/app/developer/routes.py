import os
import re
import json
import csv
import io
from functools import wraps
from datetime import datetime, timezone, timedelta

from flask import render_template, redirect, url_for, flash, request, current_app, send_file, g, Response
from flask_login import login_required, current_user

from app.developer import developer_bp
from app.extensions import db
from app.models.developer import DeveloperProfile, Product, License, TebexIntegration, ScriptUpload, Module, UsageEvent, TeamMember
from app.models.user import User
from app.injector.build import build_protected_package, extract_modules_from_upload, InjectorError
from app.utils import (
    generate_product_id,
    generate_product_api_key,
    generate_product_secret_key,
    generate_license_key,
    generate_developer_api_key,
    generate_webhook_secret,
    encrypt_secret,
    hash_secret,
)


def log_activity(developer_id, action, detail=None):
    """Records a mutating action against a workspace, attributed to
    whoever's actually logged in right now (owner or team member)."""
    from app.models.developer import WorkspaceActivityLog
    entry = WorkspaceActivityLog(
        developer_id=developer_id,
        actor_user_id=current_user.id,
        action=action,
        detail=detail,
    )
    db.session.add(entry)


def get_workspace_developer_id(user):
    """Returns the developer_id whose workspace `user` should see: their
    own, if they're a developer themselves, or the owner's, if they're an
    accepted team member. Returns None if neither."""
    if user.is_developer:
        return user.id
    membership = TeamMember.query.filter_by(member_user_id=user.id).filter(
        TeamMember.accepted_at.isnot(None)
    ).first()
    return membership.developer_id if membership else None


def developer_required(f):
    @wraps(f)
    def wrapper(*args, **kwargs):
        if not current_user.is_authenticated:
            flash("You need a developer account for that.", "error")
            return redirect(url_for("developer.overview"))
        workspace_id = get_workspace_developer_id(current_user)
        if workspace_id is None:
            flash("You need a developer account for that.", "error")
            return redirect(url_for("developer.overview"))
        g.workspace_developer_id = workspace_id
        return f(*args, **kwargs)
    return wrapper


def _unique_product_id():
    while True:
        candidate = generate_product_id()
        if not Product.query.filter_by(product_id=candidate).first():
            return candidate


def _unique_license_key():
    while True:
        candidate = generate_license_key()
        if not License.query.filter_by(license_key=candidate).first():
            return candidate


# ------------------------------------------------------------------ overview
@developer_bp.route("/developer")
@login_required
def overview():
    workspace_id = get_workspace_developer_id(current_user)
    if workspace_id is None:
        return render_template("developer/become_developer.html")
    products = Product.query.filter_by(developer_id=workspace_id).order_by(Product.created_at.desc()).all()
    is_team_member = workspace_id != current_user.id
    return render_template("developer/overview.html", products=products, is_team_member=is_team_member)


@developer_bp.route("/developer/enable", methods=["POST"])
@login_required
def enable():
    if current_user.is_developer:
        return redirect(url_for("developer.overview"))

    raw_key, prefix = generate_developer_api_key()
    profile = DeveloperProfile(
        user_id=current_user.id,
        developer_api_key_hash=hash_secret(raw_key),
        developer_api_key_prefix=prefix,
    )
    current_user.is_developer = True
    db.session.add(profile)
    db.session.commit()

    return render_template("developer/api_key_created.html", api_key=raw_key, regenerate=False)


# ------------------------------------------------------------------ products
@developer_bp.route("/developer/products")
@login_required
@developer_required
def products():
    items = Product.query.filter_by(developer_id=g.workspace_developer_id).order_by(Product.created_at.desc()).all()
    return render_template("developer/products.html", products=items)


@developer_bp.route("/developer/products/new", methods=["GET", "POST"])
@login_required
@developer_required
def new_product():
    if request.method == "POST":
        name = request.form.get("name", "").strip()
        version = request.form.get("version", "1.0.0").strip() or "1.0.0"
        product_type = request.form.get("product_type", "FiveM Resource").strip()
        description = request.form.get("description", "").strip()

        if not name:
            flash("Product name is required.", "error")
            return render_template("developer/new_product.html", name=name, version=version, description=description)

        secret_raw = generate_product_secret_key()

        product = Product(
            developer_id=g.workspace_developer_id,
            product_id=_unique_product_id(),
            name=name,
            version=version,
            product_type=product_type,
            description=description,
            api_key=generate_product_api_key(),
            secret_key_hash=hash_secret(secret_raw),
        )
        db.session.add(product)
        log_activity(g.workspace_developer_id, "product_created", detail=product.name)
        db.session.commit()

        return render_template("developer/product_created.html", product=product, secret_key=secret_raw)

    return render_template("developer/new_product.html")


@developer_bp.route("/developer/products/<product_id>")
@login_required
@developer_required
def product_detail(product_id):
    product = Product.query.filter_by(product_id=product_id, developer_id=g.workspace_developer_id).first_or_404()
    licenses = License.query.filter_by(product_id=product.id).order_by(License.created_at.desc()).all()
    return render_template("developer/product_detail.html", product=product, licenses=licenses)


@developer_bp.route("/developer/products/<product_id>/edit", methods=["GET", "POST"])
@login_required
@developer_required
def edit_product(product_id):
    product = Product.query.filter_by(product_id=product_id, developer_id=g.workspace_developer_id).first_or_404()

    if request.method == "POST":
        name = request.form.get("name", "").strip()
        version = request.form.get("version", "").strip() or product.version
        description = request.form.get("description", "").strip()

        if not name:
            flash("Product name is required.", "error")
            return render_template("developer/edit_product.html", product=product)

        product.name = name
        product.version = version
        product.description = description
        db.session.commit()
        flash("Product updated.", "success")
        return redirect(url_for("developer.product_detail", product_id=product.product_id))

    return render_template("developer/edit_product.html", product=product)


@developer_bp.route("/developer/products/<product_id>/regenerate-secret", methods=["POST"])
@login_required
@developer_required
def regenerate_secret(product_id):
    product = Product.query.filter_by(product_id=product_id, developer_id=g.workspace_developer_id).first_or_404()
    secret_raw = generate_product_secret_key()
    product.secret_key_hash = hash_secret(secret_raw)
    log_activity(g.workspace_developer_id, "secret_regenerated", detail=product.name)
    db.session.commit()
    return render_template("developer/product_created.html", product=product, secret_key=secret_raw, regenerated=True)


@developer_bp.route("/developer/products/<product_id>/toggle-active", methods=["POST"])
@login_required
@developer_required
def toggle_product_active(product_id):
    product = Product.query.filter_by(product_id=product_id, developer_id=g.workspace_developer_id).first_or_404()
    product.is_active = not product.is_active
    db.session.commit()
    flash(f"{product.name} is now {'active' if product.is_active else 'disabled'}.", "info")
    return redirect(url_for("developer.product_detail", product_id=product.product_id))


@developer_bp.route("/developer/products/<product_id>/delete", methods=["GET", "POST"])
@login_required
@developer_required
def delete_product(product_id):
    product = Product.query.filter_by(product_id=product_id, developer_id=g.workspace_developer_id).first_or_404()

    # Blocked if ANY license was ever issued, regardless of status - even
    # a revoked license means a real customer transaction happened once.
    # Disable is the right tool if you want to stop new activity; delete
    # is only for a product that was never actually sold.
    ever_had_licenses = License.query.filter_by(product_id=product.id).count() > 0

    if request.method == "POST":
        if ever_had_licenses:
            flash("This product has licenses on record and can't be deleted. Disable it instead.", "error")
            return redirect(url_for("developer.product_detail", product_id=product.product_id))

        confirm_text = request.form.get("confirm_text", "").strip()
        if confirm_text != product.name:
            flash("Type the product name exactly to confirm.", "error")
            return render_template("developer/delete_product.html", product=product, ever_had_licenses=ever_had_licenses)

        # Clean up files on disk for any script uploads before the DB rows go.
        for upload in ScriptUpload.query.filter_by(product_id=product.id).all():
            if upload.protected_file_path:
                full_path = os.path.join(current_app.config["UPLOAD_FOLDER"], upload.protected_file_path)
                if os.path.exists(full_path):
                    os.remove(full_path)

        Module.query.filter_by(product_id=product.id).delete(synchronize_session=False)
        ScriptUpload.query.filter_by(product_id=product.id).delete(synchronize_session=False)
        TebexIntegration.query.filter_by(product_id=product.id).delete(synchronize_session=False)
        UsageEvent.query.filter_by(product_id=product.id).delete(synchronize_session=False)

        product_name = product.name
        log_activity(g.workspace_developer_id, "product_deleted", detail=product_name)
        db.session.delete(product)
        db.session.commit()

        flash(f'"{product_name}" deleted.', "info")
        return redirect(url_for("developer.products"))

    return render_template("developer/delete_product.html", product=product, ever_had_licenses=ever_had_licenses)


# ------------------------------------------------------------------ licenses
@developer_bp.route("/developer/products/<product_id>/licenses/new", methods=["POST"])
@login_required
@developer_required
def new_license(product_id):
    product = Product.query.filter_by(product_id=product_id, developer_id=g.workspace_developer_id).first_or_404()

    quantity = request.form.get("quantity", "1")
    customer_email = request.form.get("customer_email", "").strip().lower() or None

    try:
        quantity = max(1, min(int(quantity), 500))
    except ValueError:
        quantity = 1

    created = []
    for _ in range(quantity):
        lic = License(
            product_id=product.id,
            developer_id=g.workspace_developer_id,
            license_key=_unique_license_key(),
            customer_email=customer_email,
        )
        db.session.add(lic)
        created.append(lic)
    db.session.commit()

    flash(f"Created {quantity} license(s) for {product.name}.", "success")
    return redirect(url_for("developer.product_detail", product_id=product.product_id))


def _get_owned_license(license_id):
    return License.query.filter_by(id=license_id, developer_id=g.workspace_developer_id).first_or_404()


@developer_bp.route("/developer/licenses/<int:license_id>/revoke", methods=["POST"])
@login_required
@developer_required
def revoke_license(license_id):
    lic = _get_owned_license(license_id)
    lic.status = "revoked"
    log_activity(g.workspace_developer_id, "license_revoked", detail=lic.license_key)
    db.session.commit()
    flash("License revoked.", "info")
    return redirect(url_for("developer.product_detail", product_id=lic.product.product_id))


@developer_bp.route("/developer/licenses/<int:license_id>/suspend", methods=["POST"])
@login_required
@developer_required
def suspend_license(license_id):
    lic = _get_owned_license(license_id)
    lic.status = "suspended"
    db.session.commit()
    flash("License suspended.", "info")
    return redirect(url_for("developer.product_detail", product_id=lic.product.product_id))


@developer_bp.route("/developer/licenses/<int:license_id>/reactivate", methods=["POST"])
@login_required
@developer_required
def reactivate_license(license_id):
    lic = _get_owned_license(license_id)
    lic.status = "active"
    db.session.commit()
    flash("License reactivated.", "success")
    return redirect(url_for("developer.product_detail", product_id=lic.product.product_id))


# ---------------------------------------------------------------- tebex
@developer_bp.route("/developer/products/<product_id>/tebex")
@login_required
@developer_required
def tebex_settings(product_id):
    product = Product.query.filter_by(product_id=product_id, developer_id=g.workspace_developer_id).first_or_404()
    return render_template("developer/tebex.html", product=product, integration=product.tebex_integration)


@developer_bp.route("/developer/products/<product_id>/tebex/enable", methods=["POST"])
@login_required
@developer_required
def tebex_enable(product_id):
    product = Product.query.filter_by(product_id=product_id, developer_id=g.workspace_developer_id).first_or_404()

    if product.tebex_integration:
        flash("Tebex is already connected for this product.", "info")
        return redirect(url_for("developer.tebex_settings", product_id=product.product_id))

    package_id = request.form.get("package_id", "").strip() or None
    raw_secret = generate_webhook_secret()

    integration = TebexIntegration(
        product_id=product.id,
        developer_id=g.workspace_developer_id,
        webhook_secret_encrypted=encrypt_secret(raw_secret),
        webhook_secret_prefix=raw_secret[:14],
        package_id_filter=package_id,
    )
    db.session.add(integration)
    db.session.commit()

    return render_template(
        "developer/tebex_secret_shown.html",
        product=product,
        webhook_secret=raw_secret,
        regenerated=False,
    )


@developer_bp.route("/developer/products/<product_id>/tebex/regenerate", methods=["POST"])
@login_required
@developer_required
def tebex_regenerate(product_id):
    product = Product.query.filter_by(product_id=product_id, developer_id=g.workspace_developer_id).first_or_404()
    integration = product.tebex_integration
    if not integration:
        flash("Connect Tebex first.", "error")
        return redirect(url_for("developer.tebex_settings", product_id=product.product_id))

    raw_secret = generate_webhook_secret()
    integration.webhook_secret_encrypted = encrypt_secret(raw_secret)
    integration.webhook_secret_prefix = raw_secret[:14]
    db.session.commit()

    return render_template(
        "developer/tebex_secret_shown.html",
        product=product,
        webhook_secret=raw_secret,
        regenerated=True,
    )


@developer_bp.route("/developer/products/<product_id>/tebex/toggle", methods=["POST"])
@login_required
@developer_required
def tebex_toggle(product_id):
    product = Product.query.filter_by(product_id=product_id, developer_id=g.workspace_developer_id).first_or_404()
    integration = product.tebex_integration
    if not integration:
        flash("Connect Tebex first.", "error")
        return redirect(url_for("developer.tebex_settings", product_id=product.product_id))

    integration.is_active = not integration.is_active
    db.session.commit()
    flash(f"Tebex integration {'enabled' if integration.is_active else 'paused'}.", "info")
    return redirect(url_for("developer.tebex_settings", product_id=product.product_id))


# ---------------------------------------------------------------- scripts
@developer_bp.route("/developer/products/<product_id>/scripts")
@login_required
@developer_required
def scripts(product_id):
    product = Product.query.filter_by(product_id=product_id, developer_id=g.workspace_developer_id).first_or_404()
    uploads = ScriptUpload.query.filter_by(product_id=product.id).order_by(ScriptUpload.created_at.desc()).all()
    return render_template("developer/scripts.html", product=product, uploads=uploads)


@developer_bp.route("/developer/products/<product_id>/scripts/upload", methods=["POST"])
@login_required
@developer_required
def upload_script(product_id):
    product = Product.query.filter_by(product_id=product_id, developer_id=g.workspace_developer_id).first_or_404()

    file = request.files.get("script_zip")
    if not file or file.filename == "":
        flash("Choose a .zip file to upload.", "error")
        return redirect(url_for("developer.scripts", product_id=product.product_id))

    if not file.filename.lower().endswith(".zip"):
        flash("Only .zip files are accepted.", "error")
        return redirect(url_for("developer.scripts", product_id=product.product_id))

    upload_bytes = file.read()

    record = ScriptUpload(
        product_id=product.id,
        developer_id=g.workspace_developer_id,
        original_filename=file.filename,
        status="processing",
    )
    db.session.add(record)
    db.session.commit()

    owner = User.query.get(g.workspace_developer_id)
    api_base = (
        owner.developer_profile.effective_api_base(current_app.config["SITE_URL"])
        if owner.developer_profile else current_app.config["SITE_URL"]
    )

    try:
        protected_bytes, resource_name, checksum = build_protected_package(
            upload_bytes,
            product,
            site_name=current_app.config["SITE_NAME"],
            api_base=api_base,
        )
    except InjectorError as e:
        record.status = "failed"
        record.error_message = str(e)
        db.session.commit()
        flash(f"Upload failed: {e}", "error")
        return redirect(url_for("developer.scripts", product_id=product.product_id))

    product_dir = os.path.join(current_app.config["UPLOAD_FOLDER"], product.product_id)
    os.makedirs(product_dir, exist_ok=True)
    filename = f"protected_{record.id}_{resource_name}.zip"
    full_path = os.path.join(product_dir, filename)
    with open(full_path, "wb") as f:
        f.write(protected_bytes)

    record.resource_name = resource_name
    record.status = "ready"
    record.protected_file_path = os.path.join(product.product_id, filename)
    record.file_size_bytes = len(protected_bytes)
    record.checksum_sha256 = checksum
    db.session.commit()

    # Auto-publish as Modules too - this is what makes the upload
    # immediately deliverable through CloudLoader's API with zero manual
    # file installs. The protected zip above is kept as an optional
    # fallback for anyone who wants a traditionally-installed resource,
    # but this is the path that actually needs nothing but CloudLoader.
    created_count = 0
    updated_count = 0
    try:
        extracted = extract_modules_from_upload(upload_bytes)
    except InjectorError:
        extracted = []  # already validated above; treat any surprise here as "nothing to publish"

    for m in extracted:
        existing = Module.query.filter_by(product_id=product.id, name=m["name"]).first()
        if existing:
            existing.code = m["code"]
            existing.side = m["side"]
            updated_count += 1
        else:
            db.session.add(Module(
                product_id=product.id,
                developer_id=g.workspace_developer_id,
                name=m["name"],
                display_name=m["source_path"],
                side=m["side"],
                code=m["code"],
            ))
            created_count += 1
    db.session.commit()

    if created_count or updated_count:
        flash(
            f"{file.filename} processed. {created_count} module(s) published, "
            f"{updated_count} updated - already live for licensed customers, "
            f"no separate install needed.",
            "success",
        )
    else:
        flash(f"{file.filename} processed and protected successfully.", "success")

    return redirect(url_for("developer.scripts", product_id=product.product_id))


@developer_bp.route("/developer/scripts/<int:upload_id>/download")
@login_required
@developer_required
def download_script(upload_id):
    record = ScriptUpload.query.filter_by(id=upload_id, developer_id=g.workspace_developer_id).first_or_404()
    if record.status != "ready" or not record.protected_file_path:
        flash("This build isn't ready to download.", "error")
        return redirect(url_for("developer.scripts", product_id=record.product.product_id))

    full_path = os.path.join(current_app.config["UPLOAD_FOLDER"], record.protected_file_path)
    return send_file(
        full_path,
        as_attachment=True,
        download_name=f"{record.resource_name}_protected.zip",
        mimetype="application/zip",
    )


# ---------------------------------------------------------------- modules
def _slugify_module_name(name: str) -> str:
    slug = re.sub(r"[^a-z0-9_]", "_", name.lower().strip())
    slug = re.sub(r"_+", "_", slug).strip("_")
    return slug or "module"


@developer_bp.route("/developer/products/<product_id>/modules")
@login_required
@developer_required
def modules(product_id):
    product = Product.query.filter_by(product_id=product_id, developer_id=g.workspace_developer_id).first_or_404()
    items = Module.query.filter_by(product_id=product.id).order_by(Module.created_at.desc()).all()
    return render_template("developer/modules.html", product=product, modules=items)


@developer_bp.route("/developer/products/<product_id>/modules/new", methods=["GET", "POST"])
@login_required
@developer_required
def new_module(product_id):
    product = Product.query.filter_by(product_id=product_id, developer_id=g.workspace_developer_id).first_or_404()

    if request.method == "POST":
        display_name = request.form.get("display_name", "").strip()
        side = request.form.get("side", "server")
        code = request.form.get("code", "")
        version = request.form.get("version", "1.0.0").strip() or "1.0.0"
        channel = request.form.get("channel", "stable")

        if not display_name or not code.strip():
            flash("Name and code are required.", "error")
            return render_template("developer/module_form.html", product=product, display_name=display_name, side=side, code=code, version=version, channel=channel)

        if side not in ("server", "client"):
            side = "server"
        if channel not in ("stable", "beta"):
            channel = "stable"

        name = _slugify_module_name(display_name)
        base_name = name
        n = 1
        while Module.query.filter_by(product_id=product.id, name=name, channel=channel).first():
            n += 1
            name = f"{base_name}_{n}"

        module = Module(
            product_id=product.id,
            developer_id=g.workspace_developer_id,
            name=name,
            display_name=display_name,
            side=side,
            code=code,
            version=version,
            channel=channel,
        )
        db.session.add(module)
        db.session.commit()
        flash(f"Module '{display_name}' created.", "success")
        return redirect(url_for("developer.modules", product_id=product.product_id))

    return render_template("developer/module_form.html", product=product)


@developer_bp.route("/developer/products/<product_id>/modules/<int:module_id>/edit", methods=["GET", "POST"])
@login_required
@developer_required
def edit_module(product_id, module_id):
    product = Product.query.filter_by(product_id=product_id, developer_id=g.workspace_developer_id).first_or_404()
    module = Module.query.filter_by(id=module_id, product_id=product.id).first_or_404()

    if request.method == "POST":
        module.display_name = request.form.get("display_name", module.display_name).strip()
        module.side = request.form.get("side", module.side)
        module.code = request.form.get("code", module.code)
        module.version = request.form.get("version", module.version).strip() or module.version
        db.session.commit()
        flash(f"Module '{module.display_name}' updated.", "success")
        return redirect(url_for("developer.modules", product_id=product.product_id))

    return render_template(
        "developer/module_form.html", product=product, module=module,
        display_name=module.display_name, side=module.side, code=module.code, version=module.version, channel=module.channel,
    )


@developer_bp.route("/developer/products/<product_id>/modules/<int:module_id>/toggle", methods=["POST"])
@login_required
@developer_required
def toggle_module(product_id, module_id):
    product = Product.query.filter_by(product_id=product_id, developer_id=g.workspace_developer_id).first_or_404()
    module = Module.query.filter_by(id=module_id, product_id=product.id).first_or_404()
    module.is_active = not module.is_active
    db.session.commit()
    return redirect(url_for("developer.modules", product_id=product.product_id))


@developer_bp.route("/developer/products/<product_id>/modules/<int:module_id>/delete", methods=["POST"])
@login_required
@developer_required
def delete_module(product_id, module_id):
    product = Product.query.filter_by(product_id=product_id, developer_id=g.workspace_developer_id).first_or_404()
    module = Module.query.filter_by(id=module_id, product_id=product.id).first_or_404()
    db.session.delete(module)
    db.session.commit()
    flash("Module deleted.", "info")
    return redirect(url_for("developer.modules", product_id=product.product_id))


# ----------------------------------------------------------- remote config
@developer_bp.route("/developer/products/<product_id>/config", methods=["GET", "POST"])
@login_required
@developer_required
def remote_config(product_id):
    product = Product.query.filter_by(product_id=product_id, developer_id=g.workspace_developer_id).first_or_404()

    if request.method == "POST":
        raw = request.form.get("config_json", "").strip()
        if not raw:
            product.remote_config = None
            db.session.commit()
            flash("Config cleared.", "info")
            return redirect(url_for("developer.remote_config", product_id=product.product_id))

        try:
            parsed = json.loads(raw)
        except (ValueError, TypeError) as e:
            flash(f"That's not valid JSON: {e}", "error")
            return render_template("developer/remote_config.html", product=product, config_json=raw)

        if not isinstance(parsed, dict):
            flash("Config must be a JSON object, e.g. {\"key\": \"value\"} - not a list or plain value.", "error")
            return render_template("developer/remote_config.html", product=product, config_json=raw)

        product.remote_config = json.dumps(parsed)
        db.session.commit()
        flash("Config saved - live for licensed customers on their next re-check (or restart CloudLoader now).", "success")
        return redirect(url_for("developer.remote_config", product_id=product.product_id))

    current_json = product.remote_config or "{}"
    try:
        # re-pretty-print for readability
        current_json = json.dumps(json.loads(current_json), indent=2)
    except (ValueError, TypeError):
        pass

    return render_template("developer/remote_config.html", product=product, config_json=current_json)


# --------------------------------------------------------- server monitor
@developer_bp.route("/developer/products/<product_id>/servers")
@login_required
@developer_required
def product_servers(product_id):
    product = Product.query.filter_by(product_id=product_id, developer_id=g.workspace_developer_id).first_or_404()

    from app.models.portal import ServerLicense
    from app.utils import is_server_online, humanize_relative_time

    attachments = (
        ServerLicense.query.join(License, ServerLicense.license_id == License.id)
        .filter(License.product_id == product.id)
        .all()
    )

    rows = []
    online_count = 0
    for a in attachments:
        online = is_server_online(a.server.last_seen_at)
        if online:
            online_count += 1
        rows.append({
            "server_name": a.server.name,
            "license_key": a.license.license_key,
            "license_status": a.license.status,
            "channel": a.channel,
            "online": online,
            "last_seen_text": humanize_relative_time(a.server.last_seen_at),
        })

    return render_template(
        "developer/product_servers.html", product=product, rows=rows,
        online_count=online_count, total_count=len(rows),
    )


# --------------------------------------------------------------- analytics
@developer_bp.route("/developer/products/<product_id>/analytics")
@login_required
@developer_required
def analytics(product_id):
    product = Product.query.filter_by(product_id=product_id, developer_id=g.workspace_developer_id).first_or_404()

    since = datetime.now(timezone.utc) - timedelta(days=14)
    events = UsageEvent.query.filter(
        UsageEvent.product_id == product.id, UsageEvent.created_at >= since
    ).all()

    # Daily license-check counts for the last 14 days, oldest first.
    daily_counts = {}
    today = datetime.now(timezone.utc).date()
    for i in range(13, -1, -1):
        day = today - timedelta(days=i)
        daily_counts[day] = 0
    for e in events:
        if e.event_type == "license_check":
            day = e.created_at.date()
            if day in daily_counts:
                daily_counts[day] += 1

    max_count = max(daily_counts.values()) or 1
    chart_bars = [
        {"date": day.strftime("%m/%d"), "count": count, "height_pct": round(count / max_count * 100)}
        for day, count in daily_counts.items()
    ]

    module_downloads = {}
    for e in events:
        if e.event_type == "module_download" and e.module_name:
            module_downloads[e.module_name] = module_downloads.get(e.module_name, 0) + 1
    top_modules = sorted(module_downloads.items(), key=lambda kv: kv[1], reverse=True)[:10]

    totals = {
        "license_checks_14d": sum(1 for e in events if e.event_type == "license_check"),
        "module_downloads_14d": sum(1 for e in events if e.event_type == "module_download"),
        "purchases_14d": sum(1 for e in events if e.event_type == "tebex_purchase"),
        "total_licenses": License.query.filter_by(product_id=product.id).count(),
        "active_licenses": License.query.filter_by(product_id=product.id, status="active").count(),
    }

    return render_template(
        "developer/analytics.html", product=product, chart_bars=chart_bars,
        top_modules=top_modules, totals=totals,
    )


# ---------------------------------------------------------------- activity
@developer_bp.route("/developer/activity")
@login_required
@developer_required
def activity_log():
    if g.workspace_developer_id != current_user.id:
        flash("Only the workspace owner can view the activity log.", "error")
        return redirect(url_for("developer.overview"))

    from app.models.developer import WorkspaceActivityLog
    entries = (
        WorkspaceActivityLog.query.filter_by(developer_id=current_user.id)
        .order_by(WorkspaceActivityLog.created_at.desc())
        .limit(200)
        .all()
    )
    return render_template("developer/activity_log.html", entries=entries)


# -------------------------------------------------------------------- team
@developer_bp.route("/developer/team")
@login_required
@developer_required
def team():
    # Only the actual owner manages the team, not other members - avoids
    # members inviting/removing each other.
    if g.workspace_developer_id != current_user.id:
        flash("Only the workspace owner can manage the team.", "error")
        return redirect(url_for("developer.overview"))

    members = TeamMember.query.filter_by(developer_id=current_user.id).all()
    return render_template("developer/team.html", members=members)


@developer_bp.route("/developer/team/invite", methods=["POST"])
@login_required
@developer_required
def invite_team_member():
    if g.workspace_developer_id != current_user.id:
        flash("Only the workspace owner can manage the team.", "error")
        return redirect(url_for("developer.overview"))

    email = request.form.get("email", "").strip().lower()
    invitee = User.query.filter_by(email=email).first()

    if not invitee:
        flash("No account found with that email - they need to sign up first.", "error")
        return redirect(url_for("developer.team"))

    if invitee.id == current_user.id:
        flash("You can't invite yourself.", "error")
        return redirect(url_for("developer.team"))

    existing = TeamMember.query.filter_by(developer_id=current_user.id, member_user_id=invitee.id).first()
    if existing:
        flash(f"{invitee.username} is already a member or has a pending invite.", "info")
        return redirect(url_for("developer.team"))

    member = TeamMember(developer_id=current_user.id, member_user_id=invitee.id)
    db.session.add(member)
    log_activity(current_user.id, "team_member_invited", detail=invitee.username)
    db.session.commit()
    flash(f"Invited {invitee.username}. They can accept it from their dashboard.", "success")
    return redirect(url_for("developer.team"))


@developer_bp.route("/developer/team/<int:member_id>/remove", methods=["POST"])
@login_required
@developer_required
def remove_team_member(member_id):
    if g.workspace_developer_id != current_user.id:
        flash("Only the workspace owner can manage the team.", "error")
        return redirect(url_for("developer.overview"))

    member = TeamMember.query.filter_by(id=member_id, developer_id=current_user.id).first_or_404()
    removed_username = member.member.username
    db.session.delete(member)
    log_activity(current_user.id, "team_member_removed", detail=removed_username)
    db.session.commit()
    flash("Removed from team.", "info")
    return redirect(url_for("developer.team"))


@developer_bp.route("/developer/team/invites/<int:invite_id>/accept", methods=["POST"])
@login_required
def accept_team_invite(invite_id):
    invite = TeamMember.query.filter_by(id=invite_id, member_user_id=current_user.id).first_or_404()
    invite.accepted_at = datetime.now(timezone.utc)
    log_activity(invite.developer_id, "team_member_joined", detail=current_user.username)
    db.session.commit()

    owner = invite.owner
    if owner.developer_profile and owner.developer_profile.email_notifications_enabled:
        from app.auth.mailer import send_email
        send_email(
            to=owner.email,
            subject=f"{current_user.username} joined your team",
            body=(
                f"{current_user.username} accepted your invite and now has full access "
                f"to your workspace's products, licenses, and modules.\n\n"
                f"Manage your team: {url_for('developer.team', _external=True)}"
            ),
        )

    flash(f"You're now on {invite.owner.username}'s team.", "success")
    return redirect(url_for("developer.overview"))


@developer_bp.route("/developer/team/invites/<int:invite_id>/decline", methods=["POST"])
@login_required
def decline_team_invite(invite_id):
    invite = TeamMember.query.filter_by(id=invite_id, member_user_id=current_user.id).first_or_404()
    db.session.delete(invite)
    db.session.commit()
    flash("Invite declined.", "info")
    return redirect(url_for("dashboard.index"))


# ----------------------------------------------------------------- customers
@developer_bp.route("/developer/customers")
@login_required
@developer_required
def customers():
    licenses = (
        License.query.filter_by(developer_id=g.workspace_developer_id)
        .filter(License.customer_email.isnot(None))
        .order_by(License.customer_email)
        .all()
    )

    grouped = {}
    for lic in licenses:
        grouped.setdefault(lic.customer_email, []).append(lic)

    return render_template("developer/customers.html", grouped=grouped)


def _csv_response(rows, header, filename):
    buffer = io.StringIO()
    writer = csv.writer(buffer)
    writer.writerow(header)
    writer.writerows(rows)
    return Response(
        buffer.getvalue(),
        mimetype="text/csv",
        headers={"Content-Disposition": f"attachment; filename={filename}"},
    )


@developer_bp.route("/developer/products/<product_id>/licenses/export.csv")
@login_required
@developer_required
def export_product_licenses(product_id):
    product = Product.query.filter_by(product_id=product_id, developer_id=g.workspace_developer_id).first_or_404()
    licenses = License.query.filter_by(product_id=product.id).order_by(License.created_at.desc()).all()

    rows = [
        [
            lic.license_key,
            lic.customer_email or "",
            lic.status,
            lic.created_at.strftime("%Y-%m-%d %H:%M") if lic.created_at else "",
            lic.activated_at.strftime("%Y-%m-%d %H:%M") if lic.activated_at else "",
            lic.last_checked_at.strftime("%Y-%m-%d %H:%M") if lic.last_checked_at else "",
            lic.server_binding or "",
        ]
        for lic in licenses
    ]
    header = ["license_key", "customer_email", "status", "created_at", "activated_at", "last_checked_at", "server_binding"]
    safe_name = re.sub(r"[^a-zA-Z0-9_-]", "_", product.name.lower())
    return _csv_response(rows, header, f"{safe_name}_licenses.csv")


@developer_bp.route("/developer/customers/export.csv")
@login_required
@developer_required
def export_customers():
    licenses = (
        License.query.filter_by(developer_id=g.workspace_developer_id)
        .filter(License.customer_email.isnot(None))
        .order_by(License.customer_email)
        .all()
    )

    rows = [
        [
            lic.customer_email,
            lic.product.name,
            lic.license_key,
            lic.status,
            lic.created_at.strftime("%Y-%m-%d %H:%M") if lic.created_at else "",
        ]
        for lic in licenses
    ]
    header = ["customer_email", "product", "license_key", "status", "created_at"]
    return _csv_response(rows, header, "customers.csv")


# ----------------------------------------------------------------- api keys
@developer_bp.route("/developer/api-keys")
@login_required
@developer_required
def api_keys():
    owner = User.query.get(g.workspace_developer_id)
    return render_template("developer/api_keys.html", profile=owner.developer_profile)


@developer_bp.route("/developer/api-keys/regenerate", methods=["POST"])
@login_required
@developer_required
def regenerate_api_key():
    owner = User.query.get(g.workspace_developer_id)
    raw_key, prefix = generate_developer_api_key()
    owner.developer_profile.developer_api_key_hash = hash_secret(raw_key)
    owner.developer_profile.developer_api_key_prefix = prefix
    db.session.commit()
    return render_template("developer/api_key_created.html", api_key=raw_key, regenerate=True)


@developer_bp.route("/developer/notifications/toggle", methods=["POST"])
@login_required
@developer_required
def toggle_email_notifications():
    if g.workspace_developer_id != current_user.id:
        flash("Only the workspace owner can manage notifications.", "error")
        return redirect(url_for("developer.overview"))

    owner = User.query.get(g.workspace_developer_id)
    owner.developer_profile.email_notifications_enabled = not owner.developer_profile.email_notifications_enabled
    db.session.commit()
    return redirect(url_for("developer.api_keys"))


# ------------------------------------------------------------- custom domain
def _normalize_domain(raw: str) -> str:
    raw = raw.strip().lower()
    raw = re.sub(r"^https?://", "", raw)
    raw = raw.rstrip("/")
    raw = raw.split("/")[0]  # drop any accidental path
    return raw


_DOMAIN_RE = re.compile(r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$")


@developer_bp.route("/developer/domain")
@login_required
@developer_required
def custom_domain():
    if g.workspace_developer_id != current_user.id:
        flash("Only the workspace owner can manage the custom domain.", "error")
        return redirect(url_for("developer.overview"))
    owner = User.query.get(g.workspace_developer_id)
    return render_template(
        "developer/custom_domain.html",
        profile=owner.developer_profile,
        site_url=current_app.config["SITE_URL"],
    )


@developer_bp.route("/developer/domain/set", methods=["POST"])
@login_required
@developer_required
def set_custom_domain():
    if g.workspace_developer_id != current_user.id:
        flash("Only the workspace owner can manage the custom domain.", "error")
        return redirect(url_for("developer.overview"))

    raw = request.form.get("domain", "")
    domain = _normalize_domain(raw)

    if not domain or not _DOMAIN_RE.match(domain):
        flash("That doesn't look like a valid domain (e.g. scripts.yourbrand.com).", "error")
        return redirect(url_for("developer.custom_domain"))

    owner = User.query.get(g.workspace_developer_id)
    owner.developer_profile.custom_domain = domain
    owner.developer_profile.custom_domain_verified = False
    owner.developer_profile.custom_domain_checked_at = None
    log_activity(g.workspace_developer_id, "domain_changed", detail=domain)
    db.session.commit()

    flash(f"Domain set to {domain}. Verify it below once your DNS is pointed here.", "success")
    return redirect(url_for("developer.custom_domain"))


@developer_bp.route("/developer/domain/verify", methods=["POST"])
@login_required
@developer_required
def verify_custom_domain():
    if g.workspace_developer_id != current_user.id:
        flash("Only the workspace owner can manage the custom domain.", "error")
        return redirect(url_for("developer.overview"))

    owner = User.query.get(g.workspace_developer_id)
    profile = owner.developer_profile

    if not profile.custom_domain:
        flash("Set a domain first.", "error")
        return redirect(url_for("developer.custom_domain"))

    import requests
    from datetime import datetime, timezone as tz

    ok = False
    error_detail = None
    try:
        resp = requests.get(f"https://{profile.custom_domain}/api/ping", timeout=8)
        if resp.status_code == 200:
            data = resp.json()
            if data.get("ok") and data.get("platform") == current_app.config["SITE_NAME"]:
                ok = True
            else:
                error_detail = "Reached a server, but it's not this platform - check the CNAME target."
        else:
            error_detail = f"Got HTTP {resp.status_code} instead of 200."
    except requests.exceptions.SSLError:
        error_detail = "TLS/SSL error - if you're using Cloudflare, make sure SSL mode is Flexible or Full, not Off."
    except requests.exceptions.ConnectionError:
        error_detail = "Could not connect - check the CNAME is pointed correctly and has had time to propagate."
    except requests.exceptions.Timeout:
        error_detail = "Timed out - the domain isn't responding."
    except Exception as e:
        error_detail = str(e)

    profile.custom_domain_verified = ok
    profile.custom_domain_checked_at = datetime.now(tz.utc)
    db.session.commit()

    if ok:
        flash("Domain verified! Newly uploaded scripts and configs will use it from now on.", "success")
    else:
        flash(f"Verification failed: {error_detail}", "error")

    return redirect(url_for("developer.custom_domain"))


@developer_bp.route("/developer/domain/clear", methods=["POST"])
@login_required
@developer_required
def clear_custom_domain():
    if g.workspace_developer_id != current_user.id:
        flash("Only the workspace owner can manage the custom domain.", "error")
        return redirect(url_for("developer.overview"))

    owner = User.query.get(g.workspace_developer_id)
    owner.developer_profile.custom_domain = None
    owner.developer_profile.custom_domain_verified = False
    owner.developer_profile.custom_domain_checked_at = None
    log_activity(g.workspace_developer_id, "domain_removed")
    db.session.commit()
    flash("Custom domain removed. Back to the default platform domain.", "info")
    return redirect(url_for("developer.custom_domain"))
