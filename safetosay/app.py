from flask import (Flask, render_template, redirect, url_for, flash,
                   request, session, jsonify, abort, send_from_directory)
from flask_login import LoginManager, login_user, logout_user, login_required, current_user
from werkzeug.security import generate_password_hash, check_password_hash
from werkzeug.utils import secure_filename
from urllib.parse import urlparse, urljoin
from functools import wraps
from datetime import datetime, timedelta
import uuid, os, re, time
from collections import defaultdict

app = Flask(__name__)
app.config['SECRET_KEY'] = os.environ.get('SECRET_KEY') or 'change-this-secret-key-in-production-use-env-var'
app.config['SQLALCHEMY_DATABASE_URI'] = 'sqlite:///forum.db'
app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False
app.config['MAX_CONTENT_LENGTH'] = 20 * 1024 * 1024  # 20MB
app.config['UPLOAD_FOLDER'] = os.path.join(os.path.dirname(__file__), 'static', 'uploads')

ALLOWED_IMAGES = {'png', 'jpg', 'jpeg', 'gif', 'webp'}
ALLOWED_DOCS   = {'pdf', 'doc', 'docx'}
ALLOWED_ALL    = ALLOWED_IMAGES | ALLOWED_DOCS

# ─── Simple in-memory rate limiter for login/register ────────────────────────
_login_attempts = defaultdict(list)  # ip -> [timestamp, ...]
LOGIN_MAX_ATTEMPTS = 10
LOGIN_WINDOW_SECONDS = 300  # 5 minutes

def _rate_limited(ip):
    now = time.time()
    attempts = _login_attempts[ip]
    # Drop old attempts outside the window
    attempts[:] = [t for t in attempts if now - t < LOGIN_WINDOW_SECONDS]
    if len(attempts) >= LOGIN_MAX_ATTEMPTS:
        return True
    attempts.append(now)
    return False

from models import (db, User, Post, PostMedia, Comment, Report, ReportMedia,
                    ReportPortalUser, ReportMessage, SiteText, Announcement, BannedIP)

db.init_app(app)
login_manager = LoginManager(app)
login_manager.login_view = 'login'
login_manager.login_message = 'Please log in to access this page.'
login_manager.login_message_category = 'info'

# ─── Helpers ────────────────────────────────────────────────────────────────

@login_manager.user_loader
def load_user(uid):
    return User.query.get(int(uid))

def allowed_file(filename):
    return '.' in filename and filename.rsplit('.', 1)[1].lower() in ALLOWED_ALL

def get_file_type(filename):
    ext = filename.rsplit('.', 1)[1].lower() if '.' in filename else ''
    return 'image' if ext in ALLOWED_IMAGES else 'document'

def save_upload(file, subfolder):
    if not file or not file.filename:
        return None, None
    if not allowed_file(file.filename):
        return None, None
    ext = file.filename.rsplit('.', 1)[1].lower()
    fname = str(uuid.uuid4()) + '.' + ext
    dest = os.path.join(app.config['UPLOAD_FOLDER'], subfolder)
    os.makedirs(dest, exist_ok=True)
    file.save(os.path.join(dest, fname))
    ftype = 'image' if ext in ALLOWED_IMAGES else 'document'
    return subfolder + '/' + fname, ftype

def get_ip():
    # Only trust X-Forwarded-For if explicitly running behind a proxy (set TRUST_PROXY=1 env var)
    if os.environ.get("TRUST_PROXY") == "1":
        forwarded = request.headers.get("X-Forwarded-For", "")
        if forwarded:
            return forwarded.split(",")[0].strip()
    return request.remote_addr

def is_ip_banned():
    return BannedIP.query.filter_by(ip_address=get_ip()).first() is not None


def is_safe_redirect(target):
    """Prevent open redirect - only allow relative URLs on the same host."""
    if not target:
        return False
    ref_url = urlparse(request.host_url)
    test_url = urlparse(urljoin(request.host_url, target))
    return test_url.scheme in ("http", "https") and ref_url.netloc == test_url.netloc

def get_text(page, key, default=''):
    t = SiteText.query.filter_by(page=page, key=key).first()
    return t.value if t else default

def admin_required(f):
    @wraps(f)
    def dec(*a, **kw):
        if not current_user.is_authenticated or not current_user.is_admin:
            abort(403)
        return f(*a, **kw)
    return dec

@app.context_processor
def globals():
    page = request.endpoint or ''
    anns = Announcement.query.filter(
        Announcement.is_active == True,
        db.or_(Announcement.target_page == 'all', Announcement.target_page == page)
    ).all()
    return dict(get_text=get_text, announcements=anns,
                portal_logged_in='portal_user_id' in session,
                portal_username=session.get('portal_username', ''))

@app.before_request
def check_ban():
    if is_ip_banned() and not request.path.startswith('/static'):
        return render_template('banned.html'), 403

# ─── Auth ────────────────────────────────────────────────────────────────────

