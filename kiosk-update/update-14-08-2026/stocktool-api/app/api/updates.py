from flask import Blueprint, request, jsonify
from flask_jwt_extended import jwt_required
from app.extensions import db
from app.models import ReleaseVersion
from app.utils.decorators import admin_required
from app.utils.install_auth import install_token_required

api_updates_bp = Blueprint("api_updates", __name__, url_prefix="/api/updates")


@api_updates_bp.route("/latest", methods=["GET"])
@install_token_required
def latest():
    """
    The desktop client's update-check call. Query param `channel`
    defaults to stable. Returns the newest active release on that
    channel — the client compares `version` against its own and decides
    whether to prompt for/perform an update.
    """
    channel = request.args.get("channel", "stable")
    release = (ReleaseVersion.query
               .filter_by(channel=channel, is_active=True)
               .order_by(ReleaseVersion.published_at.desc())
               .first())
    if not release:
        return jsonify({"error": f"No active release on channel '{channel}'."}), 404
    return jsonify(release.to_dict()), 200


@api_updates_bp.route("", methods=["POST"])
@jwt_required()
@admin_required
def publish_release():
    """Admin-only: publish a new release. The desktop client never
    uploads anything here — this is how a new build gets announced."""
    data = request.get_json(silent=True) or {}
    version = (data.get("version") or "").strip()
    download_url = (data.get("download_url") or "").strip()
    checksum_sha256 = (data.get("checksum_sha256") or "").strip()
    channel = (data.get("channel") or "stable").strip()

    errors = []
    if not version:
        errors.append("version is required.")
    if not download_url:
        errors.append("download_url is required.")
    if not checksum_sha256 or len(checksum_sha256) != 64:
        errors.append("checksum_sha256 must be a 64-character SHA-256 hex digest.")
    if ReleaseVersion.query.filter_by(version=version).first():
        errors.append(f"Version '{version}' already exists.")
    if errors:
        return jsonify({"error": " ".join(errors)}), 400

    release = ReleaseVersion(
        version=version, channel=channel, download_url=download_url,
        checksum_sha256=checksum_sha256,
        release_notes=data.get("release_notes"),
        min_supported_version=data.get("min_supported_version"),
    )
    db.session.add(release)
    db.session.commit()
    return jsonify(release.to_dict()), 201
