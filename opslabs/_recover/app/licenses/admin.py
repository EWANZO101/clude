"""
License Manager - Admin Routes
"""
from flask import Blueprint, render_template, redirect, url_for, flash, request, jsonify
from flask_login import login_required, current_user
from datetime import datetime, timedelta
from .. import db   # shared with OpsLabs
from .models import (
    AdminUser, Settings, Role, Permission,
    License, Customer, Product, ProductTier, 
    LicenseActivation, ActivityLog, Feature
)

bp = Blueprint('lic_admin', __name__)


def log_activity(action, entity_type=None, entity_id=None, details=None):
    """Log admin activity"""
    log = ActivityLog(
        admin_id=current_user.id,
        action=action,
        entity_type=entity_type,
        entity_id=entity_id,
        details=details,
        ip_address=request.remote_addr
    )
    db.session.add(log)
    db.session.commit()


# ==================== DASHBOARD ====================

@bp.route('/')
@login_required
def dashboard():
    """Admin dashboard"""
    # Stats
    total_licenses = License.query.count()
    active_licenses = License.query.filter_by(status='active').count()
    total_customers = Customer.query.count()
    
    # Recent activity
    recent_licenses = License.query.order_by(License.created_at.desc()).limit(5).all()
    recent_activations = LicenseActivation.query.order_by(
        LicenseActivation.activated_at.desc()
    ).limit(10).all()
    
    # Expiring soon (30 days)
    expiring_soon = License.query.filter(
        License.status == 'active',
        License.expires_at != None,
        License.expires_at <= datetime.utcnow() + timedelta(days=30),
        License.expires_at > datetime.utcnow()
    ).count()
    
    # Revenue (simple calculation)
    # In production, you'd track actual payments
    
    return render_template('admin/dashboard.html',
        total_licenses=total_licenses,
        active_licenses=active_licenses,
        total_customers=total_customers,
        expiring_soon=expiring_soon,
        recent_licenses=recent_licenses,
        recent_activations=recent_activations
    )


# ==================== LICENSES ====================

@bp.route('/licenses')
@login_required
def licenses():
    """List all licenses"""
    page = request.args.get('page', 1, type=int)
    status = request.args.get('status', 'all')
    search = request.args.get('search', '')
    
    query = License.query
    
    if status != 'all':
        query = query.filter_by(status=status)
    
    if search:
        query = query.filter(
            (License.license_key.ilike(f'%{search}%')) |
            (License.domain.ilike(f'%{search}%'))
        )
    
    licenses = query.order_by(License.created_at.desc()).paginate(page=page, per_page=20)
    
    # Counts
    counts = {
        'all': License.query.count(),
        'active': License.query.filter_by(status='active').count(),
        'suspended': License.query.filter_by(status='suspended').count(),
        'revoked': License.query.filter_by(status='revoked').count(),
        'expired': License.query.filter(
            License.expires_at < datetime.utcnow()
        ).count()
    }
    
    return render_template('admin/licenses.html',
        licenses=licenses,
        counts=counts,
        current_status=status,
        search=search
    )


@bp.route('/licenses/create', methods=['GET', 'POST'])
@login_required
def create_license():
    """Create a new license"""
    products = Product.query.filter_by(is_active=True).all()
    tiers = ProductTier.query.filter_by(is_active=True).all()
    customers = Customer.query.filter_by(is_active=True).order_by(Customer.company_name).all()
    all_features = Feature.query.filter_by(is_active=True).order_by(
        Feature.category, Feature.name).all()

    if request.method == 'POST':
        # Generate unique key
        while True:
            license_key = License.generate_key()
            if not License.query.filter_by(license_key=license_key).first():
                break

        # Calculate expiration
        duration = request.form.get('duration')
        expires_at = None
        if duration == 'monthly':
            expires_at = datetime.utcnow() + timedelta(days=30)
        elif duration == 'yearly':
            expires_at = datetime.utcnow() + timedelta(days=365)
        elif duration == 'custom':
            custom_date = request.form.get('custom_expiry')
            if custom_date:
                expires_at = datetime.strptime(custom_date, '%Y-%m-%d')

        license = License(
            license_key=license_key,
            product_id=request.form.get('product_id'),
            tier_id=request.form.get('tier_id'),
            customer_id=request.form.get('customer_id') or None,
            max_activations=request.form.get('max_activations', 1, type=int),
            expires_at=expires_at,
            domain=request.form.get('domain') or None,
            notes=request.form.get('notes'),
            created_by=current_user.id
        )

        db.session.add(license)
        db.session.flush()

        # Attach selected features
        selected_ids = set(int(x) for x in request.form.getlist('feature_ids'))
        if selected_ids:
            license.features = Feature.query.filter(Feature.id.in_(selected_ids)).all()

        db.session.commit()
        log_activity('create_license', 'license', license.id, f'Created license {license_key}')
        flash(f'License created: {license_key}', 'success')
        return redirect(url_for('lic_admin.view_license', id=license.id))

    # Group by product_group -> category
    grouped_features = {}
    for f in all_features:
        pg = grouped_features.setdefault('General', {})
        pg.setdefault(f.category or 'General', []).append(f)

    return render_template('admin/create_license.html',
        products=products,
        tiers=tiers,
        customers=customers,
        grouped_features=grouped_features
    )