@app.route('/register', methods=['GET', 'POST'])
def register():
    if current_user.is_authenticated:
        return redirect(url_for('index'))
    if request.method == 'POST':
        username = request.form.get('username', '').strip()
        if _rate_limited(get_ip()):
            flash("Too many attempts. Please wait a few minutes before trying again.", "error")
            return redirect(url_for("register"))
        email    = request.form.get('email', '').strip().lower()
        password = request.form.get('password', '')
        confirm  = request.form.get('confirm', '')
        pin      = request.form.get('pin', '').strip()

        if len(username) < 3:
            flash('Username must be at least 3 characters.', 'error')
            return redirect(url_for('register'))
        if User.query.filter_by(username=username).first():
            flash('Username already taken.', 'error')
            return redirect(url_for('register'))
        if User.query.filter_by(email=email).first():
            flash('Email already registered.', 'error')
            return redirect(url_for('register'))
        if password != confirm:
            flash('Passwords do not match.', 'error')
            return redirect(url_for('register'))
        if len(password) < 6:
            flash('Password must be at least 6 characters.', 'error')
            return redirect(url_for('register'))
        if not pin.isdigit() or len(pin) < 4:
            flash('PIN must be at least 4 digits.', 'error')
            return redirect(url_for('register'))

        user = User(
            username=username,
            email=email,
            password_hash=generate_password_hash(password),
            pin=pin,
            ip_address=get_ip()
        )

        proof = request.files.get('proof_file')
        if proof and proof.filename:
            path, ftype = save_upload(proof, 'proofs')
            if path:
                user.proof_file = path
                user.proof_type = ftype

        db.session.add(user)
        db.session.commit()
        login_user(user)
        flash('Account created! Welcome.', 'success')
        return redirect(url_for('index'))
    return render_template('register.html')


@app.route('/login', methods=['GET', 'POST'])
def login():
    if current_user.is_authenticated:
        return redirect(url_for('index'))
    if request.method == 'POST':
        username = request.form.get('username', '').strip()
        password = request.form.get('password', '')
        user = User.query.filter_by(username=username).first()
        if not user or not check_password_hash(user.password_hash, password):
            flash('Invalid username or password.', 'error')
            return redirect(url_for('login'))
        if user.is_banned:
            flash(f'Your account has been suspended. Reason: {user.ban_reason or "N/A"}', 'error')
            return redirect(url_for('login'))
        # Update IP
        user.ip_address = get_ip()
        db.session.commit()
        login_user(user)
        next_page = request.args.get("next")
        return redirect(next_page if is_safe_redirect(next_page) else url_for("index"))
    return render_template('login.html')


@app.route('/logout')
@login_required
def logout():
    logout_user()
    flash('You have been logged out.', 'info')
    return redirect(url_for('index'))


# ─── Main Forum ──────────────────────────────────────────────────────────────

@app.route('/')
def index():
    page = request.args.get('page', 1, type=int)
    posts = Post.query.filter_by(forum_type='main').filter(
        Post.status.in_(['active', 'verified_true'])
    ).order_by(Post.created_at.desc()).paginate(page=page, per_page=15)
    return render_template('index.html', posts=posts)


@app.route('/post/<post_id>')
def post_detail(post_id):
    post = Post.query.filter_by(post_id=post_id).first_or_404()
    if post.status in ('removed', 'hidden') and not (current_user.is_authenticated and current_user.is_admin):
        abort(404)
    comments = Comment.query.filter_by(post_id=post.id, is_hidden=False).order_by(Comment.created_at.asc()).all()
    return render_template('post_detail.html', post=post, comments=comments)


@app.route('/create-post', methods=['GET', 'POST'])
@login_required
def create_post():
    if current_user.is_banned:
        flash('Your account is suspended.', 'error')
        return redirect(url_for('index'))
    if request.method == 'POST':
        if not request.form.get('rules_accepted'):
            flash('You must accept the community rules before posting.', 'error')
            return redirect(url_for('create_post'))

        title   = request.form.get('title', '').strip()
        content = request.form.get('content', '').strip()
        if not title or not content:
            flash('Title and content are required.', 'error')
            return redirect(url_for('create_post'))

        post = Post(title=title, content=content, forum_type='main', user_id=current_user.id)
        db.session.add(post)
        db.session.flush()  # get post.id

        files = request.files.getlist('photos')
        for f in files[:5]:
            if f and f.filename:
                path, ftype = save_upload(f, 'posts')
                if path:
                    db.session.add(PostMedia(post_id=post.id, filename=path, media_type=ftype, approved=True))

        db.session.commit()
        flash('Your post has been published.', 'success')
        return redirect(url_for('post_detail', post_id=post.post_id))
    return render_template('create_post.html', forum_type='main')


@app.route('/post/<post_id>/edit', methods=['GET', 'POST'])
@login_required
def edit_post(post_id):
    post = Post.query.filter_by(post_id=post_id).first_or_404()
    # Only the author (or admin) can edit
    if post.user_id != current_user.id and not current_user.is_admin:
        abort(403)
    if current_user.is_banned:
        flash('Your account is suspended.', 'error')
        return redirect(url_for('post_detail', post_id=post_id))
    if post.status in ('removed',):
        flash('This post has been removed and cannot be edited.', 'error')
        return redirect(url_for('post_detail', post_id=post_id))

    if request.method == 'POST':
        title   = request.form.get('title', '').strip()
        content = request.form.get('content', '').strip()
        if not title or not content:
            flash('Title and content are required.', 'error')
            return redirect(url_for('edit_post', post_id=post_id))

        post.title   = title
        post.content = content
        post.edited_at = datetime.utcnow()

        # Handle new file uploads (append, up to 5 total)
        existing_count = len([m for m in post.media if m.approved])
        files = request.files.getlist('photos')
        added = 0
        for f in files:
            if added + existing_count >= 5:
                break
            if f and f.filename:
                path, ftype = save_upload(f, 'posts')
                if path:
                    db.session.add(PostMedia(post_id=post.id, filename=path, media_type=ftype, approved=True))
                    added += 1

        # Handle media deletions
        delete_ids = request.form.getlist('delete_media')
        for mid in delete_ids:
            media = PostMedia.query.filter_by(id=int(mid), post_id=post.id).first()
            if media:
                db.session.delete(media)

        db.session.commit()
        flash('Your post has been updated.', 'success')
        return redirect(url_for('post_detail', post_id=post_id))

    return render_template('edit_post.html', post=post)


