import re
from urllib.parse import urlparse

from flask import Blueprint, current_app, redirect, url_for, flash, request, abort, Response
from flask_login import login_required, current_user

from ..extensions import db
from ..models import Domain
from . import cloudflare_client
from . import verification

domains_bp = Blueprint('domains', __name__)

_HOSTNAME_RE = re.compile(r'^(?!-)[A-Za-z0-9-]{1,63}(?<!-)(\.(?!-)[A-Za-z0-9-]{1,63}(?<!-))+$')


def domains_configured():
    cfg = current_app.config
    return bool(cfg['CLOUDFLARE_API_TOKEN'] and cfg['CLOUDFLARE_ZONE_ID']
                and cfg['CUSTOM_DOMAIN_CNAME_TARGET'])


def _safe_referrer_or(default):
    """request.referrer is attacker-controlled (any HTTP client can set an arbitrary
    Referer header) — redirecting to it unchecked is an open redirect. Only follow it
    when it points back at this same app."""
    ref = request.referrer
    if ref and urlparse(ref).netloc == urlparse(request.host_url).netloc:
        return ref
    return default


@domains_bp.route('/domains/add', methods=['POST'])
@login_required
def add_domain():
    if not current_user.has_company_role('owner', 'admin'):
        flash('Only company owners/admins can connect a domain.', 'error')
        return redirect(url_for('auth.dashboard'))

    if not domains_configured():
        flash('Custom domains aren\'t configured on this platform yet.', 'error')
        return redirect(url_for('auth.dashboard'))

    hostname = request.form.get('hostname', '').strip().lower().rstrip('.')
    if not _HOSTNAME_RE.match(hostname):
        flash('Enter a valid domain, e.g. app.yourcompany.com.', 'error')
        return redirect(url_for('auth.dashboard'))

    if Domain.query.filter_by(hostname=hostname).first():
        flash(f'{hostname} is already connected (by someone).', 'error')
        return redirect(url_for('auth.dashboard'))

    target = current_app.config['CUSTOM_DOMAIN_CNAME_TARGET']
    domain = Domain(company_id=current_user.company_id, hostname=hostname, cname_target=target)

    try:
        record_id = cloudflare_client.create_cname_record(
            current_app.config['CLOUDFLARE_API_TOKEN'],
            current_app.config['CLOUDFLARE_ZONE_ID'],
            hostname, target,
        )
    except cloudflare_client.CloudflareError as e:
        flash(f'Couldn\'t create the DNS record: {e}', 'error')
        return redirect(url_for('auth.dashboard'))

    domain.cloudflare_record_id = record_id
    domain.cloudflare_zone_id = current_app.config['CLOUDFLARE_ZONE_ID']
    db.session.add(domain)
    db.session.commit()
    flash(f'{hostname} added — DNS is set up automatically. It may take a few minutes '
          'to propagate; check its status below.', 'success')
    return redirect(url_for('auth.dashboard'))


@domains_bp.route('/domains/<int:domain_id>/verify', methods=['POST'])
@login_required
def verify_domain(domain_id):
    domain = db.session.get(Domain, domain_id) or abort(404)
    if domain.company_id != current_user.company_id:
        abort(404)

    new_status, reason = verification.check(domain)
    domain.status = new_status
    domain.failure_reason = reason
    if new_status == 'active' and not domain.verified_at:
        from datetime import datetime
        domain.verified_at = datetime.utcnow()
    db.session.commit()

    messages = {
        'pending': (reason, 'error'),
        'failed': (reason, 'error'),
        'verified': ('DNS and routing look good — checking once more to confirm before marking active.', 'success'),
        'active': (f'{domain.hostname} is active!', 'success'),
    }
    msg, category = messages[new_status]
    flash(msg, category)
    return redirect(url_for('auth.dashboard'))


@domains_bp.route('/domains/<int:domain_id>/remove', methods=['POST'])
@login_required
def remove_domain(domain_id):
    domain = db.session.get(Domain, domain_id) or abort(404)
    if domain.company_id != current_user.company_id and not current_user.is_platform_admin:
        abort(404)

    if domain.cloudflare_record_id and domains_configured():
        try:
            cloudflare_client.delete_record(
                current_app.config['CLOUDFLARE_API_TOKEN'],
                domain.cloudflare_zone_id, domain.cloudflare_record_id,
            )
        except cloudflare_client.CloudflareError as e:
            flash(f'Removed locally, but couldn\'t delete the DNS record automatically: {e}. '
                  'Remove it from Cloudflare manually.', 'error')
            db.session.delete(domain)
            db.session.commit()
            return redirect(_safe_referrer_or(url_for('auth.dashboard')))

    hostname = domain.hostname
    db.session.delete(domain)
    db.session.commit()
    flash(f'{hostname} disconnected.', 'success')
    return redirect(_safe_referrer_or(url_for('auth.dashboard')))


@domains_bp.route('/.well-known/domain-verify/<token>')
def domain_verify_challenge(token):
    """Hit over the CUSTOMER's hostname (not the platform's own domain) — this is what
    proves their DNS + Cloudflare + our routing actually deliver traffic to us. No auth:
    Cloudflare/the customer's browser hits this directly, there's no session to check."""
    domain = Domain.query.filter_by(verify_token=token).first()
    if not domain:
        abort(404)
    return Response(token, mimetype='text/plain')