@bp.route('/licenses/<int:id>')
@login_required
def view_license(id):
    """View license details"""
    license = License.query.get_or_404(id)
    activations = license.activations.order_by(LicenseActivation.activated_at.desc()).all()
    
    return render_template('admin/view_license.html',
        license=license,
        activations=activations
    )


@bp.route('/licenses/<int:id>/edit', methods=['GET', 'POST'])
@login_required
def edit_license(id):
    """Edit license"""
    license = License.query.get_or_404(id)
    tiers = ProductTier.query.filter_by(product_id=license.product_id, is_active=True).all()
    customers = Customer.query.filter_by(is_active=True).order_by(Customer.company_name).all()
    all_features = Feature.query.filter_by(is_active=True).order_by(Feature.category, Feature.name).all()

    if request.method == 'POST':
        license.tier_id = request.form.get('tier_id')
        license.customer_id = request.form.get('customer_id') or None
        license.max_activations = request.form.get('max_activations', 1, type=int)
        license.domain = request.form.get('domain') or None
        license.notes = request.form.get('notes')

        # Update expiry
        expiry_date = request.form.get('expires_at')
        if expiry_date:
            license.expires_at = datetime.strptime(expiry_date, '%Y-%m-%d')
        else:
            license.expires_at = None

        # Update license-level features
        selected_ids = set(int(x) for x in request.form.getlist('feature_ids'))
        license.features = Feature.query.filter(Feature.id.in_(selected_ids)).all() if selected_ids else []

        db.session.commit()

        log_activity('edit_license', 'license', license.id, f'Updated license {license.license_key}')

        flash('License updated', 'success')
        return redirect(url_for('lic_admin.view_license', id=license.id))

    grouped_features = {}
    for f in all_features:
        pg = grouped_features.setdefault('General', {})
        pg.setdefault(f.category or 'General', []).append(f)

    license_feature_ids = {f.id for f in license.features}

    return render_template('admin/edit_license.html',
        license=license,
        tiers=tiers,
        customers=customers,
        grouped_features=grouped_features,
        license_feature_ids=license_feature_ids
    )


@bp.route('/licenses/<int:id>/status', methods=['POST'])
@login_required
def change_license_status(id):
    """Change license status"""
    license = License.query.get_or_404(id)
    new_status = request.form.get('status')
    
    if new_status in ['active', 'suspended', 'revoked']:
        old_status = license.status
        license.status = new_status
        db.session.commit()
        
        log_activity('change_status', 'license', license.id, 
            f'Changed status from {old_status} to {new_status}')
        
        flash(f'License status changed to {new_status}', 'success')
    
    return redirect(url_for('lic_admin.view_license', id=license.id))


@bp.route('/licenses/<int:id>/extend', methods=['POST'])
@login_required
def extend_license(id):
    """Extend license expiration"""
    license = License.query.get_or_404(id)
    days = request.form.get('days', 30, type=int)
    
    if license.expires_at:
        base_date = max(license.expires_at, datetime.utcnow())
    else:
        base_date = datetime.utcnow()
    
    license.expires_at = base_date + timedelta(days=days)
    db.session.commit()
    
    log_activity('extend_license', 'license', license.id, f'Extended by {days} days')
    
    flash(f'License extended by {days} days', 'success')
    return redirect(url_for('lic_admin.view_license', id=license.id))


@bp.route('/licenses/<int:id>/reset-activations', methods=['POST'])
@login_required
def reset_activations(id):
    """Reset license activations"""
    license = License.query.get_or_404(id)
    
    # Deactivate all activations
    LicenseActivation.query.filter_by(license_id=license.id, is_active=True).update({
        'is_active': False,
        'deactivated_at': datetime.utcnow()
    })
    license.current_activations = 0
    db.session.commit()
    
    log_activity('reset_activations', 'license', license.id, 'Reset all activations')
    
    flash('Activations reset', 'success')
    return redirect(url_for('lic_admin.view_license', id=license.id))


