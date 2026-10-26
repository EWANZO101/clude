-- OPSHUB licensing — the only place an OPS installation keeps its license details.
-- Every OPS resource asks this one (exports['opslabs-license']:HasModule('…')); none of them has its own key or check.
Config = {}

-- Your OPSHUB license key. Leave it empty to enter it on the OPS Phone's license screen the first time the server runs
-- (an admin does it once; it's kept by this resource). You can also set it in server.cfg instead:
--   set opshub_license "OPSHUB-XXXX-XXXX-XXXX-XXXX"
Config.LicenseKey = ''

-- the OPSHUB licensing API
Config.Api = 'https://opsphone-store.opslabsystems.cloud/license/api/v1'

-- the longest gap between check-ins with OPSHUB (seconds). OPSHUB can ask for them more often (each license has a session
-- length: with no check-in for that long the server stops running OPS). Changes made on OPSHUB apply within this.
Config.CheckEvery = 120

-- start / stop OPS resources to match the license (resource modules). false = only report, never stop anything.
Config.Enforce = true

-- never stopped by licensing (the phone shows its own license screen when it isn't licensed)
-- rps_lib too: it's the framework bridge the phone (and so the license screen) and every other script start from.
-- Its actions are still checked by the guard like everything else.
Config.Protected = { ['opslabs-license'] = true, ['opslabs-phone'] = true, ['rps_lib'] = true }

-- who may enter / change the key in game: this ACE (add_ace group.admin opshub.license allow), or anyone with 'command'
Config.AdminAce = 'opshub.license'

-- the key OPSHUB signs licenses with. A license is only believed when its signature checks out against this, so a copied
-- or edited installation can't give itself modules. Don't change it.
Config.PublicKey = [[
-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEAsh1RF0TeOasUZnMcA/OpVLD4zNrV9/FSXMzRRRFU/zs=
-----END PUBLIC KEY-----
]]
