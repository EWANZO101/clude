"""
License Manager - Authentication Routes
"""
from flask import Blueprint, render_template, redirect, url_for, flash, request
from flask_login import login_user, logout_user, current_user, login_required
from datetime import datetime
from .. import db   # shared with OpsLabs
from .models import AdminUser
from ..security import safe_next

bp = Blueprint('lic_auth', __name__)


@bp.route('/login', methods=['GET', 'POST'])
def login():
    if current_user.is_authenticated:
        return redirect(url_for('lic_admin.dashboard'))
    
    if request.method == 'POST':
        email = request.form.get('email', '').lower()
        password = request.form.get('password', '')
        remember = 'remember' in request.form
        
        user = AdminUser.query.filter_by(email=email).first()
        
        if user is None or not user.check_password(password):
            flash('Invalid email or password', 'error')
            return redirect(url_for('lic_auth.login'))
        
        if not user.is_active:
            flash('Account disabled', 'error')
            return redirect(url_for('lic_auth.login'))
        
        user.last_login = datetime.utcnow()
        db.session.commit()
        
        login_user(user, remember=remember)
        
        next_page = safe_next(request.args.get('next'), url_for('lic_admin.dashboard'))
        
        return redirect(next_page)
    
    return render_template('licenses/auth/login.html')


@bp.route('/logout')
@login_required
def logout():
    logout_user()
    flash('Logged out', 'info')
    return redirect(url_for('lic_auth.login'))


@bp.route('/profile', methods=['GET', 'POST'])
@login_required
def profile():
    if request.method == 'POST':
        current_user.name = request.form.get('name')
        
        new_password = request.form.get('new_password')
        if new_password:
            current_password = request.form.get('current_password')
            if not current_user.check_password(current_password):
                flash('Current password is incorrect', 'error')
                return redirect(url_for('lic_auth.profile'))
            current_user.set_password(new_password)
        
        db.session.commit()
        flash('Profile updated', 'success')
        return redirect(url_for('lic_auth.profile'))
    
    return render_template('auth/profile.html')