# ==================== CUSTOMERS ====================

@bp.route('/customers')
@login_required
def customers():
    """List all customers"""
    page = request.args.get('page', 1, type=int)
    search = request.args.get('search', '')
    
    query = Customer.query
    
    if search:
        query = query.filter(
            (Customer.email.ilike(f'%{search}%')) |
            (Customer.company_name.ilike(f'%{search}%')) |
            (Customer.contact_name.ilike(f'%{search}%'))
        )
    
    customers = query.order_by(Customer.created_at.desc()).paginate(page=page, per_page=20)
    
    return render_template('admin/customers.html', customers=customers, search=search)


@bp.route('/customers/create', methods=['GET', 'POST'])
@login_required
def create_customer():
    """Create a new customer"""
    if request.method == 'POST':
        email = request.form.get('email', '').lower()
        
        if Customer.query.filter_by(email=email).first():
            flash('Email already exists', 'error')
            return redirect(url_for('lic_admin.create_customer'))
        
        customer = Customer(
            email=email,
            company_name=request.form.get('company_name'),
            contact_name=request.form.get('contact_name'),
            phone=request.form.get('phone'),
            address=request.form.get('address'),
            notes=request.form.get('notes')
        )
        
        db.session.add(customer)
        db.session.commit()
        
        log_activity('create_customer', 'customer', customer.id, f'Created customer {email}')
        
        flash('Customer created', 'success')
        return redirect(url_for('lic_admin.view_customer', id=customer.id))
    
    return render_template('admin/create_customer.html')


@bp.route('/customers/<int:id>')
@login_required
def view_customer(id):
    """View customer details"""
    customer = Customer.query.get_or_404(id)
    licenses = customer.licenses.order_by(License.created_at.desc()).all()
    
    return render_template('admin/view_customer.html',
        customer=customer,
        licenses=licenses
    )


@bp.route('/customers/<int:id>/edit', methods=['GET', 'POST'])
@login_required
def edit_customer(id):
    """Edit customer"""
    customer = Customer.query.get_or_404(id)
    
    if request.method == 'POST':
        customer.company_name = request.form.get('company_name')
        customer.contact_name = request.form.get('contact_name')
        customer.phone = request.form.get('phone')
        customer.address = request.form.get('address')
        customer.notes = request.form.get('notes')
        customer.is_active = 'is_active' in request.form
        
        db.session.commit()
        
        flash('Customer updated', 'success')
        return redirect(url_for('lic_admin.view_customer', id=customer.id))
    
    return render_template('admin/edit_customer.html', customer=customer)


# ==================== PRODUCTS & TIERS ====================

@bp.route('/products')
@login_required
def products():
    """List products and tiers"""
    products = Product.query.all()
    return render_template('admin/products.html', products=products)


@bp.route('/products/<int:id>/tiers', methods=['GET', 'POST'])
@login_required
def edit_tiers(id):
    """Edit product tiers"""
    product = Product.query.get_or_404(id)
    all_features = Feature.query.filter_by(is_active=True).order_by(Feature.category, Feature.name).all()

    if request.method == 'POST':
        tier_id = request.form.get('tier_id')
        tier = ProductTier.query.get(tier_id)

        if tier and tier.product_id == product.id:
            tier.name = request.form.get('name')
            tier.price_monthly = request.form.get('price_monthly', 0, type=float)
            tier.price_yearly = request.form.get('price_yearly', 0, type=float)
            tier.max_users = request.form.get('max_users', 0, type=int)

            # Build features dict from Feature table codes
            selected = set(request.form.getlist('lic_features'))
            tier.features = {f.code: (f.code in selected) for f in all_features}

            db.session.commit()
            flash('Tier updated', 'success')

        return redirect(url_for('lic_admin.edit_tiers', id=product.id))

    return render_template('admin/edit_tiers.html', product=product, all_features=all_features)


# ==================== ACTIVITY LOG ====================

@bp.route('/activity')
@login_required
def activity_log():
    """View activity log"""
    page = request.args.get('page', 1, type=int)
    logs = ActivityLog.query.order_by(ActivityLog.created_at.desc()).paginate(page=page, per_page=50)
    
    return render_template('admin/activity_log.html', logs=logs)


# ==================== BULK OPERATIONS ====================

