"""
License Manager - API Routes for License Validation + Management
"""
from flask import Blueprint, request, jsonify
from datetime import datetime
from functools import wraps
from app import db
from app.models import (
    License, LicenseActivation, LicenseIPHistory,
    Customer, Product, ProductTier, AdminUser,
    Role, Permission, Feature, ActivityLog, Settings
)

bp = Blueprint('api', __name__)


# ==================== API KEY AUTH ====================

def require_api_key(f):
    """Decorator — requires X-API-Key header matching the stored admin API key."""
    @wraps(f)
    def decorated(*args, **kwargs):
        key = request.headers.get('X-API-Key', '').strip()
        stored = Settings.get('admin_api_key', '')
        if not stored:
            return jsonify({'error': 'Admin API not enabled. Set admin_api_key in Settings.'}), 403
        if not key or key != stored:
            return jsonify({'error': 'Invalid or missing API key. Pass X-API-Key header.'}), 401
        return f(*args, **kwargs)
    return decorated

bp = Blueprint('api', __name__)


@bp.route('/validate', methods=['POST'])
def validate_license():
    """Validate a license key and auto-register IP"""
    data = request.get_json() or {}
    license_key = data.get('license_key', '').upper().strip()
    domain = data.get('domain', '')
    hardware_id = data.get('hardware_id', '')
    client_ip = request.headers.get('X-Forwarded-For', request.remote_addr).split(',')[0].strip()
    
    if not license_key:
        return jsonify({'valid': False, 'error': 'No license key provided'}), 200
    
    license = License.query.filter_by(license_key=license_key).first()
    
    if not license:
        return jsonify({'valid': False, 'error': 'Invalid license key'}), 200
    
    if license.status == 'revoked':
        return jsonify({'valid': False, 'error': 'License has been revoked'}), 200
    
    if license.status == 'suspended':
        return jsonify({'valid': False, 'error': 'License has been suspended'}), 200
    
    if license.status != 'active':
        return jsonify({'valid': False, 'error': f'License status: {license.status}'}), 200
    
    if license.is_expired:
        return jsonify({'valid': False, 'error': 'License has expired'}), 200
    
    # Check domain lock
    if license.domain and domain:
        if not domain.lower().endswith(license.domain.lower()):
            return jsonify({'valid': False, 'error': 'License not valid for this domain'}), 200
    
    # Handle IP lock
    if license.product.require_ip_lock:
        if not license.allowed_ips:
            # First use - auto-register this IP
            license.allowed_ips = [client_ip]
            license.last_ip_change = datetime.utcnow()
            
            # Log IP history
            history = LicenseIPHistory(
                license_id=license.id,
                ip_address=client_ip,
                action='auto_registered',
                changed_by='api'
            )
            db.session.add(history)
            db.session.commit()
        elif client_ip not in license.allowed_ips:
            return jsonify({
                'valid': False,
                'error': f'License not authorized for IP: {client_ip}',
                'error_code': 'IP_MISMATCH',
                'your_ip': client_ip,
                'allowed_ips': license.allowed_ips
            }), 200
    
    # Update or create activation record
    activation = LicenseActivation.query.filter_by(
        license_id=license.id,
        is_active=True
    ).first()
    
    if activation:
        activation.last_check = datetime.utcnow()
        activation.ip_address = client_ip
    else:
        # Create activation if under limit
        active_count = LicenseActivation.query.filter_by(license_id=license.id, is_active=True).count()
        if active_count < license.max_activations:
            activation = LicenseActivation(
                license_id=license.id,
                domain=domain,
                ip_address=client_ip,
                hardware_id=hardware_id
            )
            db.session.add(activation)
            license.current_activations = active_count + 1
            if not license.activated_at:
                license.activated_at = datetime.utcnow()
    
    db.session.commit()
    
    # Build features list — license-level features take priority, fall back to tier
    features = license.get_features()
    
    return jsonify({
        'valid': True,
        'product': license.product.code,
        'tier': license.tier.code,
        'tier_name': license.tier.name,
        'max_users': license.tier.max_users,
        'features': features,
        'expires_at': license.expires_at.isoformat() if license.expires_at else None,
        'days_until_expiry': license.days_until_expiry,
        'customer': license.customer.company_name if license.customer else None,
        'your_ip': client_ip,
        'allowed_ips': license.allowed_ips
    }), 200


