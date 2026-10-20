Config = {}

Config.Identifier = "xonsight"
Config.Name = "Xon Sight"
Config.Description = "Bodycam evidence, live ops map, and cases - straight from your phone."
Config.Developer = "Xon Sight Evidence Portal"

-- Base URL of the evidence portal (no trailing slash), on the port it's
-- actually running on (5010, per app.py). Same value you used for
-- xonsight-livesync / xonsight-tablet.
Config.SiteUrl = "http://YOUR_SITE_HOST:5010"

-- Page that opens first inside the app.
Config.StartPath = "/dashboard"

-- Auto-install on every player's phone instead of requiring them to
-- download it from the LB Phone app store first.
Config.DefaultApp = false

-- In-game currency cost to download the app from the store. Leave nil
-- for a free download.
Config.Price = nil

-- Rough app size shown in the store listing (kb). Cosmetic only.
Config.Size = 4096

-- Lets the app submit evidence straight from LB Phone's own camera
-- (server.lua posts it to /api/xonsight/evidence) - you don't need
-- OPS Phone / opslabs-bodycam at all to use this path. Must match
-- XONSIGHT_WEBHOOK_KEY in the portal's .env, or leave blank if the
-- portal was deployed with no key configured.
Config.WebhookKey = ""

-- Set to false to hide the in-app "Record evidence" capture button and
-- only use this app as a viewer (e.g. if you'd rather evidence only ever
-- come from OPS Phone / another bodycam resource).
Config.AllowCapture = true