@bp.route('/licenses/bulk-create', methods=['GET', 'POST'])
@login_required
def bulk_create_licenses():
    """Create multiple licenses at once"""
    products = Product.query.filter_by(is_active=True).all()
    tiers = ProductTier.query.filter_by(is_active=True).all()
    
    if request.method == 'POST':
        count = request.form.get('count', 1, type=int)
        count = min(count, 100)  # Max 100 at once
        
        product_id = request.form.get('product_id')
        tier_id = request.form.get('tier_id')
        
        duration = request.form.get('duration')
        expires_at = None
        if duration == 'monthly':
            expires_at = datetime.utcnow() + timedelta(days=30)
        elif duration == 'yearly':
            expires_at = datetime.utcnow() + timedelta(days=365)
        
        created_keys = []
        for _ in range(count):
            while True:
                license_key = License.generate_key()
                if not License.query.filter_by(license_key=license_key).first():
                    break
            
            license = License(
                license_key=license_key,
                product_id=product_id,
                tier_id=tier_id,
                max_activations=1,
                expires_at=expires_at,
                created_by=current_user.id
            )
            db.session.add(license)
            created_keys.append(license_key)
        
        db.session.commit()
        
        log_activity('bulk_create', 'license', None, f'Created {count} licenses')
        
        flash(f'{count} licenses created', 'success')
        return render_template('admin/bulk_result.html', keys=created_keys)
    
    return render_template('admin/bulk_create.html', products=products, tiers=tiers)


# ==================== API for AJAX ====================

@bp.route('/api/tiers/<int:product_id>')
@login_required
def get_tiers(product_id):
    """Get tiers for a product (AJAX)"""
    tiers = ProductTier.query.filter_by(product_id=product_id, is_active=True).all()
    return jsonify([{
        'id': t.id,
        'name': t.name,
        'code': t.code,
        'max_users': t.max_users
    } for t in tiers])


# ==================== PRODUCT MANAGEMENT ====================

@bp.route('/products/create', methods=['GET', 'POST'])
@login_required
def create_product():
    """Create a new product"""
    if request.method == 'POST':
        code = request.form.get('code', '').upper().replace(' ', '_')

        if Product.query.filter_by(code=code).first():
            flash('Product code already exists', 'error')
            return redirect(url_for('lic_admin.create_product'))

        product = Product(
            name=request.form.get('name'),
            code=code,
            description=request.form.get('description'),
            require_ip_lock='require_ip_lock' in request.form,
            max_ip_addresses=request.form.get('max_ip_addresses', 1, type=int),
            allow_ip_change='allow_ip_change' in request.form,
            ip_change_cooldown=request.form.get('ip_change_cooldown', 24, type=int)
        )
        db.session.add(product)
        db.session.commit()

        log_activity('create_product', 'product', product.id, f'Created product {product.name}')
        flash(f'Product "{product.name}" created', 'success')
        # Redirect to kit page so user gets the integration code immediately
        return redirect(url_for('lic_admin.product_kit', id=product.id))

    return render_template('admin/create_product.html')


@bp.route('/products/<int:id>/edit', methods=['GET', 'POST'])
@login_required
def edit_product(id):
    """Edit a product"""
    product = Product.query.get_or_404(id)
    
    if request.method == 'POST':
        product.name = request.form.get('name')
        product.description = request.form.get('description')
        product.require_ip_lock = 'require_ip_lock' in request.form
        product.max_ip_addresses = request.form.get('max_ip_addresses', 1, type=int)
        product.allow_ip_change = 'allow_ip_change' in request.form
        product.ip_change_cooldown = request.form.get('ip_change_cooldown', 24, type=int)
        product.is_active = 'is_active' in request.form
        
        db.session.commit()
        log_activity('edit_product', 'product', product.id, f'Updated product {product.name}')
        flash('Product updated', 'success')
        return redirect(url_for('lic_admin.products'))
    
    return render_template('admin/edit_product.html', product=product)


@bp.route('/products/<int:id>/delete', methods=['POST'])
@login_required
def delete_product(id):
    """Delete a product"""
    product = Product.query.get_or_404(id)
    
    # Check if product has licenses
    if product.licenses.count() > 0:
        flash(f'Cannot delete: {product.licenses.count()} licenses exist for this product', 'error')
        return redirect(url_for('lic_admin.products'))
    
    name = product.name
    
    # Delete tiers first
    ProductTier.query.filter_by(product_id=product.id).delete()
    db.session.delete(product)
    db.session.commit()
    
    log_activity('delete_product', 'product', id, f'Deleted product {name}')
    flash(f'Product "{name}" deleted', 'success')
    return redirect(url_for('lic_admin.products'))


