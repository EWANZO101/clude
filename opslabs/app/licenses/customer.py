"""
License Manager - Customer Portal
"""
from flask import Blueprint, render_template, redirect, url_for, flash, request, session
from functools import wraps
from datetime import datetime
from .. import db   # shared with OpsLabs
from .models import Customer, License, LicenseActivation, LicenseIPHistory

bp = Blueprint('lic_customer', __name__)


def customer_required(f):
    @wraps(f)
    def decorated_function(*args, **kwargs):
        customer_id = session.get('customer_id')
        if not customer_id:
            return redirect(url_for('lic_customer.login'))
        customer = Customer.query.get(customer_id)
        if not customer or not customer.is_active:
            session.pop('customer_id', None)
            return redirect(url_for('lic_customer.login'))
        return f(customer, *args, **kwargs)
    return decorated_function


@bp.route('/login', methods=['GET', 'POST'])
def login():
    if session.get('customer_id'):
        return redirect(url_for('lic_customer.dashboard'))
    
    if request.method == 'POST':
        email = request.form.get('email', '').lower().strip()
        password = request.form.get('password', '')
        
        customer = Customer.query.filter_by(email=email).first()
        
        if customer and customer.check_password(password):
            if not customer.is_active:
                flash('Account is disabled', 'error')
                return redirect(url_for('lic_customer.login'))
            
            session['customer_id'] = customer.id
            customer.last_login = datetime.utcnow()
            db.session.commit()
            return redirect(url_for('lic_customer.dashboard'))
        
        flash('Invalid email or password', 'error')
    
    return render_template('licenses/customer/login.html')


@bp.route('/register', methods=['GET', 'POST'])
def register():
    if session.get('customer_id'):
        return redirect(url_for('lic_customer.dashboard'))
    
    if request.method == 'POST':
        email = request.form.get('email', '').lower().strip()
        password = request.form.get('password', '')
        company_name = request.form.get('company_name', '').strip()
        contact_name = request.form.get('contact_name', '').strip()
        
        if Customer.query.filter_by(email=email).first():
            flash('Email already registered', 'error')
            return redirect(url_for('lic_customer.register'))
        
        if len(password) < 8:
            flash('Password must be at least 8 characters', 'error')
            return redirect(url_for('lic_customer.register'))
        
        customer = Customer(email=email, company_name=company_name or None, contact_name=contact_name or None)
        customer.set_password(password)
        db.session.add(customer)
        db.session.commit()
        
        session['customer_id'] = customer.id
        flash('Account created!', 'success')
        return redirect(url_for('lic_customer.dashboard'))
    
    return render_template('licenses/customer/register.html')


@bp.route('/logout')
def logout():
    session.pop('customer_id', None)
    flash('Logged out', 'info')
    return redirect(url_for('lic_customer.login'))


@bp.route('/')
@customer_required
def dashboard(customer):
    licenses = customer.licenses.order_by(License.created_at.desc()).all()
    return render_template('licenses/customer/dashboard.html', customer=customer, licenses=licenses)


@bp.route('/license/<int:id>')
@customer_required
def view_license(customer, id):
    license = License.query.filter_by(id=id, customer_id=customer.id).first_or_404()
    activations = license.activations.order_by(LicenseActivation.activated_at.desc()).all()
    ip_history = license.ip_history.order_by(LicenseIPHistory.changed_at.desc()).limit(20).all()
    can_change_ip = license.can_change_ip()
    change_message = None
    
    return render_template('licenses/customer/view_license.html',
        customer=customer, license=license, activations=activations,
        ip_history=ip_history, can_change_ip=can_change_ip,
        change_message=change_message, current_ip=request.remote_addr)


@bp.route('/license/<int:id>/add-ip', methods=['POST'])
@customer_required
def add_ip(customer, id):
    license = License.query.filter_by(id=id, customer_id=customer.id).first_or_404()
    
    can_change, message = license.can_change_ip()
    if not can_change:
        flash(message, 'error')
        return redirect(url_for('lic_customer.view_license', id=id))
    
    ip = request.form.get('ip_address', '').strip() or request.remote_addr
    
    if not license.allowed_ips:
        license.allowed_ips = []
    
    if ip in license.allowed_ips:
        flash('IP already in list', 'info')
        return redirect(url_for('lic_customer.view_license', id=id))
    
    if len(license.allowed_ips) >= license.product.max_ip_addresses:
        flash(f'Maximum {license.product.max_ip_addresses} IPs allowed', 'error')
        return redirect(url_for('lic_customer.view_license', id=id))
    
    license.allowed_ips = license.allowed_ips + [ip]
    license.last_ip_change = datetime.utcnow()
    
    history = LicenseIPHistory(license_id=license.id, ip_address=ip, action='added', changed_by='customer')
    db.session.add(history)
    db.session.commit()
    
    flash(f'IP {ip} added', 'success')
    return redirect(url_for('lic_customer.view_license', id=id))


