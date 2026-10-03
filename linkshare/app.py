import os
import string
import random
import atexit
from datetime import datetime, timedelta

from flask import Flask, request, render_template, url_for, send_from_directory, abort, jsonify
from flask_sqlalchemy import SQLAlchemy
from werkzeug.utils import secure_filename
from apscheduler.schedulers.background import BackgroundScheduler

BASE_DIR = os.path.abspath(os.path.dirname(__file__))
UPLOAD_DIR = os.path.join(BASE_DIR, 'uploads')
os.makedirs(UPLOAD_DIR, exist_ok=True)

ALLOWED_EXT = {
    'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp',
    'mp4', 'mov', 'webm', 'avi', 'mkv'
}

EXPIRE_HOURS = float(os.environ.get('EXPIRE_HOURS', 12))
MAX_CONTENT_LENGTH = int(os.environ.get('MAX_UPLOAD_MB', 500)) * 1024 * 1024

app = Flask(__name__)
app.config['SQLALCHEMY_DATABASE_URI'] = 'sqlite:///' + os.path.join(BASE_DIR, 'linkshare.db')
app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False
app.config['MAX_CONTENT_LENGTH'] = MAX_CONTENT_LENGTH
app.secret_key = os.environ.get('SECRET_KEY', 'change-me-in-prod')

db = SQLAlchemy(app)


class Upload(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    code = db.Column(db.String(12), unique=True, nullable=False, index=True)
    filename = db.Column(db.String(255), nullable=False)
    original_name = db.Column(db.String(255), nullable=False)
    filesize = db.Column(db.Integer, nullable=False)
    mimetype = db.Column(db.String(100))
    kind = db.Column(db.String(10))  # image / video
    uploaded_at = db.Column(db.DateTime, default=datetime.utcnow)
    expires_at = db.Column(db.DateTime, nullable=False)
    views = db.Column(db.Integer, default=0)

    def is_expired(self):
        return datetime.utcnow() >= self.expires_at


with app.app_context():
    db.create_all()


def gen_code(length=8):
    chars = string.ascii_letters + string.digits
    while True:
        code = ''.join(random.choices(chars, k=length))
        if not Upload.query.filter_by(code=code).first():
            return code


def allowed_file(filename):
    return '.' in filename and filename.rsplit('.', 1)[1].lower() in ALLOWED_EXT


def kind_for(ext):
    ext = ext.lower()
    if ext in {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'}:
        return 'image'
    return 'video'


def delete_upload(upload):
    path = os.path.join(UPLOAD_DIR, upload.filename)
    try:
        if os.path.exists(path):
            os.remove(path)
    except OSError:
        pass
    db.session.delete(upload)


def cleanup_expired():
    with app.app_context():
        expired = Upload.query.filter(Upload.expires_at <= datetime.utcnow()).all()
        for u in expired:
            delete_upload(u)
        if expired:
            db.session.commit()


scheduler = BackgroundScheduler()
scheduler.add_job(func=cleanup_expired, trigger='interval', minutes=5)
scheduler.start()
atexit.register(lambda: scheduler.shutdown(wait=False))


@app.route('/')
def index():
    return render_template('index.html', expire_hours=EXPIRE_HOURS, max_mb=MAX_CONTENT_LENGTH // (1024 * 1024))


@app.route('/upload', methods=['POST'])
def upload():
    if 'file' not in request.files:
        return jsonify({'error': 'No file provided'}), 400
    f = request.files['file']
    if f.filename == '':
        return jsonify({'error': 'No file selected'}), 400
    if not allowed_file(f.filename):
        return jsonify({'error': 'File type not allowed'}), 400

    ext = f.filename.rsplit('.', 1)[1].lower()
    code = gen_code()
    stored_name = f"{code}.{ext}"
    filepath = os.path.join(UPLOAD_DIR, stored_name)
    f.save(filepath)
    filesize = os.path.getsize(filepath)

    row = Upload(
        code=code,
        filename=stored_name,
        original_name=secure_filename(f.filename) or f"file.{ext}",
        filesize=filesize,
        mimetype=f.mimetype,
        kind=kind_for(ext),
        expires_at=datetime.utcnow() + timedelta(hours=EXPIRE_HOURS)
    )
    db.session.add(row)
    db.session.commit()

    return jsonify({
        'code': code,
        'url': url_for('view_upload', code=code, _external=True),
        'expires_at': row.expires_at.isoformat() + 'Z',
        'kind': row.kind
    })


@app.route('/v/<code>')
def view_upload(code):
    u = Upload.query.filter_by(code=code).first()
    if not u or u.is_expired():
        if u and u.is_expired():
            delete_upload(u)
            db.session.commit()
        return render_template('gone.html'), 404
    u.views += 1
    db.session.commit()
    remaining = int((u.expires_at - datetime.utcnow()).total_seconds())
    return render_template('view.html', upload=u, remaining=max(remaining, 0))


@app.route('/f/<code>')
def raw_file(code):
    u = Upload.query.filter_by(code=code).first()
    if not u or u.is_expired():
        abort(404)
    return send_from_directory(UPLOAD_DIR, u.filename, mimetype=u.mimetype)


@app.route('/d/<code>')
def download_file(code):
    u = Upload.query.filter_by(code=code).first()
    if not u or u.is_expired():
        abort(404)
    return send_from_directory(
        UPLOAD_DIR, u.filename, mimetype=u.mimetype,
        as_attachment=True, download_name=u.original_name
    )


@app.errorhandler(413)
def too_large(e):
    return jsonify({'error': 'File too large'}), 413


@app.errorhandler(404)
def not_found(e):
    return render_template('gone.html'), 404


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5004, debug=False)