@bp.route('/activate', methods=['POST'])
def activate_license():
    """Activate a license on a server"""
    data = request.get_json() or {}
    license_key = data.get('license_key', '').upper().strip()
    domain = data.get('domain', '')
    hardware_id = data.get('hardware_id', '')
    hostname = data.get('hostname', '')
    client_ip = request.headers.get('X-Forwarded-For', request.remote_addr).split(',')[0].strip()
    
    if not license_key:
        return jsonify({'success': False, 'error': 'No license key provided'}), 200
    
    license = License.query.filter_by(license_key=license_key).first()
    
    if not license:
        return jsonify({'success': False, 'error': 'Invalid license key'}), 200
    
    if not license.is_valid:
        return jsonify({'success': False, 'error': f'License is {license.status}'}), 200
    
    # Handle IP lock - auto-register on first activation
    if license.product.require_ip_lock:
        if not license.allowed_ips:
            # First activation - register this IP
            license.allowed_ips = [client_ip]
            license.last_ip_change = datetime.utcnow()
            
            history = LicenseIPHistory(
                license_id=license.id,
                ip_address=client_ip,
                action='auto_registered',
                changed_by='api'
            )
            db.session.add(history)
        elif client_ip not in license.allowed_ips:
            # Check if we can add more IPs
            if len(license.allowed_ips) < license.product.max_ip_addresses:
                license.allowed_ips = license.allowed_ips + [client_ip]
                license.last_ip_change = datetime.utcnow()
                
                history = LicenseIPHistory(
                    license_id=license.id,
                    ip_address=client_ip,
                    action='auto_added',
                    changed_by='api'
                )
                db.session.add(history)
            else:
                return jsonify({
                    'success': False,
                    'error': f'License not authorized for IP: {client_ip}. Max IPs ({license.product.max_ip_addresses}) reached.',
                    'error_code': 'IP_MISMATCH',
                    'your_ip': client_ip,
                    'allowed_ips': license.allowed_ips
                }), 200
    
    # Check existing activation for this hardware/domain
    existing = None
    if hardware_id:
        existing = LicenseActivation.query.filter_by(
            license_id=license.id,
            hardware_id=hardware_id,
            is_active=True
        ).first()
    
    if existing:
        existing.last_check = datetime.utcnow()
        existing.ip_address = client_ip
        existing.domain = domain
        existing.hostname = hostname if hasattr(existing, 'hostname') else None
        db.session.commit()
        
        return jsonify({
            'success': True,
            'message': 'Activation updated',
            'license': license.to_dict(),
            'your_ip': client_ip,
            'allowed_ips': license.allowed_ips
        }), 200
    
    # Check max activations
    active_count = LicenseActivation.query.filter_by(license_id=license.id, is_active=True).count()
    if license.max_activations > 0 and active_count >= license.max_activations:
        return jsonify({
            'success': False,
            'error': f'Maximum activations reached ({license.max_activations})',
            'error_code': 'MAX_ACTIVATIONS'
        }), 200
    
    # Create new activation
    activation = LicenseActivation(
        license_id=license.id,
        domain=domain,
        ip_address=client_ip,
        hardware_id=hardware_id,
        server_info={'hostname': hostname}
    )
    db.session.add(activation)
    
    license.current_activations = active_count + 1
    if not license.activated_at:
        license.activated_at = datetime.utcnow()
    
    db.session.commit()
    
    return jsonify({
        'success': True,
        'message': 'License activated',
        'license': license.to_dict(),
        'activation_id': activation.id,
        'your_ip': client_ip,
        'allowed_ips': license.allowed_ips
    }), 200


@bp.route('/deactivate', methods=['POST'])
def deactivate_license():
    """Deactivate a license"""
    data = request.get_json() or {}
    license_key = data.get('license_key', '').upper().strip()
    activation_id = data.get('activation_id')
    
    if not license_key:
        return jsonify({'success': False, 'error': 'No license key provided'}), 200
    
    license = License.query.filter_by(license_key=license_key).first()
    
    if not license:
        return jsonify({'success': False, 'error': 'Invalid license key'}), 200
    
    if activation_id:
        activation = LicenseActivation.query.filter_by(
            id=activation_id,
            license_id=license.id,
            is_active=True
        ).first()
    else:
        activation = LicenseActivation.query.filter_by(
            license_id=license.id,
            is_active=True
        ).order_by(LicenseActivation.activated_at.desc()).first()
    
    if activation:
        activation.is_active = False
        activation.deactivated_at = datetime.utcnow()
        license.current_activations = max(0, license.current_activations - 1)
        db.session.commit()
        
        return jsonify({'success': True, 'message': 'License deactivated'}), 200
    
    return jsonify({'success': False, 'error': 'No active activation found'}), 200


