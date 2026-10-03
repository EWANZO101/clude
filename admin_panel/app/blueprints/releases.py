import os
import uuid
import zipfile

from flask import Blueprint, render_template, redirect, url_for, request, flash, current_app, abort
from flask_login import login_required, current_user
from werkzeug.utils import secure_filename

from app.extensions import db
from app.models import UpdatePackage, Product, SUPPORTED_OS, log_action, kiosk_product_id
from app.platform_auth import platform_admin_required
from app.update_validation import (
    validate_update_zip, peek_manifest_version,
    repair_package, register_package_from_zip, format_file_listing, RESCUE_PREFIX,
)
from app.datetime_utils import group_by_month_week
from tools.build_kiosk_release import build_kiosk_release_zip

bp = Blueprint("releases", __name__, url_prefix="/admin/releases")


def _ensure_upload_dir():
    d = current_app.config["UPDATE_PACKAGE_DIR"]
    os.makedirs(d, exist_ok=True)
    return d


@bp.route("/")
@login_required
@platform_admin_required
def list_releases():
    packages = UpdatePackage.query.order_by(UpdatePackage.uploaded_at.desc()).all()
    deletable_ids = {p.id for p in packages if p.delete_blocking_reason() is None}

    def _category(p):
        if p.withdrawn:
            return "withdrawn"
        return "validated" if p.status == "validated" else "invalid"

    by_category = {"validated": [], "invalid": [], "withdrawn": []}
    for p in packages:
        by_category[_category(p)].append(p)

    by_uploaded_at = lambda p: p.uploaded_at
    package_groups = {
        "all": group_by_month_week(packages, by_uploaded_at),
        "validated": group_by_month_week(by_category["validated"], by_uploaded_at),
        "invalid": group_by_month_week(by_category["invalid"], by_uploaded_at),
        "withdrawn": group_by_month_week(by_category["withdrawn"], by_uploaded_at),
    }
    package_counts = {
        "all": len(packages),
        "validated": len(by_category["validated"]),
        "invalid": len(by_category["invalid"]),
        "withdrawn": len(by_category["withdrawn"]),
    }

    return render_template(
        "releases/list.html", package_groups=package_groups, package_counts=package_counts,
        deletable_ids=deletable_ids,
    )


def _selectable_products():
    return Product.query.filter_by(is_active=True).order_by(Product.name).all()


@bp.route("/upload", methods=["GET", "POST"])
@login_required
@platform_admin_required
def upload():
    products = _selectable_products()
    supported_os_choices = SUPPORTED_OS

    if request.method == "POST":
        version = request.form.get("version", "").strip()
        release_notes = request.form.get("release_notes", "").strip()
        uploaded_file = request.files.get("package")
        product = Product.query.filter_by(public_id=request.form.get("product_id", "")).first()
        product_id = product.id if product is not None else kiosk_product_id()
        is_kiosk = product_id == kiosk_product_id()
        # Only meaningful for a non-kiosk product — kiosk always derives
        # supported_os from the zip's own update.json instead (see
        # register_package_from_zip/validate_update_zip).
        selected_os = [o for o in request.form.getlist("supported_os") if o in SUPPORTED_OS]

        errors = []
        if not version:
            errors.append("Version is required.")
        elif UpdatePackage.query.filter_by(version=version, product_id=product_id).first() is not None:
            errors.append(f"A package with version '{version}' already exists for this product.")
        if uploaded_file is None or uploaded_file.filename == "":
            errors.append("Choose a ZIP file to upload.")
        elif not uploaded_file.filename.lower().endswith(".zip"):
            errors.append("The update package must be a .zip file.")
        if not is_kiosk and not selected_os:
            errors.append("Choose at least one supported operating system.")

        if errors:
            for e in errors:
                flash(e, "danger")
            return render_template(
                "releases/upload.html", version=version, release_notes=release_notes,
                products=products, selected_product_id=request.form.get("product_id", ""),
                selected_os=selected_os, supported_os_choices=supported_os_choices,
            )

        upload_dir = _ensure_upload_dir()
        safe_name = secure_filename(f"{version}-{uuid.uuid4().hex[:8]}.zip")
        dest_path = os.path.join(upload_dir, safe_name)
        uploaded_file.save(dest_path)

        ok, val_errors, package = register_package_from_zip(
            dest_path, version, release_notes, current_user.id, product_id=product_id,
            supported_os=selected_os,
        )
        db.session.add(package)
        log_action(None, current_user, "package_uploaded", f"v{version} ({'validated' if ok else 'invalid'})")
        db.session.commit()

        if ok:
            flash(f"Package v{version} uploaded and validated successfully.", "success")
        else:
            flash(
                f"Package v{version} was uploaded but failed validation — it cannot be pushed "
                f"to any instance until re-uploaded correctly. See details below.",
                "danger",
            )

        return redirect(url_for("releases.detail", package_id=package.public_id))

    return render_template("releases/upload.html", products=products, supported_os_choices=supported_os_choices)