@app.route('/post/<post_id>/comment', methods=['POST'])
@login_required
def add_comment(post_id):
    post = Post.query.filter_by(post_id=post_id).first_or_404()
    content = request.form.get('content', '').strip()
    if not content:
        flash('Comment cannot be empty.', 'error')
    elif current_user.is_banned:
        flash('Your account is suspended.', 'error')
    else:
        db.session.add(Comment(content=content, user_id=current_user.id, post_id=post.id))
        db.session.commit()
        flash('Comment added.', 'success')
    return redirect(url_for('post_detail', post_id=post_id))


# ─── Advice Forum ────────────────────────────────────────────────────────────

@app.route('/advice')
def advice():
    page = request.args.get('page', 1, type=int)
    posts = Post.query.filter_by(forum_type='advice').filter(
        Post.status.in_(['active', 'verified_true'])
    ).order_by(Post.created_at.desc()).paginate(page=page, per_page=15)
    return render_template('advice.html', posts=posts)


@app.route('/advice/<post_id>')
def advice_detail(post_id):
    post = Post.query.filter_by(post_id=post_id, forum_type='advice').first_or_404()
    if post.status in ('removed', 'hidden') and not (current_user.is_authenticated and current_user.is_admin):
        abort(404)
    comments = Comment.query.filter_by(post_id=post.id, is_hidden=False).order_by(Comment.created_at.asc()).all()
    approved_media = [m for m in post.media if m.approved]
    return render_template('advice_detail.html', post=post, comments=comments, approved_media=approved_media)


@app.route('/advice/create', methods=['GET', 'POST'])
@login_required
def create_advice():
    if current_user.is_banned:
        flash('Your account is suspended.', 'error')
        return redirect(url_for('advice'))
    if request.method == 'POST':
        if not request.form.get('rules_accepted'):
            flash('You must accept the community rules before posting.', 'error')
            return redirect(url_for('create_advice'))
        title   = request.form.get('title', '').strip()
        content = request.form.get('content', '').strip()
        if not title or not content:
            flash('Title and content are required.', 'error')
            return redirect(url_for('create_advice'))

        post = Post(title=title, content=content, forum_type='advice',
                    post_id='ADV-' + str(uuid.uuid4()).replace('-','')[:8].upper(),
                    user_id=current_user.id)
        db.session.add(post)
        db.session.flush()

        auto_approve = current_user.advice_media_approved
        files = request.files.getlist('photos')
        for f in files[:5]:
            if f and f.filename:
                path, ftype = save_upload(f, 'advice')
                if path:
                    db.session.add(PostMedia(post_id=post.id, filename=path, media_type=ftype, approved=auto_approve))

        db.session.commit()
        flash('Your advice post has been published.', 'success')
        return redirect(url_for('advice_detail', post_id=post.post_id))
    return render_template('create_post.html', forum_type='advice')


@app.route('/advice/<post_id>/comment', methods=['POST'])
@login_required
def add_advice_comment(post_id):
    post = Post.query.filter_by(post_id=post_id, forum_type='advice').first_or_404()
    content = request.form.get('content', '').strip()
    if not content:
        flash('Comment cannot be empty.', 'error')
    elif current_user.is_banned:
        flash('Your account is suspended.', 'error')
    else:
        db.session.add(Comment(content=content, user_id=current_user.id, post_id=post.id))
        db.session.commit()
        flash('Comment added.', 'success')
    return redirect(url_for('advice_detail', post_id=post_id))


# ─── Profile ─────────────────────────────────────────────────────────────────

@app.route('/profile/<username>')
def profile(username):
    user = User.query.filter_by(username=username).first_or_404()
    posts = Post.query.filter_by(user_id=user.id).filter(
        Post.status.in_(['active', 'verified_true'])
    ).order_by(Post.created_at.desc()).all()
    return render_template('profile.html', profile_user=user, posts=posts)


@app.route('/profile/update-proof', methods=['POST'])
@login_required
def update_proof():
    f = request.files.get('proof_file')
    if f and f.filename:
        path, ftype = save_upload(f, 'proofs')
        if path:
            current_user.proof_file = path
            current_user.proof_type = ftype
            db.session.commit()
            flash('Proof updated.', 'success')
        else:
            flash('Invalid file type.', 'error')
    return redirect(url_for('profile', username=current_user.username))


# ─── Report System ───────────────────────────────────────────────────────────

