from flask import Blueprint, render_template, jsonify, request, redirect, url_for
from flask_login import login_required, current_user
from app import db

main_bp = Blueprint('main', __name__)


@main_bp.route('/')
@login_required
def dashboard():
    return redirect(url_for('dashboard.index'))


@main_bp.route('/api/theme', methods=['POST'])
@login_required
def set_theme():
    theme = request.json.get('theme', 'dark')
    if theme not in ('dark', 'light'):
        theme = 'dark'
    current_user.theme_pref = theme
    db.session.commit()
    return jsonify({'ok': True, 'theme': theme})