@bp.route('/heartbeat', methods=['POST'])
def heartbeat():
    """Periodic heartbeat check"""
    data = request.get_json() or {}
    license_key = data.get('license_key', '').upper().strip()
    activation_id = data.get('activation_id')
    client_ip = request.headers.get('X-Forwarded-For', request.remote_addr).split(',')[0].strip()
    
    if not license_key:
        return jsonify({'valid': False, 'error': 'No license key'}), 200
    
    license = License.query.filter_by(license_key=license_key).first()
    
    if not license or not license.is_valid:
        return jsonify({'valid': False, 'error': 'License invalid or expired'}), 200
    
    # Check IP
    if license.product.require_ip_lock and license.allowed_ips:
        if client_ip not in license.allowed_ips:
            return jsonify({
                'valid': False,
                'error': f'IP {client_ip} not authorized',
                'your_ip': client_ip
            }), 200
    
    # Update activation
    if activation_id:
        activation = LicenseActivation.query.filter_by(
            id=activation_id,
            license_id=license.id,
            is_active=True
        ).first()
        
        if activation:
            activation.last_check = datetime.utcnow()
            activation.ip_address = client_ip
            db.session.commit()
    
    return jsonify({
        'valid': True,
        'license': license.to_dict(),
        'your_ip': client_ip
    }), 200


@bp.route('/info/<license_key>')
def license_info(license_key):
    """Get public license info"""
    license = License.query.filter_by(license_key=license_key.upper()).first()
    
    if not license:
        return jsonify({'error': 'License not found'}), 404
    
    return jsonify({
        'valid': license.is_valid,
        'status': license.status,
        'tier': license.tier.name if license.tier else None,
        'expires_at': license.expires_at.isoformat() if license.expires_at else None
    }), 200


@bp.route('/my-ip', methods=['GET'])
def my_ip():
    """Return client's IP"""
    client_ip = request.headers.get('X-Forwarded-For', request.remote_addr).split(',')[0].strip()
    return jsonify({'ip': client_ip}), 200


@bp.route('/health', methods=['GET'])
def health_check():
    """Health check"""
    return jsonify({'status': 'ok', 'timestamp': datetime.utcnow().isoformat()}), 200


# ==================== MANAGEMENT API ====================
# All routes below require X-API-Key header.

# ── Dashboard ──────────────────────────────────────────

@bp.route('/admin/dashboard', methods=['GET'])
@require_api_key
def admin_dashboard():
    """Dashboard stats summary"""
    from datetime import timedelta
    total_licenses   = License.query.count()
    active_licenses  = License.query.filter_by(status='active').count()
    suspended        = License.query.filter_by(status='suspended').count()
    revoked          = License.query.filter_by(status='revoked').count()
    total_customers  = Customer.query.count()
    total_products   = Product.query.count()
    expiring_soon    = License.query.filter(
        License.status == 'active',
        License.expires_at != None,
        License.expires_at <= datetime.utcnow() + timedelta(days=30),
        License.expires_at > datetime.utcnow()
    ).count()
    recent_logs = ActivityLog.query.order_by(ActivityLog.created_at.desc()).limit(5).all()
    return jsonify({
        'licenses': {
            'total': total_licenses,
            'active': active_licenses,
            'suspended': suspended,
            'revoked': revoked,
            'expiring_soon_30d': expiring_soon,
        },
        'customers': {'total': total_customers},
        'products':  {'total': total_products},
        'recent_activity': [
            {'action': l.action, 'entity_type': l.entity_type,
             'entity_id': l.entity_id, 'at': l.created_at.isoformat()}
            for l in recent_logs
        ]
    }), 200


# ── Licences ───────────────────────────────────────────

