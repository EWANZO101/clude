from datetime import datetime
from urllib.parse import urlparse
from app import db

CATEGORY_RULES = {
    'Social Media': ['facebook.com', 'twitter.com', 'x.com', 'instagram.com', 'tiktok.com', 'reddit.com', 'linkedin.com', 'snapchat.com', 'pinterest.com'],
    'Communication': ['gmail.com', 'mail.google.com', 'outlook.com', 'slack.com', 'teams.microsoft.com', 'zoom.us', 'discord.com', 'whatsapp.com'],
    'Entertainment': ['youtube.com', 'netflix.com', 'twitch.tv', 'spotify.com', 'disneyplus.com', 'primevideo.com'],
    'Research': ['wikipedia.org', 'scholar.google.com', 'stackoverflow.com', 'github.com', 'docs.google.com'],
}


def categorize(url):
    try:
        domain = urlparse(url).netloc.lower().replace('www.', '')
    except Exception:
        return 'Uncategorized'
    for category, domains in CATEGORY_RULES.items():
        for d in domains:
            if domain == d or domain.endswith('.' + d):
                return category
    return 'Uncategorized'


class UrlLog(db.Model):
    __tablename__ = 'url_logs'

    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.Integer, db.ForeignKey('users.id'), nullable=False)
    time_entry_id = db.Column(db.Integer, db.ForeignKey('time_entries.id'), nullable=True)

    url = db.Column(db.String(1000), nullable=False)
    domain = db.Column(db.String(255))
    title = db.Column(db.String(500))
    category = db.Column(db.String(50), default='Uncategorized')

    visited_at = db.Column(db.DateTime, default=datetime.utcnow)
    duration_seconds = db.Column(db.Integer, default=0)

    user = db.relationship('User', backref='url_logs')
    time_entry = db.relationship('TimeEntry', backref='url_logs')

    def __repr__(self):
        return f'<UrlLog {self.domain} user={self.user_id}>'