@app.route('/report/submit', methods=['POST'])
def submit_report():
    post_ref_id   = request.form.get('post_ref_id', '').strip()
    is_anon       = request.form.get('is_anonymous') == '1'
    display_name  = request.form.get('display_name', '').strip()
    description   = request.form.get('description', '').strip()
    links         = request.form.get('links', '').strip()
    other_info    = request.form.get('other_info', '').strip()

    if not post_ref_id or not description:
        flash('Post ID and description are required.', 'error')
        return redirect(request.referrer or url_for('index'))

    post = Post.query.filter_by(post_id=post_ref_id).first()
    if not post:
        flash('Post not found.', 'error')
        return redirect(request.referrer or url_for('index'))

    portal_uid = session.get('portal_user_id')

    # Generate a claim token for unregistered reporters so they can claim later
    claim_token = None
    if not portal_uid:
        claim_token = str(uuid.uuid4()).replace('-', '')

    report = Report(
        post_id=post.id,
        post_ref_id=post_ref_id,
        portal_user_id=portal_uid,
        reporter_display_name=None if is_anon else (display_name or None),
        is_anonymous=is_anon,
        description=description,
        links=links or None,
        other_info=other_info or None,
        ip_address=get_ip(),
        claim_token=claim_token
    )
    db.session.add(report)
    db.session.flush()

    files = request.files.getlist('evidence')
    for f in files[:5]:
        if f and f.filename:
            path, ftype = save_upload(f, 'reports')
            if path:
                db.session.add(ReportMedia(report_id=report.id, filename=path, media_type=ftype))

    db.session.commit()

    if portal_uid:
        flash(f'Report submitted. Your report ID is {report.report_id}. You can track it in My Reports.', 'success')
    else:
        # Store the claim token temporarily in session so the next page can show it
        session['last_report_id'] = report.report_id
        session['last_claim_token'] = claim_token
        flash(f'Report submitted. Your report ID is {report.report_id}. Save this ID — you will need it to check your report status.', 'success')
    return redirect(url_for('portal_lookup'))


# ─── Report Portal ───────────────────────────────────────────────────────────

@app.route('/report-portal')
def report_portal():
    """Public landing page for the report portal."""
    portal_uid = session.get('portal_user_id')
    reports = []
    if portal_uid:
        reports = Report.query.filter_by(portal_user_id=portal_uid).order_by(Report.created_at.desc()).limit(5).all()
    return render_template('report_portal.html', reports=reports)


@app.route('/report-portal/register', methods=['GET', 'POST'])
def portal_register():
    if 'portal_user_id' in session:
        return redirect(url_for('portal_my_reports'))
    if request.method == 'POST':
        username = request.form.get('username', '').strip()
        password = request.form.get('password', '')
        confirm  = request.form.get('confirm', '')
        if len(username) < 3:
            flash('Username must be at least 3 characters.', 'error')
            return redirect(url_for('portal_register'))
        if ReportPortalUser.query.filter_by(username=username).first():
            flash('Username taken.', 'error')
            return redirect(url_for('portal_register'))
        if password != confirm or len(password) < 6:
            flash('Passwords do not match or too short.', 'error')
            return redirect(url_for('portal_register'))
        u = ReportPortalUser(username=username, password_hash=generate_password_hash(password))
        db.session.add(u)
        db.session.commit()
        session['portal_user_id'] = u.id
        session['portal_username'] = u.username
        flash('Report portal account created.', 'success')
        return redirect(url_for('portal_my_reports'))
    return render_template('portal_register.html')


@app.route('/report-portal/login', methods=['GET', 'POST'])
def portal_login():
    if 'portal_user_id' in session:
        return redirect(url_for('portal_my_reports'))
    if request.method == 'POST':
        username = request.form.get('username', '').strip()
        password = request.form.get('password', '')
        u = ReportPortalUser.query.filter_by(username=username).first()
        if not u or not check_password_hash(u.password_hash, password):
            flash('Invalid credentials.', 'error')
            return redirect(url_for('portal_login'))
        session['portal_user_id'] = u.id
        session['portal_username'] = u.username
        return redirect(url_for('portal_my_reports'))
    return render_template('portal_login.html')


@app.route('/report-portal/logout')
def portal_logout():
    session.pop('portal_user_id', None)
    session.pop('portal_username', None)
    flash('Logged out of report portal.', 'info')
    return redirect(url_for('index'))


@app.route('/report-portal/my-reports')
def portal_my_reports():
    if 'portal_user_id' not in session:
        return redirect(url_for('portal_login'))
    reports = Report.query.filter_by(portal_user_id=session['portal_user_id']).order_by(Report.created_at.desc()).all()
    return render_template('portal_my_reports.html', reports=reports)


@app.route('/report-portal/lookup-json', methods=['POST'])
def portal_lookup_json():
    """JSON endpoint used by the inline homepage lookup widget."""
    data = request.get_json(silent=True) or {}
    rp_id = data.get('report_id', '').strip().upper()

    if not rp_id:
        return jsonify({'error': 'Please enter a Report ID.'}), 400

    report = Report.query.filter_by(report_id=rp_id).first()
    if not report:
        return jsonify({'error': f'No report found with ID "{rp_id}". Please check and try again.'}), 404

    messages = [{
        'id':        m.id,
        'sender':    m.sender,
        'is_read':   m.is_read,
        'created_at': m.created_at.strftime('%d %b %Y %H:%M'),
    } for m in report.messages]

    return jsonify({
        'report_id':   report.report_id,
        'post_ref_id': report.post_ref_id,
        'status':      report.status,
        'admin_seen':  report.admin_seen,
        'admin_reply': report.admin_reply or '',
        'claim_token': report.claim_token or '',
        'created_at':  report.created_at.strftime('%d %b %Y'),
        'messages':    messages,
    })


@app.route('/report-portal/lookup', methods=['GET', 'POST'])
def portal_lookup():
    """Public lookup by RP ID — no login required."""
    report = None
    error  = None

    # Pre-fill from session if redirected after submit
    prefill_id    = session.pop('last_report_id', None)
    prefill_token = session.pop('last_claim_token', None)

    if request.method == 'POST':
        rp_id = request.form.get('report_id', '').strip().upper()
        report = Report.query.filter_by(report_id=rp_id).first()
        if not report:
            error = f'No report found with ID "{rp_id}". Please check and try again.'

    return render_template('portal_lookup.html',
                           report=report,
                           error=error,
                           prefill_id=prefill_id,
                           prefill_token=prefill_token)