@bp.route('/admin/licenses', methods=['GET'])
@require_api_key
def admin_list_licenses():
    """List all licences with optional filters.
    Query params: status, customer_id, product_id, page, per_page"""
    page     = request.args.get('page', 1, type=int)
    per_page = min(request.args.get('per_page', 25, type=int), 100)
    status   = request.args.get('status')
    cid      = request.args.get('customer_id', type=int)
    pid      = request.args.get('product_id', type=int)

    q = License.query
    if status:
        q = q.filter_by(status=status)
    if cid:
        q = q.filter_by(customer_id=cid)
    if pid:
        q = q.filter_by(product_id=pid)

    total = q.count()
    items = q.order_by(License.created_at.desc()).offset((page - 1) * per_page).limit(per_page).all()

    return jsonify({
        'total': total, 'page': page, 'per_page': per_page,
        'licenses': [l.to_dict() for l in items]
    }), 200


@bp.route('/admin/licenses/<int:lid>', methods=['GET'])
@require_api_key
def admin_get_license(lid):
    """Get a single licence by ID"""
    lic = License.query.get_or_404(lid)
    data = lic.to_dict()
    data['activations'] = [
        {'id': a.id, 'domain': a.domain, 'ip': a.ip_address,
         'hardware_id': a.hardware_id, 'activated_at': a.activated_at.isoformat(),
         'last_check': a.last_check.isoformat() if a.last_check else None,
         'is_active': a.is_active}
        for a in lic.activations.all()
    ]
    return jsonify(data), 200


@bp.route('/admin/licenses/<int:lid>/status', methods=['PATCH'])
@require_api_key
def admin_set_license_status(lid):
    """Change licence status. Body: {"status": "active"|"suspended"|"revoked"}"""
    lic = License.query.get_or_404(lid)
    data = request.get_json() or {}
    new_status = data.get('status', '').lower()
    if new_status not in ('active', 'suspended', 'revoked'):
        return jsonify({'error': 'status must be active, suspended or revoked'}), 400
    lic.status = new_status
    db.session.commit()
    return jsonify({'success': True, 'license_key': lic.license_key, 'status': lic.status}), 200


@bp.route('/admin/licenses/<int:lid>/features', methods=['GET'])
@require_api_key
def admin_get_license_features(lid):
    """Get features assigned to a licence"""
    lic = License.query.get_or_404(lid)
    return jsonify({
        'license_key': lic.license_key,
        'features': [{'id': f.id, 'code': f.code, 'name': f.name, 'category': f.category}
                     for f in lic.features],
        'effective_features': lic.get_features()
    }), 200


@bp.route('/admin/licenses/<int:lid>/features', methods=['PUT'])
@require_api_key
def admin_set_license_features(lid):
    """Replace all features on a licence. Body: {"feature_ids": [1,2,3]}"""
    lic = License.query.get_or_404(lid)
    data = request.get_json() or {}
    ids = data.get('feature_ids', [])
    lic.features = Feature.query.filter(Feature.id.in_(ids)).all() if ids else []
    db.session.commit()
    return jsonify({'success': True, 'effective_features': lic.get_features()}), 200


# ── Customers ──────────────────────────────────────────

@bp.route('/admin/customers', methods=['GET'])
@require_api_key
def admin_list_customers():
    """List customers. Query params: page, per_page, active"""
    page     = request.args.get('page', 1, type=int)
    per_page = min(request.args.get('per_page', 25, type=int), 100)
    active   = request.args.get('active')

    q = Customer.query
    if active is not None:
        q = q.filter_by(is_active=(active.lower() == 'true'))

    total = q.count()
    items = q.order_by(Customer.company_name).offset((page - 1) * per_page).limit(per_page).all()

    return jsonify({
        'total': total, 'page': page, 'per_page': per_page,
        'customers': [{
            'id': c.id, 'email': c.email,
            'company_name': c.company_name, 'contact_name': c.contact_name,
            'phone': c.phone, 'is_active': c.is_active,
            'created_at': c.created_at.isoformat(),
            'license_count': c.licenses.count()
        } for c in items]
    }), 200


@bp.route('/admin/customers/<int:cid>', methods=['GET'])
@require_api_key
def admin_get_customer(cid):
    """Get a single customer with their licences"""
    c = Customer.query.get_or_404(cid)
    return jsonify({
        'id': c.id, 'email': c.email,
        'company_name': c.company_name, 'contact_name': c.contact_name,
        'phone': c.phone, 'address': c.address, 'notes': c.notes,
        'is_active': c.is_active, 'created_at': c.created_at.isoformat(),
        'licenses': [l.to_dict() for l in c.licenses.all()]
    }), 200


