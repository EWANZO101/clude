# ClearVoice — Community Forum Platform

A safe, anonymous platform for individuals whose false allegation cases have been officially closed to share their stories, seek advice, and connect with others.

---

## Features

### Public Forum
- **Stories Forum** — For users with officially closed cases
- **Advice Forum** — For active situations seeking guidance
- Anonymous posting using initials/pseudonyms (no full legal names)
- Unique Post IDs (e.g. `FA-A1B2C3D4` for stories, `ADV-XXXXXXXX` for advice)
- Photo and document attachments per post (up to 5 files, 20MB)
- Comment system on all posts
- Mandatory rules acceptance popup before every post

### User Accounts
- Register with username, email, password, and a 4–10 digit support PIN
- Optional proof of innocence document/photo upload on profile
- View own and others' profiles
- Update proof of innocence at any time

### Report System
- ⚑ Report button on every post opens a pre-filled popup with Post ID
- Submit anonymously or with a display name
- Upload up to 5 evidence files (photos/documents)
- Provide links and additional notes
- **Report Portal** — Separate lightweight account (username + password only) to track report status
- Reports tracked: `pending → seen → resolved/dismissed`
- Admin reply visible in the reporter's portal within 24 hours

### Admin Panel (`/admin`)
- **Dashboard** with stats and unseen report alerts
- **User Management** — Search by username, email, or IP; view all details including PIN
- **Per-User Actions** — Ban/unban, reset password, toggle advice media approval, promote/demote admin, delete account, ban IP
- **Post Management** — Search by Post ID or title, filter by type; hide/show/remove/verify/tag/delete posts
- **Find & Replace / Redact** — Blank out specific text (e.g. real names) in any post
- **Report Management** — Filter by status, reply to reporters, update status
- **Advice Media Approval** — Per-user toggle: auto-approve or require admin approval for advice attachments
- **Announcements** — Create colour-coded banners shown site-wide or on specific pages
- **Site Text Editor** — Edit every piece of text on the platform: hero titles, rules, footer, auth page intros, report popup text
- **IP Ban Management** — Ban and unban IPs with reasons; banned IPs see a block page

---

## Quick Start

### 1. Install dependencies

```bash
pip install -r requirements.txt
```

### 2. Run the app

```bash
python app.py
```

The app will start at `http://localhost:5000`

### 3. Default admin account

| Field    | Value          |
|----------|----------------|
| Username | `admin`        |
| Password | `admin123`     |
| Email    | `admin@clearvoice.local` |

**⚠ Change this password immediately after first login via the Admin → User Detail page.**

---

## Configuration

Edit `app.py` top section or use environment variables for production:

```python
app.config['SECRET_KEY'] = 'your-secret-key-here'  # Change this!
app.config['SQLALCHEMY_DATABASE_URI'] = 'sqlite:///forum.db'  # Or PostgreSQL
app.config['MAX_CONTENT_LENGTH'] = 20 * 1024 * 1024  # 20MB upload limit
```

For production, use a strong random `SECRET_KEY`:
```bash
python -c "import secrets; print(secrets.token_hex(32))"
```

---

## File Structure

```
forum/
├── app.py                  # Main Flask application & all routes
├── models.py               # Database models
├── requirements.txt        # Python dependencies
├── static/
│   └── uploads/
│       ├── posts/          # Story post attachments
│       ├── advice/         # Advice post attachments
│       ├── proofs/         # User proof of innocence uploads
│       └── reports/        # Report evidence files
└── templates/
    ├── base.html           # Base layout with nav, flash messages, report modal
    ├── index.html          # Stories forum index
    ├── advice.html         # Advice forum index
    ├── post_detail.html    # Story post detail + comments
    ├── advice_detail.html  # Advice post detail + comments
    ├── create_post.html    # Create post (both forum types) with rules modal
    ├── register.html       # User registration
    ├── login.html          # User login
    ├── profile.html        # User profile with proof display
    ├── portal_register.html # Report portal registration
    ├── portal_login.html   # Report portal login
    ├── portal_my_reports.html # Reporter's report tracking
    ├── banned.html         # Shown to IP-banned users
    ├── errors/
    │   ├── 403.html
    │   └── 404.html
    └── admin/
        ├── _sidebar.html   # Admin navigation sidebar
        ├── dashboard.html  # Admin dashboard
        ├── users.html      # Users list
        ├── user_detail.html # Individual user management
        ├── posts.html      # Posts list + management
        ├── reports.html    # Reports list
        ├── report_detail.html # Individual report + reply
        ├── announcements.html # Announcement management
        ├── site_text.html  # Site-wide text editor
        └── banned_ips.html # IP ban management
```

---

## Admin Guide

### Managing a Report
1. Go to `/admin/reports`
2. Click a report to open it — the reporter is notified it's been seen
3. Write a reply and update the status
4. The reporter sees your reply in their Report Portal within seconds

### Redacting Real Names
If a user posts a real full name:
1. Go to `/admin/posts`
2. Search for the post by ID
3. Expand "Redact / Find & Replace text"
4. Enter the real name to find and replace with initials or `[REDACTED]`
5. Optionally ban the user from their User Detail page

### Advice Media Approval
- By default, files uploaded to advice posts require admin approval
- To auto-approve a trusted user's uploads: Admin → User Detail → "Approve Advice Media Uploads"
- Pending media is shown to admins on the advice post detail page

### Customising All Text
Go to `/admin` → "Edit Site Text" to change:
- Site name, tagline, footer
- Hero headings and intro paragraphs
- Full community rules text
- Report popup wording
- Register/login page intros

---

## Security Notes

- All file uploads are UUID-renamed to prevent path traversal
- IP addresses are logged for all users and reporters
- Banned IPs are blocked at the request level
- Passwords are hashed with Werkzeug (PBKDF2-SHA256)
- Users have a support PIN for identity verification by admins
- The admin panel requires `is_admin=True` on the user record

---

## Production Deployment

For production, replace SQLite with PostgreSQL and use a WSGI server:

```bash
pip install gunicorn psycopg2-binary
gunicorn -w 4 -b 0.0.0.0:5000 app:app
```

Set these environment variables:
```
SECRET_KEY=your-random-secret-key
DATABASE_URL=postgresql://user:pass@localhost/clearvoice
```