@bp.route("/build", methods=["GET", "POST"])
@login_required
@platform_admin_required
def build_from_source():
    """Builds a release straight from kiosk_app/ (see
    tools/build_kiosk_release.py) instead of asking a human to attach some
    zip file from wherever — the sanctioned path after the v1.0.2 incident,
    where an uploaded zip turned out to be a snapshot of the Admin Panel's
    own source tree rather than the Kiosk App. The output still goes through
    the exact same validate_update_zip (content-firewall included) as a
    manual upload; this only removes "which file do I attach" as a place for
    a human to get it wrong."""
    if request.method == "POST":
        version = request.form.get("version", "").strip()
        release_notes = request.form.get("release_notes", "").strip()

        errors = []
        if not version:
            errors.append("Version is required.")
        elif UpdatePackage.query.filter_by(version=version, product_id=kiosk_product_id()).first() is not None:
            errors.append(f"A package with version '{version}' already exists.")

        if errors:
            for e in errors:
                flash(e, "danger")
            return render_template("releases/build.html", version=version, release_notes=release_notes)

        upload_dir = _ensure_upload_dir()
        safe_name = secure_filename(f"{version}-{uuid.uuid4().hex[:8]}.zip")
        dest_path = os.path.join(upload_dir, safe_name)
        try:
            build_kiosk_release_zip(version, dest_path)
        except (FileNotFoundError, OSError) as e:
            flash(f"Couldn't build a package from kiosk_app/: {e}", "danger")
            return render_template("releases/build.html", version=version, release_notes=release_notes)

        # This route only ever builds from kiosk_app/ (see build_kiosk_release_zip
        # above) — always the kiosk product, no selector needed here.
        ok, val_errors, package = register_package_from_zip(
            dest_path, version, release_notes, current_user.id, product_id=kiosk_product_id(),
        )
        db.session.add(package)
        log_action(None, current_user, "package_uploaded", f"v{version} ({'validated' if ok else 'invalid'}, built from kiosk_app/)")
        db.session.commit()

        if ok:
            flash(f"Package v{version} built from kiosk_app/ and validated successfully.", "success")
        else:
            flash(
                f"Package v{version} was built but failed validation — see details below. "
                f"This means kiosk_app/ itself has a structural problem right now.",
                "danger",
            )
        return redirect(url_for("releases.detail", package_id=package.public_id))

    return render_template("releases/build.html")


@bp.route("/<package_id>")
@login_required
@platform_admin_required
def detail(package_id):
    package = UpdatePackage.query.filter_by(public_id=package_id).first()
    if package is None:
        abort(404)
    manifest_version = None
    if package.status == "invalid":
        manifest_version = peek_manifest_version(package.file_path)
        if manifest_version == package.version:
            manifest_version = None  # nothing to fix — mismatch wasn't the (only) problem
    return render_template(
        "releases/detail.html", package=package,
        manifest_version=manifest_version,
        delete_blocking_reason=package.delete_blocking_reason(),
    )


@bp.route("/<package_id>/withdraw", methods=["POST"])
@login_required
@platform_admin_required
def withdraw(package_id):
    package = UpdatePackage.query.filter_by(public_id=package_id).first()
    if package is None:
        abort(404)
    package.withdrawn = True
    log_action(None, current_user, "package_withdrawn", f"v{package.version}")
    db.session.commit()
    flash(f"Package v{package.version} withdrawn — it can no longer be pushed to instances.", "info")
    return redirect(url_for("releases.detail", package_id=package.public_id))


