Config = {}

-- Base URL of the evidence portal site (no trailing slash), on the port
-- it's actually running on (5010, per app.py).
Config.SiteUrl = "http://YOUR_SITE_HOST:5010"

-- Must match XONSIGHT_WEBHOOK_KEY in the site's .env file.
Config.ApiKey = "change-me-too"

-- How often (ms) to poll exports.XonSight:GetActiveRecorders() and push the
-- roster to the site. The sync endpoint replaces the whole roster every call,
-- so this doesn't need to be fast - 5s is a reasonable default.
Config.PollIntervalMs = 5000

-- Print sync attempts/failures to the server console.
Config.Debug = false