@app.route('/report-portal/report/<report_id>')
def portal_report_view(report_id):
    """Full ticket view — requires portal login or valid claim token."""
    report = Report.query.filter_by(report_id=report_id).first_or_404()

    # Check access: must be logged-in portal owner OR have the claim token
    portal_uid = session.get('portal_user_id')
    claim_token = request.args.get('token', '')

    has_access = (
        (portal_uid and report.portal_user_id == portal_uid) or
        (claim_token and report.claim_token and claim_token == report.claim_token) or
        (portal_uid and report.portal_user_id is None and not report.claim_token)  # admin-linked
    )

    if not has_access:
        flash('You do not have access to this report. Please log in or use the correct link.', 'error')
        return redirect(url_for('portal_lookup'))

    # Mark unread reporter-side messages as read
    for msg in report.messages:
        if msg.sender == 'admin' and not msg.is_read:
            msg.is_read = True
    db.session.commit()

    return render_template('portal_report_view.html',
                           report=report,
                           claim_token=claim_token)


@app.route('/report-portal/report/<report_id>/messages.json')
def portal_messages_json(report_id):
    """Returns latest messages + status for live polling."""
    report = Report.query.filter_by(report_id=report_id).first_or_404()

    portal_uid  = session.get('portal_user_id')
    claim_token = request.args.get('token', '')

    has_access = (
        (portal_uid and report.portal_user_id == portal_uid) or
        (claim_token and report.claim_token and claim_token == report.claim_token) or
        (current_user.is_authenticated and current_user.is_admin)
    )
    if not has_access:
        return jsonify({'error': 'forbidden'}), 403

    messages = []
    for msg in report.messages:
        messages.append({
            'id':           msg.id,
            'sender':       msg.sender,
            'sender_label': msg.sender_label or ('Admin Team' if msg.sender == 'admin' else 'You'),
            'content':      msg.content,
            'is_read':      msg.is_read,
            'created_at':   msg.created_at.strftime('%d %b %Y %H:%M'),
        })

    # Auto-mark admin messages as read for reporter
    if not (current_user.is_authenticated and current_user.is_admin):
        changed = False
        for msg in report.messages:
            if msg.sender == 'admin' and not msg.is_read:
                msg.is_read = True
                changed = True
        if changed:
            db.session.commit()

    return jsonify({
        'report_id': report.report_id,
        'status':    report.status,
        'admin_seen': report.admin_seen,
        'admin_reply': report.admin_reply or '',
        'messages':  messages,
    })


@app.route('/report-portal/report/<report_id>/reply', methods=['POST'])
def portal_reply(report_id):
    """Reporter sends a message in the ticket thread."""
    report = Report.query.filter_by(report_id=report_id).first_or_404()

    portal_uid  = session.get('portal_user_id')
    claim_token = request.form.get('claim_token', '')

    has_access = (
        (portal_uid and report.portal_user_id == portal_uid) or
        (claim_token and report.claim_token and claim_token == report.claim_token)
    )
    if not has_access:
        flash('Access denied.', 'error')
        return redirect(url_for('portal_lookup'))

    content = request.form.get('content', '').strip()
    if not content:
        flash('Message cannot be empty.', 'error')
    else:
        label = session.get('portal_username', 'Reporter')
        if not portal_uid:
            label = 'Reporter (unregistered)'
        db.session.add(ReportMessage(
            report_id=report.id,
            sender='reporter',
            sender_label=label,
            content=content,
            is_read=False
        ))
        # Reset to pending/seen so admin knows there's a new message
        if report.status == 'resolved':
            report.status = 'seen'
        report.admin_seen = False
        db.session.commit()
        flash('Message sent to the admin team.', 'success')

    return redirect(url_for('portal_report_view', report_id=report_id, token=claim_token))


@app.route('/report-portal/claim/<report_id>', methods=['GET', 'POST'])
def portal_claim(report_id):
    """Let an unregistered reporter create a portal account and claim their report."""
    report = Report.query.filter_by(report_id=report_id).first_or_404()
    token  = request.args.get('token', '') or request.form.get('claim_token', '')

    if not token or report.claim_token != token:
        flash('Invalid claim link.', 'error')
        return redirect(url_for('portal_lookup'))

    if 'portal_user_id' in session:
        # Already logged in — just link and redirect
        if not report.portal_user_id:
            report.portal_user_id = session['portal_user_id']
            report.claim_token = None
            db.session.commit()
        return redirect(url_for('portal_report_view', report_id=report_id))

    if request.method == 'POST':
        username = request.form.get('username', '').strip()
        password = request.form.get('password', '')
        confirm  = request.form.get('confirm', '')

        if len(username) < 3:
            flash('Username must be at least 3 characters.', 'error')
            return redirect(url_for('portal_claim', report_id=report_id, token=token))
        if ReportPortalUser.query.filter_by(username=username).first():
            flash('Username already taken.', 'error')
            return redirect(url_for('portal_claim', report_id=report_id, token=token))
        if password != confirm or len(password) < 6:
            flash('Passwords do not match or are too short (minimum 6 characters).', 'error')
            return redirect(url_for('portal_claim', report_id=report_id, token=token))

        u = ReportPortalUser(username=username, password_hash=generate_password_hash(password))
        db.session.add(u)
        db.session.flush()

        # Link the report to this new account
        report.portal_user_id = u.id
        report.claim_token = None
        db.session.commit()

        session['portal_user_id'] = u.id
        session['portal_username'] = u.username
        flash('Account created and report linked successfully! You can now track and reply to your report.', 'success')
        return redirect(url_for('portal_report_view', report_id=report_id))

    return render_template('portal_claim.html', report=report, token=token)




