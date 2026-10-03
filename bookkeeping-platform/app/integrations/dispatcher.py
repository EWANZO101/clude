"""Every integration call goes through `run_integration`. It never lets an
integration's exception propagate: it's caught, logged to IntegrationLog,
and reported back as a (success, result_or_message) tuple. This is what
guarantees a bug or outage in one integration (a bad CSV, a malformed
webhook, a provider timeout) can't take down the core accounting engine or
any other integration.
"""
from app.extensions import db
from app.models.integration import IntegrationLog, STATUS_SUCCESS, STATUS_FAILURE
from app.models.notification import TYPE_INTEGRATION_FAILURE


def run_integration(provider, business_id, event, fn, *args, **kwargs):
    try:
        result = fn(*args, **kwargs)
    except Exception as e:  # noqa: BLE001 — intentional: isolate ANY integration failure
        db.session.rollback()
        db.session.add(IntegrationLog(
            business_id=business_id, provider=provider, event=event,
            status=STATUS_FAILURE, message=str(e),
        ))
        db.session.commit()
        if business_id:
            from app.notifications.service import notify_business_admins
            notify_business_admins(
                business_id, TYPE_INTEGRATION_FAILURE,
                title=f"{provider} integration failed",
                message=f"{event}: {e}",
                link="/integrations/",
            )
        return False, str(e)

    db.session.add(IntegrationLog(
        business_id=business_id, provider=provider, event=event,
        status=STATUS_SUCCESS, message=None,
    ))
    db.session.commit()
    return True, result


def get_or_create_config(business_id, provider):
    from app.models.integration import IntegrationConfig
    config = IntegrationConfig.query.filter_by(business_id=business_id, provider=provider).first()
    if config is None:
        config = IntegrationConfig(business_id=business_id, provider=provider, is_enabled=False)
        db.session.add(config)
        db.session.commit()
    return config