@bp.route('/products/<int:product_id>/tiers/create', methods=['GET', 'POST'])
@login_required
def create_tier(product_id):
    """Create a new tier for a product"""
    product = Product.query.get_or_404(product_id)
    all_features = Feature.query.filter_by(is_active=True).order_by(Feature.category, Feature.name).all()

    if request.method == 'POST':
        # Build features dict from Feature table codes
        selected = set(request.form.getlist('lic_features'))
        features = {f.code: (f.code in selected) for f in all_features}

        tier = ProductTier(
            product_id=product.id,
            name=request.form.get('name'),
            code=request.form.get('code', '').lower().replace(' ', '_'),
            price_monthly=request.form.get('price_monthly', 0, type=float),
            price_yearly=request.form.get('price_yearly', 0, type=float),
            max_users=request.form.get('max_users', 0, type=int),
            sort_order=request.form.get('sort_order', 0, type=int),
            features=features
        )

        db.session.add(tier)
        db.session.commit()

        log_activity('create_tier', 'tier', tier.id, f'Created tier {tier.name} for {product.name}')
        flash(f'Tier "{tier.name}" created', 'success')
        return redirect(url_for('lic_admin.edit_tiers', id=product.id))

    return render_template('admin/create_tier.html', product=product, all_features=all_features)


@bp.route('/tiers/<int:id>/delete', methods=['POST'])
@login_required
def delete_tier(id):
    """Delete a tier"""
    tier = ProductTier.query.get_or_404(id)
    product_id = tier.product_id
    
    # Check if tier has licenses
    if tier.licenses.count() > 0:
        flash(f'Cannot delete: {tier.licenses.count()} licenses use this tier', 'error')
        return redirect(url_for('lic_admin.edit_tiers', id=product_id))
    
    name = tier.name
    db.session.delete(tier)
    db.session.commit()
    
    flash(f'Tier "{name}" deleted', 'success')
    return redirect(url_for('lic_admin.edit_tiers', id=product_id))



@bp.route('/licenses/<int:id>/ips', methods=['GET', 'POST'])
@login_required
def manage_license_ips(id):
    """Manage allowed IPs for a license"""
    license = License.query.get_or_404(id)
    
    if request.method == 'POST':
        action = request.form.get('action')
        
        if action == 'add':
            ip = request.form.get('ip', '').strip()
            if ip:
                allowed_ips = license.allowed_ips or []
                if ip not in allowed_ips:
                    allowed_ips.append(ip)
                    license.allowed_ips = allowed_ips
                    db.session.commit()
                    log_activity('add_ip', 'license', license.id, f'Added IP {ip}')
                    flash(f'IP {ip} added', 'success')
                else:
                    flash('IP already in list', 'warning')
        
        elif action == 'remove':
            ip = request.form.get('ip', '').strip()
            if ip:
                allowed_ips = license.allowed_ips or []
                if ip in allowed_ips:
                    allowed_ips.remove(ip)
                    license.allowed_ips = allowed_ips
                    db.session.commit()
                    log_activity('remove_ip', 'license', license.id, f'Removed IP {ip}')
                    flash(f'IP {ip} removed', 'success')
        
        elif action == 'clear':
            license.allowed_ips = []
            db.session.commit()
            log_activity('clear_ips', 'license', license.id, 'Cleared all IPs')
            flash('All IPs cleared', 'success')
        
        return redirect(url_for('lic_admin.manage_license_ips', id=license.id))
    
    return render_template('admin/manage_ips.html', license=license)


@bp.route('/licenses/<int:id>/delete', methods=['POST'])
@login_required
def delete_license(id):
    """Delete a license"""
    license = License.query.get_or_404(id)
    license_key = license.license_key
    
    # Delete related records
    LicenseActivation.query.filter_by(license_id=license.id).delete()
    
    # Delete IP history if exists
    from .models import LicenseIPHistory
    LicenseIPHistory.query.filter_by(license_id=license.id).delete()
    
    db.session.delete(license)
    db.session.commit()
    
    log_activity('delete_license', 'license', id, f'Deleted license {license_key}')
    flash(f'License {license_key} deleted', 'success')
    return redirect(url_for('lic_admin.licenses'))


@bp.route('/licenses/<int:id>/purge', methods=['POST'])
@login_required
def purge_license(id):
    """Purge all data for a license (IPs, activations, history) but keep license"""
    license = License.query.get_or_404(id)
    
    # Clear activations
    LicenseActivation.query.filter_by(license_id=license.id).delete()
    license.current_activations = 0
    
    # Clear IP history
    from .models import LicenseIPHistory
    LicenseIPHistory.query.filter_by(license_id=license.id).delete()
    
    # Clear allowed IPs
    license.allowed_ips = []
    license.last_ip_change = None
    
    db.session.commit()
    
    log_activity('purge_license', 'license', license.id, f'Purged all data for {license.license_key}')
    flash(f'License {license.license_key} purged', 'success')
    return redirect(url_for('lic_admin.view_license', id=license.id))



