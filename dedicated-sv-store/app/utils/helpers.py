from flask import request
from flask_login import current_user

from app.extensions import db
from app.models.audit import AuditLog


def client_ip():
    if request.headers.get("X-Forwarded-For"):
        return request.headers["X-Forwarded-For"].split(",")[0].strip()
    return request.remote_addr


def log_audit(action, object_type, object_id=None, old_value=None, new_value=None, reason=None):
    entry = AuditLog(
        user_id=current_user.id if current_user.is_authenticated else None,
        action=action,
        object_type=object_type,
        object_id=str(object_id) if object_id is not None else None,
        old_value=old_value,
        new_value=new_value,
        reason=reason,
        ip_address=client_ip(),
    )
    db.session.add(entry)
    return entry


def generate_unique_slug(model, base_value, slug_field="slug"):
    from slugify import slugify

    base_slug = slugify(base_value)[:240] or "item"
    slug = base_slug
    counter = 2
    while model.query.filter(getattr(model, slug_field) == slug).first() is not None:
        slug = f"{base_slug}-{counter}"
        counter += 1
    return slug


def paginate_query(query, page, per_page, max_per_page=100):
    per_page = min(per_page or 25, max_per_page)
    return query.paginate(page=page or 1, per_page=per_page, error_out=False)


def format_hardware_value(value):
    if value is None:
        return "—"
    if isinstance(value, bool):
        return "Yes" if value else "No"
    if hasattr(value, "value") and hasattr(value, "name"):
        return str(value.value).replace("_", " ").title()
    return value
