Config = {}

-- Base URL of the evidence portal site (no trailing slash), on the port
-- it's actually running on (5010, per app.py). The tablet just iframes
-- this site - the officer logs in inside the tablet UI like a normal
-- browser tab; the NUI browser keeps its own cookie storage between
-- uses, so that only has to happen once.
Config.SiteUrl = "http://YOUR_SITE_HOST:5010"

-- Path opened inside the tablet. "/dashboard" is a sensible landing page;
-- point it at "/live" instead if you want officers to land straight on
-- the live recorder map.
Config.StartPath = "/dashboard"

-- Key that opens/closes the tablet (FiveM control name, see
-- https://docs.fivem.net/docs/game-references/controls/). Change this if
-- it conflicts with another resource.
Config.ToggleKey = "F6"

-- Stock GTA V tablet prop - no custom model needed. If your server's
-- game build doesn't have this streamed in for some reason, swap it for
-- another vanilla tablet-shaped prop (e.g. "prop_cs_tablet" is used in
-- several vanilla heist/casino scenes and is safe on a default FiveM
-- server).
Config.PropModel = "prop_cs_tablet"

-- Bone to attach the tablet prop to and its offset/rotation relative to
-- that bone. Tuned for prop_cs_tablet held in the left hand, roughly
-- screen-towards-player. Adjust if you swap the model.
Config.AttachBone = "PH_L_Hand"
Config.AttachOffset = vector3(0.03, 0.02, 0.0)
Config.AttachRotation = vector3(0.0, 0.0, 0.0)

-- Restrict who can open the tablet by job (jobs come from whatever
-- framework/export your server uses - wire GetPlayerJob() in client.lua
-- to it). Leave empty to let anyone with the item/command open it.
Config.AllowedJobs = {}

-- Disable attacking/shooting while the tablet is open (you're holding it
-- with both hands, not a weapon). Movement stays enabled so officers can
-- still walk around reading it, matching how most phone resources behave.
Config.DisableAttackWhileOpen = true