# ==================== BULK LICENSE ACTIONS ====================

@bp.route('/licenses/bulk-action', methods=['POST'])
@login_required
def bulk_license_action():
    """Perform bulk actions on licenses"""
    action = request.form.get('action')
    license_ids = request.form.getlist('license_ids')
    
    if not license_ids:
        flash('No licenses selected', 'warning')
        return redirect(url_for('lic_admin.licenses'))
    
    count = 0
    
    if action == 'delete':
        for lid in license_ids:
            license = License.query.get(lid)
            if license:
                LicenseActivation.query.filter_by(license_id=license.id).delete()
                from .models import LicenseIPHistory
                LicenseIPHistory.query.filter_by(license_id=license.id).delete()
                db.session.delete(license)
                count += 1
        db.session.commit()
        log_activity('bulk_delete', 'license', None, f'Deleted {count} licenses')
        flash(f'{count} licenses deleted', 'success')
    
    elif action == 'purge':
        for lid in license_ids:
            license = License.query.get(lid)
            if license:
                LicenseActivation.query.filter_by(license_id=license.id).delete()
                from .models import LicenseIPHistory
                LicenseIPHistory.query.filter_by(license_id=license.id).delete()
                license.allowed_ips = []
                license.current_activations = 0
                license.last_ip_change = None
                count += 1
        db.session.commit()
        log_activity('bulk_purge', 'license', None, f'Purged {count} licenses')
        flash(f'{count} licenses purged', 'success')
    
    elif action == 'suspend':
        for lid in license_ids:
            license = License.query.get(lid)
            if license and license.status == 'active':
                license.status = 'suspended'
                count += 1
        db.session.commit()
        log_activity('bulk_suspend', 'license', None, f'Suspended {count} licenses')
        flash(f'{count} licenses suspended', 'success')
    
    elif action == 'activate':
        for lid in license_ids:
            license = License.query.get(lid)
            if license and license.status != 'active':
                license.status = 'active'
                count += 1
        db.session.commit()
        log_activity('bulk_activate', 'license', None, f'Activated {count} licenses')
        flash(f'{count} licenses activated', 'success')
    
    elif action == 'revoke':
        for lid in license_ids:
            license = License.query.get(lid)
            if license:
                license.status = 'revoked'
                count += 1
        db.session.commit()
        log_activity('bulk_revoke', 'license', None, f'Revoked {count} licenses')
        flash(f'{count} licenses revoked', 'success')
    
    elif action == 'clear_ips':
        for lid in license_ids:
            license = License.query.get(lid)
            if license:
                license.allowed_ips = []
                count += 1
        db.session.commit()
        log_activity('bulk_clear_ips', 'license', None, f'Cleared IPs for {count} licenses')
        flash(f'IPs cleared for {count} licenses', 'success')
    
    return redirect(url_for('lic_admin.licenses'))


@bp.route('/licenses/delete-all', methods=['POST'])
@login_required
def delete_all_licenses():
    """Delete ALL licenses - dangerous!"""
    confirm = request.form.get('confirm')
    
    if confirm != 'DELETE ALL':
        flash('Please type "DELETE ALL" to confirm', 'error')
        return redirect(url_for('lic_admin.licenses'))
    
    # Delete all related data
    LicenseActivation.query.delete()
    from .models import LicenseIPHistory
    LicenseIPHistory.query.delete()
    
    count = License.query.count()
    License.query.delete()
    db.session.commit()
    
    log_activity('delete_all', 'license', None, f'Deleted ALL {count} licenses')
    flash(f'All {count} licenses deleted', 'success')
    return redirect(url_for('lic_admin.licenses'))


# ==================== SETTINGS ====================

@bp.route('/settings', methods=['GET', 'POST'])
@login_required
def settings():
    """System settings"""
    from .models import Settings
    
    if request.method == 'POST':
        for key in request.form:
            if key != 'csrf_token':
                Settings.set(key, request.form[key])
        
        log_activity('update_settings', 'lic_settings', None, 'Updated system settings')
        flash('Settings saved', 'success')
        return redirect(url_for('lic_admin.settings'))
    
    settings_by_category = Settings.get_all_by_category()
    return render_template('admin/settings.html', settings_by_category=settings_by_category)


# ==================== ROLES ====================

@bp.route('/roles')
@login_required
def roles():
    """List all roles"""
    from .models import Role
    roles = Role.query.order_by(Role.name).all()
    return render_template('admin/roles.html', roles=roles)


