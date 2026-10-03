"""
Lightweight remote-update checker -- talks ONLY to
stocktoolsetup.opslabsystems.cloud's /api/updates/latest and
/api/updates/download, using the same installation_token already
saved from pairing (see app/cloud_setup.py) -- no separate
registration, heartbeat, or full item/tool data-sync involved.

Deliberately does not reuse app/sync_engine.py's SyncEngine, which is
built against the much larger (never-built) full cloud-sync API --
this only needs update-checking, and updater.py / app/update_notifier.py
already do 100% of the actual download/verify/apply work regardless of
where the release metadata comes from.
"""
import logging

import requests

log = logging.getLogger("update_checker")


class UpdateChecker:
    def __init__(self, app):
        self.app = app

    def check_for_update(self):
        from app.settings import load_settings
        settings = load_settings(self.app.config["DATA_DIR"])
        base = settings.get("setup_api_base", "https://stocktoolsetup.opslabsystems.cloud").rstrip("/")
        token = settings.get("setup_installation_token")
        if not token:
            return None  # not paired with stocktoolsetup yet -- nothing to check against

        try:
            resp = requests.get(
                f"{base}/api/updates/latest",
                headers={"Authorization": f"Bearer {token}"},
                timeout=10,
            )
            if resp.status_code == 404:
                return None  # no release published yet -- not an error
            resp.raise_for_status()
            return resp.json()
        except Exception:
            log.exception("Update check failed")
            return None