@bp.route("/<package_id>/reinstate", methods=["POST"])
@login_required
@platform_admin_required
def reinstate(package_id):
    package = UpdatePackage.query.filter_by(public_id=package_id).first()
    if package is None:
        abort(404)
    if package.status != "validated":
        flash("Only a previously-validated package can be reinstated.", "danger")
        return redirect(url_for("releases.detail", package_id=package.public_id))
    package.withdrawn = False
    db.session.commit()
    flash(f"Package v{package.version} reinstated.", "success")
    return redirect(url_for("releases.detail", package_id=package.public_id))


@bp.route("/<package_id>/autofix-version", methods=["POST"])
@login_required
@platform_admin_required
def autofix_version(package_id):
    """Re-validates an invalid package against the version already baked
    into its own update.json, instead of the (wrong) version typed on the
    upload form — so a version-mismatch rejection doesn't require rebuilding
    and re-uploading the exact same ZIP."""
    package = UpdatePackage.query.filter_by(public_id=package_id).first()
    if package is None:
        abort(404)
    if package.status != "invalid":
        flash("Auto-fix only applies to a package that failed validation.", "danger")
        return redirect(url_for("releases.detail", package_id=package.public_id))

    manifest_version = peek_manifest_version(package.file_path)
    if not manifest_version:
        flash("Couldn't read a version from this package's update.json — nothing to auto-fix.", "danger")
        return redirect(url_for("releases.detail", package_id=package.public_id))
    if manifest_version == package.version:
        flash("update.json already matches the version on this package — the mismatch isn't the problem here.", "danger")
        return redirect(url_for("releases.detail", package_id=package.public_id))

    conflict = UpdatePackage.query.filter(
        UpdatePackage.version == manifest_version, UpdatePackage.product_id == package.product_id,
        UpdatePackage.id != package.id,
    ).first()
    if conflict is not None:
        flash(
            f"Can't auto-fix to v{manifest_version} — that version already exists "
            f"(uploaded {conflict.uploaded_at.strftime('%Y-%m-%d')}). Withdraw or rename that "
            f"one first, or fix update.json and re-upload.",
            "danger",
        )
        return redirect(url_for("releases.detail", package_id=package.public_id))

    old_version = package.version
    ok, val_errors, metadata = validate_update_zip(package.file_path, expected_version=manifest_version)

    package.version = manifest_version
    package.supported_os = ",".join(metadata.get("supported_os") or [])
    package.status = "validated" if ok else "invalid"
    package.validation_log = "\n".join(val_errors) if val_errors else None
    package.has_rescue_component = metadata.get("has_rescue", False)
    package.file_listing = format_file_listing(metadata)

    log_action(
        None, current_user, "package_version_autofixed",
        f"v{old_version} -> v{manifest_version} ({'validated' if ok else 'still invalid'})",
    )
    db.session.commit()

    if ok:
        flash(f"Fixed — this package is now v{manifest_version} and validated successfully.", "success")
    else:
        flash(
            f"Version updated to v{manifest_version}, but other validation errors remain — see below.",
            "danger",
        )
    return redirect(url_for("releases.detail", package_id=package.public_id))


def _find_repair_donor(exclude_id, product_id):
    """Most recent validated, non-withdrawn package OF THE SAME PRODUCT —
    used as the source of a known-good rescue/ component and a default
    supported_os list when repairing another package that's missing them
    outright. Scoped by product since a donor's rescue/ contents are only
    meaningful for packages shaped the same way."""
    return (
        UpdatePackage.query
        .filter(
            UpdatePackage.status == "validated",
            UpdatePackage.withdrawn.is_(False),
            UpdatePackage.product_id == product_id,
            UpdatePackage.id != exclude_id,
        )
        .order_by(UpdatePackage.uploaded_at.desc())
        .first()
    )


