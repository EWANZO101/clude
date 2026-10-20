-- Paste this into resources/XonSight/config.lua (replace/merge with any
-- existing Config.Evidence block already there), then run `restart XonSight`.
--
-- webhookUrl must point at the evidence portal's webhook route, on the port
-- it's actually running on (5010, per app.py).
-- webhookApiKey must match XONSIGHT_WEBHOOK_KEY in the site's .env file.

Config.Evidence = {
    webhookUrl = "http://YOUR_SITE_HOST:5010/api/xonsight/evidence",
    webhookApiKey = "change-me-too",
}