@bp.route('/admin/customers', methods=['POST'])
@require_api_key
def admin_create_customer():
    """Create a new customer.
    Body: {email, company_name, contact_name, phone, address, notes}"""
    data = request.get_json() or {}
    email = (data.get('email') or '').strip().lower()
    if not email:
        return jsonify({'error': 'email is required'}), 400
    if Customer.query.filter_by(email=email).first():
        return jsonify({'error': 'email already exists'}), 409
    c = Customer(
        email=email,
        company_name=data.get('company_name', '').strip(),
        contact_name=data.get('contact_name', '').strip(),
        phone=data.get('phone', '').strip(),
        address=data.get('address', '').strip(),
        notes=data.get('notes', '').strip(),
    )
    db.session.add(c)
    db.session.commit()
    return jsonify({'success': True, 'id': c.id, 'email': c.email}), 201


@bp.route('/admin/customers/<int:cid>', methods=['PATCH'])
@require_api_key
def admin_update_customer(cid):
    """Update customer fields. Send only the fields you want to change."""
    c = Customer.query.get_or_404(cid)
    data = request.get_json() or {}
    for field in ('company_name', 'contact_name', 'phone', 'address', 'notes'):
        if field in data:
            setattr(c, field, data[field])
    if 'is_active' in data:
        c.is_active = bool(data['is_active'])
    db.session.commit()
    return jsonify({'success': True, 'id': c.id}), 200


# ── Products ───────────────────────────────────────────

@bp.route('/admin/products', methods=['GET'])
@require_api_key
def admin_list_products():
    """List all products with their tiers"""
    products = Product.query.order_by(Product.name).all()
    return jsonify({
        'products': [{
            'id': p.id, 'name': p.name, 'code': p.code,
            'description': p.description, 'is_active': p.is_active,
            'require_ip_lock': p.require_ip_lock,
            'max_ip_addresses': p.max_ip_addresses,
            'license_count': p.licenses.count(),
            'tiers': [{
                'id': t.id, 'name': t.name, 'code': t.code,
                'price_monthly': t.price_monthly, 'price_yearly': t.price_yearly,
                'max_users': t.max_users, 'features': t.features,
                'is_active': t.is_active
            } for t in p.tiers.filter_by(is_active=True).all()]
        } for p in products]
    }), 200


@bp.route('/admin/products/<int:pid>', methods=['GET'])
@require_api_key
def admin_get_product(pid):
    """Get a single product with full tier details"""
    p = Product.query.get_or_404(pid)
    return jsonify({
        'id': p.id, 'name': p.name, 'code': p.code,
        'description': p.description, 'is_active': p.is_active,
        'require_ip_lock': p.require_ip_lock,
        'max_ip_addresses': p.max_ip_addresses,
        'allow_ip_change': p.allow_ip_change,
        'ip_change_cooldown': p.ip_change_cooldown,
        'tiers': [{
            'id': t.id, 'name': t.name, 'code': t.code,
            'description': t.description,
            'price_monthly': t.price_monthly, 'price_yearly': t.price_yearly,
            'max_users': t.max_users, 'features': t.features,
            'sort_order': t.sort_order, 'is_active': t.is_active
        } for t in p.tiers.order_by(ProductTier.sort_order).all()]
    }), 200


# ── Features ───────────────────────────────────────────

@bp.route('/admin/features', methods=['GET'])
@require_api_key
def admin_list_features():
    """List all features, optionally filtered by active status.
    Query params: active=true|false"""
    active = request.args.get('active')
    q = Feature.query
    if active is not None:
        q = q.filter_by(is_active=(active.lower() == 'true'))
    features = q.order_by(Feature.category, Feature.name).all()
    return jsonify({
        'features': [{
            'id': f.id, 'code': f.code, 'name': f.name,
            'description': f.description, 'category': f.category,
            'icon': f.icon, 'is_active': f.is_active,
            'created_at': f.created_at.isoformat()
        } for f in features]
    }), 200