# ─── File Serving ────────────────────────────────────────────────────────────

@app.route('/uploads/<path:filename>')
def uploaded_file(filename):
    return send_from_directory(app.config['UPLOAD_FOLDER'], filename)


# ─── Admin ───────────────────────────────────────────────────────────────────

@app.route('/admin')
@login_required
@admin_required
def admin_dashboard():
    stats = {
        'users':   User.query.count(),
        'posts':   Post.query.count(),
        'reports': Report.query.count(),
        'pending': Report.query.filter_by(status='pending').count(),
        'banned':  User.query.filter_by(is_banned=True).count(),
        'banned_ips': BannedIP.query.count(),
    }
    recent_reports = Report.query.filter_by(admin_seen=False).order_by(Report.created_at.desc()).limit(10).all()
    recent_posts   = Post.query.order_by(Post.created_at.desc()).limit(10).all()
    return render_template('admin/dashboard.html', stats=stats, recent_reports=recent_reports, recent_posts=recent_posts)


@app.route('/admin/users')
@login_required
@admin_required
def admin_users():
    q = request.args.get('q', '')
    query = User.query
    if q:
        query = query.filter(db.or_(User.username.ilike(f'%{q}%'), User.email.ilike(f'%{q}%'), User.ip_address.ilike(f'%{q}%')))
    users = query.order_by(User.created_at.desc()).paginate(page=request.args.get('page',1,int), per_page=20)
    return render_template('admin/users.html', users=users, q=q)


@app.route('/admin/user/<int:user_id>')
@login_required
@admin_required
def admin_user_detail(user_id):
    user = User.query.get_or_404(user_id)
    posts = Post.query.filter_by(user_id=user_id).order_by(Post.created_at.desc()).all()
    return render_template('admin/user_detail.html', u=user, posts=posts)


@app.route('/admin/user/<int:user_id>/ban', methods=['POST'])
@login_required
@admin_required
def admin_ban_user(user_id):
    user = User.query.get_or_404(user_id)
    user.is_banned = True
    user.ban_reason = request.form.get('reason', 'Violation of terms')
    db.session.commit()
    flash(f'User {user.username} banned.', 'success')
    return redirect(url_for('admin_user_detail', user_id=user_id))


@app.route('/admin/user/<int:user_id>/unban', methods=['POST'])
@login_required
@admin_required
def admin_unban_user(user_id):
    user = User.query.get_or_404(user_id)
    user.is_banned = False
    user.ban_reason = None
    db.session.commit()
    flash(f'User {user.username} unbanned.', 'success')
    return redirect(url_for('admin_user_detail', user_id=user_id))


@app.route('/admin/user/<int:user_id>/reset-password', methods=['POST'])
@login_required
@admin_required
def admin_reset_password(user_id):
    user = User.query.get_or_404(user_id)
    new_pw = request.form.get('new_password', '').strip()
    if len(new_pw) < 6:
        flash('New password too short.', 'error')
    else:
        user.password_hash = generate_password_hash(new_pw)
        db.session.commit()
        flash('Password reset.', 'success')
    return redirect(url_for('admin_user_detail', user_id=user_id))


@app.route('/admin/user/<int:user_id>/toggle-media', methods=['POST'])
@login_required
@admin_required
def admin_toggle_media(user_id):
    user = User.query.get_or_404(user_id)
    user.advice_media_approved = not user.advice_media_approved
    db.session.commit()
    flash(f'Advice media approval toggled for {user.username}.', 'success')
    return redirect(url_for('admin_user_detail', user_id=user_id))


@app.route('/admin/user/<int:user_id>/make-admin', methods=['POST'])
@login_required
@admin_required
def admin_make_admin(user_id):
    user = User.query.get_or_404(user_id)
    user.is_admin = not user.is_admin
    db.session.commit()
    flash(f'Admin status toggled for {user.username}.', 'success')
    return redirect(url_for('admin_user_detail', user_id=user_id))


@app.route('/admin/user/<int:user_id>/delete', methods=['POST'])
@login_required
@admin_required
def admin_delete_user(user_id):
    user = User.query.get_or_404(user_id)
    username = user.username
    # Anonymize their posts rather than deleting
    for post in user.posts:
        post.content = '[Account deleted]'
    db.session.delete(user)
    db.session.commit()
    flash(f'User {username} deleted.', 'success')
    return redirect(url_for('admin_users'))


@app.route('/admin/ban-ip', methods=['POST'])
@login_required
@admin_required
def admin_ban_ip():
    ip = request.form.get('ip_address', '').strip()
    reason = request.form.get('reason', '')
    if ip:
        existing = BannedIP.query.filter_by(ip_address=ip).first()
        if not existing:
            db.session.add(BannedIP(ip_address=ip, reason=reason))
            db.session.commit()
            flash(f'IP {ip} banned.', 'success')
        else:
            flash('IP already banned.', 'info')
    return redirect(request.referrer or url_for('admin_dashboard'))


@app.route('/admin/unban-ip/<int:ip_id>', methods=['POST'])
@login_required
@admin_required
def admin_unban_ip(ip_id):
    entry = BannedIP.query.get_or_404(ip_id)
    db.session.delete(entry)
    db.session.commit()
    flash('IP unbanned.', 'success')
    return redirect(url_for('admin_banned_ips'))