@bp.route("/<package_id>/fix", methods=["POST"])
@login_required
@platform_admin_required
def fix_package(package_id):
    """General repair for a package that failed validation because it's
    missing update.json and/or a rescue/ component: synthesizes a manifest
    for this package's own version and copies the rescue/ files from the
    most recently validated package, then re-validates. Only fixes
    structural completeness — a version mismatch inside an existing
    manifest should use Auto-fix version instead, and this can't fix a
    package whose payload itself is wrong."""
    package = UpdatePackage.query.filter_by(public_id=package_id).first()
    if package is None:
        abort(404)
    if package.status != "invalid":
        flash("Fix only applies to a package that failed validation.", "danger")
        return redirect(url_for("releases.detail", package_id=package.public_id))

    donor = _find_repair_donor(package.id, package.product_id)
    if donor is None:
        flash("No validated package exists yet to copy a rescue component from — nothing to fix against.", "danger")
        return redirect(url_for("releases.detail", package_id=package.public_id))

    try:
        with zipfile.ZipFile(donor.file_path) as dz:
            donor_rescue = {
                n: dz.read(n) for n in dz.namelist()
                if n.startswith(RESCUE_PREFIX) and not n.endswith("/")
            }
    except (zipfile.BadZipFile, OSError, KeyError) as e:
        flash(f"Couldn't read the donor package (v{donor.version}) to copy its rescue component: {e}", "danger")
        return redirect(url_for("releases.detail", package_id=package.public_id))

    if not donor_rescue:
        flash(f"Donor package v{donor.version} has no rescue/ files to copy — nothing to fix against.", "danger")
        return redirect(url_for("releases.detail", package_id=package.public_id))

    supported_os = donor.supported_os_list() or ["windows"]

    try:
        checksum = repair_package(package.file_path, package.version, supported_os, donor_rescue)
    except (zipfile.BadZipFile, OSError) as e:
        flash(f"Fix failed: {e}", "danger")
        return redirect(url_for("releases.detail", package_id=package.public_id))

    file_size = os.path.getsize(package.file_path)
    ok, val_errors, metadata = validate_update_zip(package.file_path, expected_version=package.version)

    package.checksum_sha256 = checksum
    package.file_size = file_size
    package.supported_os = ",".join(metadata.get("supported_os") or [])
    package.status = "validated" if ok else "invalid"
    package.validation_log = "\n".join(val_errors) if val_errors else None
    package.has_rescue_component = metadata.get("has_rescue", False)
    package.file_listing = format_file_listing(metadata)

    log_action(
        None, current_user, "package_fixed",
        f"v{package.version} — added update.json + rescue/ (rescue copied from v{donor.version}) "
        f"({'validated' if ok else 'still invalid'})",
    )
    db.session.commit()

    if ok:
        flash(
            f"Fixed — v{package.version} now has a manifest and a rescue component "
            f"(copied from v{donor.version}) and validated successfully.",
            "success",
        )
    else:
        flash("Added a manifest and rescue component, but other validation errors remain — see below.", "danger")
    return redirect(url_for("releases.detail", package_id=package.public_id))


@bp.route("/<package_id>/delete", methods=["POST"])
@login_required
@platform_admin_required
def delete(package_id):
    """Hard-deletes a package that was never actually deployed anywhere
    (e.g. an accidental upload) — removes the DB row and the file on disk.
    Anything with real deployment history is refused; use Withdraw for that
    instead, which keeps history intact but stops it being pushable."""
    package = UpdatePackage.query.filter_by(public_id=package_id).first()
    if package is None:
        abort(404)

    reason = package.delete_blocking_reason()
    if reason:
        flash(f"Can't delete v{package.version}: {reason}", "danger")
        return redirect(url_for("releases.detail", package_id=package.public_id))

    version = package.version
    file_path = package.file_path
    log_action(None, current_user, "package_deleted", f"v{version}")
    db.session.delete(package)
    db.session.commit()

    try:
        if file_path and os.path.exists(file_path):
            os.remove(file_path)
    except OSError:
        pass  # DB row is gone either way; a stray file on disk isn't worth failing the request over

    flash(f"Package v{version} deleted.", "info")
    return redirect(url_for("releases.list_releases"))