@bp.route('/roles/create', methods=['GET', 'POST'])
@login_required
def create_role():
    """Create a new role"""
    from .models import Role, Permission
    
    if request.method == 'POST':
        name = request.form.get('name')
        
        if Role.query.filter_by(name=name).first():
            flash('Role name already exists', 'error')
            return redirect(url_for('lic_admin.create_role'))
        
        role = Role(
            name=name,
            description=request.form.get('description'),
            color=request.form.get('color', 'gray')
        )
        
        # Add permissions
        perm_ids = request.form.getlist('lic_permissions')
        role.permissions = Permission.query.filter(Permission.id.in_(perm_ids)).all()
        
        db.session.add(role)
        db.session.commit()
        
        log_activity('create_role', 'role', role.id, f'Created role {name}')
        flash(f'Role "{name}" created', 'success')
        return redirect(url_for('lic_admin.roles'))
    
    permissions = Permission.get_all_by_category()
    return render_template('admin/create_role.html', permissions=permissions)


@bp.route('/roles/<int:id>/edit', methods=['GET', 'POST'])
@login_required
def edit_role(id):
    """Edit a role"""
    from .models import Role, Permission
    
    role = Role.query.get_or_404(id)
    
    if request.method == 'POST':
        role.name = request.form.get('name')
        role.description = request.form.get('description')
        role.color = request.form.get('color', 'gray')
        
        # Update permissions
        perm_ids = request.form.getlist('lic_permissions')
        role.permissions = Permission.query.filter(Permission.id.in_(perm_ids)).all()
        
        db.session.commit()
        
        log_activity('edit_role', 'role', role.id, f'Updated role {role.name}')
        flash('Role updated', 'success')
        return redirect(url_for('lic_admin.roles'))
    
    permissions = Permission.get_all_by_category()
    return render_template('admin/edit_role.html', role=role, permissions=permissions)


@bp.route('/roles/<int:id>/delete', methods=['POST'])
@login_required
def delete_role(id):
    """Delete a role"""
    from .models import Role
    
    role = Role.query.get_or_404(id)
    
    if role.is_system:
        flash('Cannot delete system role', 'error')
        return redirect(url_for('lic_admin.roles'))
    
    if role.users:
        flash(f'Cannot delete: {len(role.users)} users have this role', 'error')
        return redirect(url_for('lic_admin.roles'))
    
    name = role.name
    db.session.delete(role)
    db.session.commit()
    
    log_activity('delete_role', 'role', id, f'Deleted role {name}')
    flash(f'Role "{name}" deleted', 'success')
    return redirect(url_for('lic_admin.roles'))


# ==================== ADMIN USERS ====================

@bp.route('/users')
@login_required
def admin_users():
    """List admin users"""
    users = AdminUser.query.order_by(AdminUser.name).all()
    return render_template('admin/users.html', users=users)


@bp.route('/users/create', methods=['GET', 'POST'])
@login_required
def create_admin_user():
    """Create a new admin user"""
    from .models import Role
    
    if request.method == 'POST':
        email = request.form.get('email', '').lower()
        
        if AdminUser.query.filter_by(email=email).first():
            flash('Email already exists', 'error')
            return redirect(url_for('lic_admin.create_admin_user'))
        
        user = AdminUser(
            email=email,
            name=request.form.get('name'),
            is_superadmin='is_superadmin' in request.form,
            avatar_color=request.form.get('avatar_color', 'emerald')
        )
        user.set_password(request.form.get('password'))
        
        # Add roles
        role_ids = request.form.getlist('lic_roles')
        user.roles = Role.query.filter(Role.id.in_(role_ids)).all()
        
        db.session.add(user)
        db.session.commit()
        
        log_activity('create_user', 'admin_user', user.id, f'Created admin user {email}')
        flash(f'User "{user.name}" created', 'success')
        return redirect(url_for('lic_admin.admin_users'))
    
    roles = Role.query.order_by(Role.name).all()
    return render_template('admin/create_user.html', roles=roles)


@bp.route('/users/<int:id>/edit', methods=['GET', 'POST'])
@login_required
def edit_admin_user(id):
    """Edit an admin user"""
    from .models import Role
    
    user = AdminUser.query.get_or_404(id)
    
    if request.method == 'POST':
        user.name = request.form.get('name')
        user.is_superadmin = 'is_superadmin' in request.form
        user.is_active = 'is_active' in request.form
        user.avatar_color = request.form.get('avatar_color', 'emerald')
        
        # Update password if provided
        new_password = request.form.get('password')
        if new_password:
            user.set_password(new_password)
        
        # Update roles
        role_ids = request.form.getlist('lic_roles')
        user.roles = Role.query.filter(Role.id.in_(role_ids)).all()
        
        db.session.commit()
        
        log_activity('edit_user', 'admin_user', user.id, f'Updated admin user {user.email}')
        flash('User updated', 'success')
        return redirect(url_for('lic_admin.admin_users'))
    
    roles = Role.query.order_by(Role.name).all()
    return render_template('admin/edit_user.html', user=user, roles=roles)