@app.route('/admin/banned-ips')
@login_required
@admin_required
def admin_banned_ips():
    ips = BannedIP.query.order_by(BannedIP.created_at.desc()).all()
    return render_template('admin/banned_ips.html', ips=ips)


@app.route('/admin/posts')
@login_required
@admin_required
def admin_posts():
    q = request.args.get('q', '')
    ftype = request.args.get('type', 'all')
    query = Post.query
    if q:
        query = query.filter(db.or_(Post.post_id.ilike(f'%{q}%'), Post.title.ilike(f'%{q}%')))
    if ftype != 'all':
        query = query.filter_by(forum_type=ftype)
    posts = query.order_by(Post.created_at.desc()).paginate(page=request.args.get('page',1,int), per_page=20)
    return render_template('admin/posts.html', posts=posts, q=q, ftype=ftype)


@app.route('/admin/post/<post_id>/action', methods=['POST'])
@login_required
@admin_required
def admin_post_action(post_id):
    post = Post.query.filter_by(post_id=post_id).first_or_404()
    action = request.form.get('action')
    if action == 'hide':
        post.status = 'hidden'
    elif action == 'show':
        post.status = 'active'
    elif action == 'remove':
        post.status = 'removed'
    elif action == 'verify_true':
        post.status = 'verified_true'
        post.tag = 'VERIFIED TRUE'
    elif action == 'tag':
        post.tag = request.form.get('tag_text', '').strip()[:50]
    elif action == 'delete':
        # Preserve reports — detach them from this post using raw SQL to avoid NOT NULL
        # (post_ref_id already stores the string ID so reports remain accessible)
        import sqlite3
        db.session.execute(
            db.text('UPDATE reports SET post_id = NULL WHERE post_id = :pid'),
            {'pid': post.id}
        )
        db.session.flush()
        db.session.delete(post)
        db.session.commit()
        flash('Post deleted. Any associated reports have been preserved.', 'success')
        return redirect(url_for('admin_posts'))
    elif action == 'redact':
        find_text    = request.form.get('find_text', '')
        replace_with = request.form.get('replace_with', '[REDACTED]')
        if find_text:
            post.content = post.content.replace(find_text, replace_with)
            post.title   = post.title.replace(find_text, replace_with)
    db.session.commit()
    flash('Post updated.', 'success')
    return redirect(url_for('admin_posts'))


@app.route('/admin/advice-media/<int:media_id>/approve', methods=['POST'])
@login_required
@admin_required
def admin_approve_media(media_id):
    media = PostMedia.query.get_or_404(media_id)
    media.approved = True
    db.session.commit()
    flash('Media approved.', 'success')
    return redirect(request.referrer or url_for('admin_posts'))


@app.route('/admin/reports')
@login_required
@admin_required
def admin_reports():
    status_filter = request.args.get('status', 'all')
    query = Report.query
    if status_filter != 'all':
        query = query.filter_by(status=status_filter)
    reports = query.order_by(Report.created_at.desc()).paginate(page=request.args.get('page',1,int), per_page=20)
    return render_template('admin/reports.html', reports=reports, status_filter=status_filter)


@app.route('/admin/report/<report_id>', methods=['GET', 'POST'])
@login_required
@admin_required
def admin_report_detail(report_id):
    report = Report.query.filter_by(report_id=report_id).first_or_404()
    report.admin_seen = True
    db.session.commit()
    if request.method == 'POST':
        report.admin_reply = request.form.get('reply', '').strip()
        report.status      = request.form.get('status', report.status)
        db.session.commit()
        flash('Report updated.', 'success')
        return redirect(url_for('admin_report_detail', report_id=report_id))
    return render_template('admin/report_detail.html', report=report)


@app.route('/admin/report/<report_id>/message', methods=['POST'])
@login_required
@admin_required
def admin_report_message(report_id):
    """Admin sends a private ticket message to the reporter."""
    report = Report.query.filter_by(report_id=report_id).first_or_404()
    content = request.form.get('content', '').strip()
    if content:
        db.session.add(ReportMessage(
            report_id=report.id,
            sender='admin',
            sender_label='Admin Team',
            content=content,
            is_read=False
        ))
        report.admin_seen = True
        if report.status == 'pending':
            report.status = 'seen'
        db.session.commit()
        flash('Message sent to reporter.', 'success')
    return redirect(url_for('admin_report_detail', report_id=report_id))


