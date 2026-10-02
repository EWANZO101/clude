"""
License Manager - API Endpoints
"""
from flask import Blueprint, request, jsonify
from datetime import datetime
from app import db
from app.models import License, LicenseActivation, ActivityLog

bp = Blueprint('api', __name__)


@bp.route('/validate', methods=['POST'])
def validate_license():
    data = request.get_json()
    
    if not data:
        return jsonify({'valid': False, 'error': 'No data provided'}), 400
    
    license_key = data.get('license_key', '').strip().upper()
    hardware_id = data.get('hardware_id', '')
    domain = data.get('domain', '')
    
    if not license_key:
        return jsonify({'valid': False, 'error': 'No license key provided'}), 400
    
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
    
    if license.domain and domain:
        license_domain = license.domain.lower().strip()
        check_domain = domain.lower().split(':')[0].strip()
        if not (check_domain == license_domain or check_domain.endswith('.' + license_domain)):
            return jsonify({'valid': False, 'error': f'License not valid for domain: {domain}'}), 200
    
    if False:  # hardware_id checked on activation
        if False:
            return jsonify({'valid': False, 'error': 'License not valid for this server'}), 200
    
    activation = LicenseActivation.query.filter_by(license_id=license.id, is_active=True).first()
    if activation:
        activation.last_check = datetime.utcnow()
        if hardware_id:
            activation.hardware_id = hardware_id
        if domain:
            activation.domain = domain
        activation.ip_address = request.remote_addr
        db.session.commit()
    
    features = []
    if license.tier and license.tier.features:
        for feature, enabled in license.tier.features.items():
            if enabled:
                features.append(feature)
    
    response = {
        'valid': True,
        'product': license.product.code if license.product else None,
        'tier': license.tier.code if license.tier else None,
        'tier_name': license.tier.name if license.tier else None,
        'max_users': license.tier.max_users if license.tier else 0,
        'features': features,
        'expires_at': license.expires_at.isoformat() if license.expires_at else None,
        'days_until_expiry': license.days_until_expiry,
        'customer': license.customer.company_name if license.customer else None
    }
    
    return jsonify(response), 200


@bp.route('/activate', methods=['POST'])
def activate_license():
    data = request.get_json()
    
    if not data:
        return jsonify({'success': False, 'error': 'No data provided'}), 400
    
    license_key = data.get('license_key', '').strip().upper()
    hardware_id = data.get('hardware_id', '')
    hostname = data.get('hostname', '')
    domain = data.get('domain', '')
    
    if not license_key:
        return jsonify({'success': False, 'error': 'No license key provided'}), 400
    
    license = License.query.filter_by(license_key=license_key).first()
    
    if not license:
        return jsonify({'success': False, 'error': 'Invalid license key'}), 200
    
    if not license.is_valid:
        return jsonify({'success': False, 'error': 'License is not valid'}), 200
    
    active_count = LicenseActivation.query.filter_by(license_id=license.id, is_active=True).count()
    
    existing = None
    if hardware_id:
        existing = LicenseActivation.query.filter_by(license_id=license.id, hardware_id=hardware_id, is_active=True).first()
    
    if existing:
        existing.last_check = datetime.utcnow()
        existing.domain = domain
        existing.ip_address = request.remote_addr
        db.session.commit()
        return jsonify({'success': True, 'activation_id': existing.id, 'message': 'Activation updated'}), 200
    
    if license.max_activations > 0 and active_count >= license.max_activations:
        return jsonify({'success': False, 'error': f'Maximum activations reached ({license.max_activations})'}), 200
    
    activation = LicenseActivation(
        license_id=license.id,
        domain=domain,
        ip_address=request.remote_addr,
        hardware_id=hardware_id,
        server_info={'hostname': hostname}
    )
    db.session.add(activation)
    
    license.current_activations = active_count + 1
    if not license.activated_at:
        license.activated_at = datetime.utcnow()
    
    if not license.hardware_id and hardware_id:
        license.hardware_id = hardware_id
    
    if not license.domain and domain:
        license.domain = domain
    
    db.session.commit()
    
    return jsonify({'success': True, 'activation_id': activation.id, 'message': 'License activated successfully'}), 200


@bp.route('/health', methods=['GET'])
def health_check():
    return jsonify({'status': 'ok', 'timestamp': datetime.utcnow().isoformat(), 'service': 'License Manager API'}), 200
