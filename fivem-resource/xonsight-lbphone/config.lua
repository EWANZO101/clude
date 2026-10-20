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