@bp.route('/admin/features', methods=['POST'])
@require_api_key
def admin_create_feature():
    """Create a new feature.
    Body: {code, name, description, category, icon}"""
    data = request.get_json() or {}
    code = data.get('code', '').strip().lower().replace(' ', '_')
    name = data.get('name', '').strip()
    if not code or not name:
        return jsonify({'error': 'code and name are required'}), 400
    if Feature.query.filter_by(code=code).first():
        return jsonify({'error': f'Feature code "{code}" already exists'}), 409
    f = Feature(
        code=code, name=name,
        description=data.get('description', ''),
        category=data.get('category', 'general'),
        icon=data.get('icon', 'puzzle')
    )
    db.session.add(f)
    db.session.commit()
    return jsonify({'success': True, 'id': f.id, 'code': f.code}), 201


@bp.route('/admin/features/<int:fid>', methods=['PATCH'])
@require_api_key
def admin_update_feature(fid):
    """Update a feature. Send only the fields you want to change."""
    feat = Feature.query.get_or_404(fid)
    data = request.get_json() or {}
    for field in ('name', 'description', 'category', 'icon'):
        if field in data:
            setattr(feat, field, data[field])
    if 'is_active' in data:
        feat.is_active = bool(data['is_active'])
    db.session.commit()
    return jsonify({'success': True, 'id': feat.id, 'code': feat.code}), 200


@bp.route('/admin/features/<int:fid>', methods=['DELETE'])
@require_api_key
def admin_delete_feature(fid):
    """Delete a feature"""
    feat = Feature.query.get_or_404(fid)
    db.session.delete(feat)
    db.session.commit()
    return jsonify({'success': True}), 200


# ── Roles ──────────────────────────────────────────────

@bp.route('/admin/roles', methods=['GET'])
@require_api_key
def admin_list_roles():
    """List all roles with their permissions"""
    roles = Role.query.order_by(Role.name).all()
    return jsonify({
        'roles': [{
            'id': r.id, 'name': r.name, 'description': r.description,
            'color': r.color, 'is_system': r.is_system,
            'user_count': len(r.users),
            'permissions': [{'code': p.code, 'name': p.name} for p in r.permissions]
        } for r in roles]
    }), 200


@bp.route('/admin/roles/<int:rid>', methods=['GET'])
@require_api_key
def admin_get_role(rid):
    """Get a single role"""
    r = Role.query.get_or_404(rid)
    return jsonify({
        'id': r.id, 'name': r.name, 'description': r.description,
        'color': r.color, 'is_system': r.is_system,
        'users': [{'id': u.id, 'name': u.name, 'email': u.email} for u in r.users],
        'permissions': [{'code': p.code, 'name': p.name, 'category': p.category}
                        for p in r.permissions]
    }), 200


# ── Admin Users ────────────────────────────────────────

@bp.route('/admin/users', methods=['GET'])
@require_api_key
def admin_list_users():
    """List all admin users"""
    users = AdminUser.query.order_by(AdminUser.name).all()
    return jsonify({
        'users': [{
            'id': u.id, 'name': u.name, 'email': u.email,
            'is_superadmin': u.is_superadmin, 'is_active': u.is_active,
            'created_at': u.created_at.isoformat(),
            'last_login': u.last_login.isoformat() if u.last_login else None,
            'roles': [{'id': r.id, 'name': r.name} for r in u.roles]
        } for u in users]
    }), 200


# ── Activity Log ───────────────────────────────────────

@bp.route('/admin/activity', methods=['GET'])
@require_api_key
def admin_activity_log():
    """List activity log entries.
    Query params: page, per_page, entity_type, action"""
    page        = request.args.get('page', 1, type=int)
    per_page    = min(request.args.get('per_page', 50, type=int), 200)
    entity_type = request.args.get('entity_type')
    action      = request.args.get('action')

    q = ActivityLog.query
    if entity_type:
        q = q.filter_by(entity_type=entity_type)
    if action:
        q = q.filter(ActivityLog.action.ilike(f'%{action}%'))

    total = q.count()
    items = q.order_by(ActivityLog.created_at.desc()).offset((page - 1) * per_page).limit(per_page).all()

    return jsonify({
        'total': total, 'page': page, 'per_page': per_page,
        'logs': [{
            'id': l.id,
            'action': l.action,
            'entity_type': l.entity_type,
            'entity_id': l.entity_id,
            'details': l.details,
            'ip_address': l.ip_address,
            'admin': l.admin.name if l.admin else None,
            'created_at': l.created_at.isoformat()
        } for l in items]
    }), 200