@bp.route('/users/<int:id>/delete', methods=['POST'])
@login_required
def delete_admin_user(id):
    """Delete an admin user"""
    user = AdminUser.query.get_or_404(id)
    
    if user.id == current_user.id:
        flash('Cannot delete your own account', 'error')
        return redirect(url_for('lic_admin.admin_users'))
    
    email = user.email
    db.session.delete(user)
    db.session.commit()
    
    log_activity('delete_user', 'admin_user', id, f'Deleted admin user {email}')
    flash(f'User deleted', 'success')
    return redirect(url_for('lic_admin.admin_users'))


# ==================== FEATURES ====================

@bp.route('/features')
@login_required
def features():
    """List all features"""
    from .models import Feature
    all_features = Feature.query.order_by(Feature.category, Feature.name).all()
    grouped = Feature.grouped()
    return render_template('admin/features.html', features=all_features, grouped=grouped)


@bp.route('/features/create', methods=['GET', 'POST'])
@login_required
def create_feature():
    """Create a new feature"""
    from .models import Feature
    if request.method == 'POST':
        code         = request.form.get('code', '').strip().lower().replace(' ', '_')
        name         = request.form.get('name', '').strip()
        description  = request.form.get('description', '').strip()
        product_group = request.form.get('product_group', 'General').strip()
        category     = request.form.get('category', 'Core').strip()
        icon         = request.form.get('icon', 'puzzle').strip()

        if not code or not name:
            flash('Code and name are required', 'error')
            return redirect(url_for('lic_admin.create_feature'))

        if Feature.query.filter_by(code=code).first():
            flash(f'Feature code "{code}" already exists', 'error')
            return redirect(url_for('lic_admin.create_feature'))

        feature = Feature(
            code=code, name=name, description=description,
            product_group=product_group, category=category, icon=icon
        )
        db.session.add(feature)
        db.session.commit()
        log_activity('create_feature', 'feature', feature.id, f'Created feature {name}')
        flash(f'Feature "{name}" created', 'success')
        return redirect(url_for('lic_admin.features'))

    return render_template('admin/create_feature.html')


@bp.route('/features/<int:id>/edit', methods=['GET', 'POST'])
@login_required
def edit_feature(id):
    """Edit a feature"""
    from .models import Feature
    feature = Feature.query.get_or_404(id)

    if request.method == 'POST':
        feature.name          = request.form.get('name', feature.name).strip()
        feature.description   = request.form.get('description', '').strip()
        feature = request.form.get('product_group', 'General').strip()
        feature.category      = request.form.get('category', 'Core').strip()
        feature.icon          = request.form.get('icon', 'puzzle').strip()
        feature.is_active     = request.form.get('is_active') == 'on'
        db.session.commit()
        log_activity('edit_feature', 'feature', feature.id, f'Edited feature {feature.name}')
        flash('Feature updated', 'success')
        return redirect(url_for('lic_admin.features'))

    return render_template('admin/edit_feature.html', feature=feature)


@bp.route('/features/<int:id>/delete', methods=['POST'])
@login_required
def delete_feature(id):
    """Delete a feature"""
    from .models import Feature
    feature = Feature.query.get_or_404(id)
    name = feature.name
    db.session.delete(feature)
    db.session.commit()
    log_activity('delete_feature', 'feature', id, f'Deleted feature {name}')
    flash(f'Feature "{name}" deleted', 'success')
    return redirect(url_for('lic_admin.features'))


@bp.route('/features/<int:id>/toggle', methods=['POST'])
@login_required
def toggle_feature(id):
    """Toggle feature active state"""
    from .models import Feature
    feature = Feature.query.get_or_404(id)
    feature.is_active = not feature.is_active
    db.session.commit()
    return jsonify({'active': feature.is_active, 'name': feature.name})


# ==================== API EXPLORER ====================

@bp.route('/api-explorer')
@login_required
def api_explorer():
    """Live API Explorer page"""
    from .models import Settings
    base_url = request.host_url.rstrip('/')
    return render_template('admin/api_explorer.html', base_url=base_url)


# ==================== PRODUCT KIT ====================

@bp.route('/products/<int:id>/kit')
@login_required
def product_kit(id):
    """Integration code kit for a product"""
    product = Product.query.get_or_404(id)
    base_url = request.host_url.rstrip('/')
    return render_template('admin/product_kit.html', product=product, base_url=base_url)
