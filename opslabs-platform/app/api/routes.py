"""Server-to-server API for products integrated with the platform (Phase 7: OpsLabs
Commission is the first one). Auth is a per-company bearer token (Company.api_key) —
not customer-facing OAuth, just "this backend is who it says it is." Every product
instance calls /entitlement to check subscription status before showing platform-gated
UI, and /spend-credit when a credit-metered action happens. Both are designed to be
called defensively: a product should fail OPEN (allow the action) if this API is
unreachable, never let a platform outage lock a paying customer out of their own tool —
see the client-side notes in the OpsLabs Commission integration for how that's handled.
"""
import json

from flask import Blueprint, request, jsonify

from ..extensions import db
from ..models import Company
from ..billing import credits as credits_lib

api_bp = Blueprint('api', __name__, url_prefix='/api/v1')


def _authenticate():
    auth = request.headers.get('Authorization', '')
    if not auth.startswith('Bearer '):
        return None
    api_key = auth[len('Bearer '):].strip()
    if not api_key:
        return None
    return Company.query.filter_by(api_key=api_key).first()


@api_bp.route('/entitlement')
def entitlement():
    company = _authenticate()
    if not company:
        return jsonify({'error': 'invalid or missing API key'}), 401

    sub = company.current_subscription
    features = set(g.feature_key for g in company.active_feature_grants)
    if sub:
        features |= set(json.loads(sub.plan.product.feature_flags or '[]'))

    return jsonify({
        'company': company.name,
        'company_status': company.status,
        'active': company.is_active_company and sub is not None,
        'plan': sub.plan.name if sub else None,
        'subscription_status': sub.status if sub else None,
        'credit_balance': company.credit_balance,
        'features': sorted(features),
    })


@api_bp.route('/spend-credit', methods=['POST'])
def spend_credit():
    company = _authenticate()
    if not company:
        return jsonify({'error': 'invalid or missing API key'}), 401
    if not company.is_active_company:
        return jsonify({'error': 'company_suspended'}), 403

    data = request.get_json(silent=True) or {}
    feature_key = (data.get('feature_key') or '').strip()
    reason = data.get('reason')
    if not feature_key:
        return jsonify({'error': 'feature_key is required'}), 400

    try:
        new_balance = credits_lib.spend_for_feature(company.id, feature_key, reason=reason)
        db.session.commit()
    except credits_lib.InsufficientCredits:
        db.session.rollback()
        return jsonify({'error': 'insufficient_credits', 'balance': company.credit_balance}), 402

    return jsonify({'balance': new_balance})