@bp.route('/license/<int:id>/remove-ip', methods=['POST'])
@customer_required
def remove_ip(customer, id):
    license = License.query.filter_by(id=id, customer_id=customer.id).first_or_404()
    
    can_change, message = license.can_change_ip()
    if not can_change:
        flash(message, 'error')
        return redirect(url_for('lic_customer.view_license', id=id))
    
    ip = request.form.get('ip_address', '').strip()
    
    if license.allowed_ips and ip in license.allowed_ips:
        license.allowed_ips = [i for i in license.allowed_ips if i != ip]
        license.last_ip_change = datetime.utcnow()
        
        history = LicenseIPHistory(license_id=license.id, ip_address=ip, action='removed', changed_by='customer')
        db.session.add(history)
        db.session.commit()
        flash(f'IP {ip} removed', 'success')
    else:
        flash('IP not found', 'error')
    
    return redirect(url_for('lic_customer.view_license', id=id))


@bp.route('/license/<int:id>/use-current-ip', methods=['POST'])
@customer_required
def use_current_ip(customer, id):
    license = License.query.filter_by(id=id, customer_id=customer.id).first_or_404()
    
    can_change, message = license.can_change_ip()
    if not can_change:
        flash(message, 'error')
        return redirect(url_for('lic_customer.view_license', id=id))
    
    current_ip = request.remote_addr
    old_ips = license.allowed_ips or []
    
    license.allowed_ips = [current_ip]
    license.last_ip_change = datetime.utcnow()
    
    for old_ip in old_ips:
        if old_ip != current_ip:
            db.session.add(LicenseIPHistory(license_id=license.id, ip_address=old_ip, action='removed', changed_by='customer'))
    
    db.session.add(LicenseIPHistory(license_id=license.id, ip_address=current_ip, action='added', changed_by='customer'))
    db.session.commit()
    
    flash(f'License locked to IP: {current_ip}', 'success')
    return redirect(url_for('lic_customer.view_license', id=id))


@bp.route('/activate', methods=['GET', 'POST'])
@customer_required
def activate_license(customer):
    if request.method == 'POST':
        key = request.form.get('license_key', '').strip().upper()
        
        license = License.query.filter_by(license_key=key).first()
        
        if not license:
            flash('Invalid license key', 'error')
            return redirect(url_for('lic_customer.activate_license'))
        
        if license.customer_id and license.customer_id != customer.id:
            flash('License already assigned to another account', 'error')
            return redirect(url_for('lic_customer.activate_license'))
        
        if license.customer_id == customer.id:
            flash('License already in your account', 'info')
            return redirect(url_for('lic_customer.view_license', id=license.id))
        
        license.customer_id = customer.id
        db.session.commit()
        
        flash('License added to your account!', 'success')
        return redirect(url_for('lic_customer.view_license', id=license.id))
    
    return render_template('licenses/customer/activate.html', customer=customer)


@bp.route('/profile', methods=['GET', 'POST'])
@customer_required
def profile(customer):
    if request.method == 'POST':
        customer.company_name = request.form.get('company_name', '').strip() or None
        customer.contact_name = request.form.get('contact_name', '').strip() or None
        customer.phone = request.form.get('phone', '').strip() or None
        customer.address = request.form.get('address', '').strip() or None
        
        new_password = request.form.get('new_password', '')
        if new_password:
            current_password = request.form.get('current_password', '')
            if not customer.check_password(current_password):
                flash('Current password incorrect', 'error')
                return redirect(url_for('lic_customer.profile'))
            if len(new_password) < 8:
                flash('Password must be at least 8 characters', 'error')
                return redirect(url_for('lic_customer.profile'))
            customer.set_password(new_password)
        
        db.session.commit()
        flash('Profile updated', 'success')
    
    return render_template('licenses/customer/profile.html', customer=customer)