@app.route('/admin/site-text', methods=['GET', 'POST'])
@login_required
@admin_required
def admin_site_text():
    DEFAULTS = {
        ('global', 'site_name'):        'ClearVoice',
        ('global', 'site_tagline'):     'A safe space to share your story',
        ('global', 'footer_text'):      '© ClearVoice — A platform for those who have been falsely accused.',
        ('index', 'hero_title'):        'Share Your Story',
        ('index', 'hero_subtitle'):     'For those whose cases have been officially closed.',
        ('index', 'intro_text'):        'This platform exists for individuals who have experienced false allegations and whose cases have been officially closed. Your story matters.',
        ('advice', 'hero_title'):       'Advice Forum',
        ('advice', 'hero_subtitle'):    'Seeking or offering guidance on active situations.',
        ('advice', 'intro_text'):       'This is a space to ask for advice about ongoing situations. Your case is still active? This is the right place. Please do not post your closed case story here.',
        ('rules', 'title'):             'Community Rules',
        ('rules', 'body'):              'By posting, you agree to the following:\n\n• DO NOT use real full legal names — use initials (e.g. J.S.) or pseudonyms only. This is for GDPR compliance and to prevent doxxing.\n• This platform is for individuals whose cases have been officially closed.\n• Do not post to gain sympathy or manipulate public opinion.\n• Do not post if your case is still active — use the Advice Forum instead.\n• Do not post content that targets, harasses, or threatens any individual.\n• Violation of these rules may result in a permanent ban and referral to law enforcement.',
        ('register', 'intro'):          'Create your account to share your story. All fields are required.',
        ('login',    'intro'):          'Welcome back. Please log in to continue.',
        ('report',   'popup_intro'):    'Reports are reviewed by our admin team within 24 hours. You may submit anonymously or sign in with a report portal account.',
    }
    # Ensure defaults exist
    for (page, key), val in DEFAULTS.items():
        if not SiteText.query.filter_by(page=page, key=key).first():
            db.session.add(SiteText(page=page, key=key, value=val))
    db.session.commit()

    if request.method == 'POST':
        for (page, key) in DEFAULTS.keys():
            field_name = f'{page}__{key}'
            val = request.form.get(field_name)
            if val is not None:
                t = SiteText.query.filter_by(page=page, key=key).first()
                if t:
                    t.value = val
                    t.updated_at = datetime.utcnow()
        db.session.commit()
        flash('Site text updated.', 'success')
        return redirect(url_for('admin_site_text'))

    texts = {f'{t.page}__{t.key}': t.value for t in SiteText.query.all()}
    return render_template('admin/site_text.html', texts=texts, defaults=DEFAULTS)


@app.route('/admin/announcements', methods=['GET', 'POST'])
@login_required
@admin_required
def admin_announcements():
    if request.method == 'POST':
        action = request.form.get('action')
        if action == 'create':
            a = Announcement(
                title       = request.form.get('title', '').strip(),
                content     = request.form.get('content', '').strip(),
                target_page = request.form.get('target_page', 'all'),
                ann_type    = request.form.get('ann_type', 'info'),
                is_active   = True
            )
            db.session.add(a)
            db.session.commit()
            flash('Announcement created.', 'success')
        elif action == 'toggle':
            ann = Announcement.query.get(request.form.get('ann_id', type=int))
            if ann:
                ann.is_active = not ann.is_active
                db.session.commit()
                flash('Announcement toggled.', 'success')
        elif action == 'delete':
            ann = Announcement.query.get(request.form.get('ann_id', type=int))
            if ann:
                db.session.delete(ann)
                db.session.commit()
                flash('Announcement deleted.', 'success')
    anns = Announcement.query.order_by(Announcement.created_at.desc()).all()
    return render_template('admin/announcements.html', announcements=anns)


# ─── Error Handlers ──────────────────────────────────────────────────────────

@app.errorhandler(403)
def err_403(e):
    return render_template('errors/403.html'), 403

@app.errorhandler(404)
def err_404(e):
    return render_template('errors/404.html'), 404


# ─── Init ────────────────────────────────────────────────────────────────────

def run_migrations():
    """Safely add any missing columns/tables to an existing database."""
    import sqlite3
    # Find the actual db file
    db_path = os.path.join(os.path.dirname(__file__), 'instance', 'forum.db')
    if not os.path.exists(db_path):
        db_path = os.path.join(os.path.dirname(__file__), 'forum.db')
    if not os.path.exists(db_path):
        return  # Brand new DB — create_all will handle it

    conn = sqlite3.connect(db_path)
    cur  = conn.cursor()

    # ── reports table new columns ──
    cur.execute("PRAGMA table_info(reports)")
    report_cols = [r[1] for r in cur.fetchall()]

    needed = [
        ("claim_token",  "TEXT"),
        ("updated_at",   "DATETIME"),
    ]
    for col, coltype in needed:
        if col not in report_cols:
            cur.execute(f"ALTER TABLE reports ADD COLUMN {col} {coltype}")
            print(f"  [migrate] Added column reports.{col}")

    # ── posts table new columns ──
    cur.execute("PRAGMA table_info(posts)")
    post_cols = [r[1] for r in cur.fetchall()]
    if "edited_at" not in post_cols:
        cur.execute("ALTER TABLE posts ADD COLUMN edited_at DATETIME")
        print("  [migrate] Added column posts.edited_at")

    # ── report_messages table ──
    cur.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='report_messages'")
    if not cur.fetchone():
        cur.execute("""
            CREATE TABLE report_messages (
                id           INTEGER PRIMARY KEY AUTOINCREMENT,
                report_id    INTEGER NOT NULL REFERENCES reports(id),
                sender       VARCHAR(10) NOT NULL,
                sender_label VARCHAR(80),
                content      TEXT NOT NULL,
                is_read      BOOLEAN DEFAULT 0,
                created_at   DATETIME DEFAULT CURRENT_TIMESTAMP
            )
        """)
        print("  [migrate] Created table report_messages")

    conn.commit()
    conn.close()


def create_tables():
    with app.app_context():
        run_migrations()          # ← fix existing DB first
        db.create_all()           # ← then create any brand-new tables
        # Create default admin if none exists
        if not User.query.filter_by(is_admin=True).first():
            admin = User(
                username='admin',
                email='admin@clearvoice.local',
                password_hash=generate_password_hash('admin123'),
                pin='0000',
                is_admin=True,
                ip_address='127.0.0.1'
            )
            db.session.add(admin)
            db.session.commit()
            print('Default admin created: admin / admin123 — CHANGE THIS PASSWORD IMMEDIATELY')

if __name__ == '__main__':
    create_tables()
    app.run(host='0.0.0.0', port=5003, debug=True)
